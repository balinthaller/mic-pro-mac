import Foundation
import IOBluetooth
import AppKit

let cliVersion = "0.1.0"
let projectRoot = DeviceConfig.dataDirectory.path

func printErrorAndExit(_ text: String, _ code: Int = 2) -> Never {
    FileHandle.standardError.write(Data(("error: " + text + "\n").utf8))
    exit(Int32(code == 0 ? 2 : code))
}

struct CommonOptions {
    var transport: TransportMode = .auto
    var json = false
    var transportWasExplicit = false
}

func parseOptions(_ arguments: [String]) -> (options: CommonOptions, rest: [String], problem: String?) {
    var options = CommonOptions()
    var rest: [String] = []
    var index = 0
    while index < arguments.count {
        let text = arguments[index]
        if text == "--json" { options.json = true; index += 1; continue }
        if text == "--transport" {
            guard index + 1 < arguments.count, let mode = parseTransportMode(arguments[index + 1]) else {
                return (options, rest, "--transport expects auto|ble|rfcomm")
            }
            options.transport = mode
            options.transportWasExplicit = true
            index += 2
            continue
        }
        rest.append(text)
        index += 1
    }
    return (options, rest, nil)
}

@discardableResult
func takeOption(_ rest: inout [String], _ name: String, takesValue: Bool) -> String? {
    guard let index = rest.firstIndex(of: name) else { return nil }
    if takesValue {
        guard index + 1 < rest.count else { rest.remove(at: index); return nil }
        let value = rest[index + 1]
        rest.remove(at: index + 1)
        rest.remove(at: index)
        return value
    }
    rest.remove(at: index)
    return ""
}

func printHelp() {
    print("""
    micproctl \(cliVersion) — standalone CLI for the Insta360 Mic Pro (unofficial)

    Configure once (device must already be paired in macOS Bluetooth settings):
      micproctl configure --list
      micproctl configure --address AA:BB:CC:DD:EE:01 --suffix XXXXXX

    Status and settings (rfcomm transport while the mic is connected as an
    audio device, BLE otherwise; --transport ble|rfcomm to force, --json everywhere):
      micproctl status                       battery, charging, decoded settings
      micproctl battery                      battery percent + charging state
      micproctl battery --classic            quick read via the macOS BT cache
      micproctl settings [--raw]             decoded settings groups
      micproctl set gain -6                  -12...12 dB
      micproctl set noise off|on|high
      micproctl set mute on|off
      micproctl set float32 on|off           32-bit float recording
      micproctl set lowcut on|off
      micproctl set childlock on|off
      micproctl set vibration on|off
      micproctl set led on|off
      micproctl set <mapped-field> <value>   fields from protocol-map.json
      micproctl fields                       list known fields and value domains

    E-ink screen (rfcomm transport; same verified-backup rules as upstream):
      micproctl wallpaper backup                          verified backup of the current screen
      micproctl wallpaper upload image.png [--backup DIR]  upload + mandatory read-back verify
      micproctl wallpaper restore --backup DIR            restore a verified backup

    Protocol research (read-only):
      micproctl probe read 0x1010 0x1011 ...              raw settings-group reads
      micproctl probe diff [0x1011 0x1013 ...]        guided before/after diff, extra groups optional
    Pattern / mono-stereo / bit-depth bytes are not yet mapped: change one
    setting (mobile app or device buttons both work), run `probe diff`, add to
      ~/Library/Application Support/MicProMac/protocol-map.json
    e.g. {"pattern":{"group":"0x1012","index":6,"values":{"omni":0,"cardioid":1,"figure8":2}}}

    Local utilities:
      micproctl doctor                       diagnostics (config, pairing, services)
      micproctl connect-audio                open the classic Bluetooth audio link
      micproctl disconnect-audio             close it
      micproctl version

    Writes are whole-group with full read-back verification and never retried.
    A wallpaper BEGIN can erase the screen slot, so uploads require a verified
    backup and always finish with a full read-back. No firmware paths here.
    """)
}

// ---------- shared plumbing ----------

final class Box<T> { var value: T? }

func jsonPrint(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]) {
        print(String(decoding: data, as: UTF8.self))
    }
}

func sessionFailure(_ driver: Driver, _ options: CommonOptions, exitCode: Int) -> Never {
    var object: [String: Any] = ["ok": false, "exit_code": exitCode == 0 ? 1 : exitCode]
    if let warning = driver.context.warnings.first { object["error"] = warning }
    if !driver.context.warnings.isEmpty { object["warnings"] = driver.context.warnings }
    if let name = driver.context.transportName { object["transport"] = name }
    if !driver.jsonLines.isEmpty { object["log"] = driver.jsonLines }
    if options.json { jsonPrint(object) }
    else {
        let message = driver.context.warnings.first ?? "operation failed"
        FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    }
    exit(Int32(exitCode == 0 ? 1 : exitCode))
}

func runSession(options: CommonOptions, items: [Driver.Item], hardDeadline: TimeInterval = 2400) -> (Driver, Int) {
    let driver = Driver(jsonOutput: options.json, hardDeadline: hardDeadline, items: items)
    var code = 1
    driver.run(mode: options.transport) { exitCode in code = exitCode }
    return (driver, code)
}

func serialSuffixText(_ identity: Data) -> String {
    String(decoding: identity.dropFirst(16).prefix(while: { $0 != 0 }), as: UTF8.self)
}

func batteryPayload(_ context: SessionContext) -> [String: Any] {
    var payload: [String: Any] = [:]
    if let battery = context.battery {
        payload["percent"] = battery.percent
        payload["charging"] = battery.powerType == 1
        payload["power_type"] = battery.powerType
        payload["battery_type"] = battery.batteryType
        payload["source"] = "control-protocol-0x1005"
    } else if let level = context.batteryCharacteristicLevel {
        payload["percent"] = level
        payload["source"] = "standard-battery-service"
    }
    if let at = context.batteryAt { payload["read_at"] = ISO8601DateFormatter().string(from: at) }
    if let warning = context.batteryError { payload["warning"] = warning }
    return payload
}

func decodedGroupJSON(_ group: UInt16, _ values: Data, map: ProtocolMap) -> [String: Any] {
    var object: [String: Any] = ["raw": hexDump(values), "length": values.count]
    for spec in allFields(map: map) where spec.group == group {
        object[spec.name] = decodeField(spec, from: values)
    }
    return object
}

func printDecodedGroup(_ group: UInt16, _ values: Data, map: ProtocolMap) {
    let labels = group == 0x1000 ? commonLabels : moreLabels
    print(String(format: "group 0x%04X (%d bytes): %@", group, values.count, hexDump(values) as NSString))
    for row in decodeGroup(group, values, map: map) {
        let label = (row.position < labels.count ? labels[row.position] : row.label)
        print("  [b\(row.position)] \(label.padding(toLength: 18, withPad: " ", startingAt: 0)) = \(row.value)")
    }
}

func printStatus(_ context: SessionContext, map: ProtocolMap, json: Bool) {
    if json {
        var object: [String: Any] = ["ok": true, "transport": context.transportName as Any]
        object["battery"] = batteryPayload(context)
        if let common = context.common { object["common"] = decodedGroupJSON(0x1000, common, map: map) }
        if let more = context.more { object["more"] = decodedGroupJSON(0x1012, more, map: map) }
        if let identity = context.identity { object["serial"] = serialSuffixText(identity) }
        if let inventory = context.wallpaperInventoryBody, inventory.count >= 50 {
            object["wallpaper_md5"] = Data(inventory[34..<50]).map { String(format: "%02x", $0) }.joined()
        }
        jsonPrint(object)
        return
    }
    print("transport: \(context.transportName ?? "?")")
    let battery = batteryPayload(context)
    if let percent = battery["percent"] {
        let charging = (battery["charging"] as? Bool) == true
        print("battery: \(percent)%\((battery["power_type"] as? Int ?? 0) == 1 ? (charging ? " (charging)" : " (on power)") : "")")
    } else { print("battery: unavailable\(context.batteryError.map { " (\($0))" } ?? "")") }
    if let common = context.common { printDecodedGroup(0x1000, common, map: map) }
    if let more = context.more { printDecodedGroup(0x1012, more, map: map) }
    if let identity = context.identity { print("verified serial: …\(serialSuffixText(identity))") }
    if let inventory = context.wallpaperInventoryBody, inventory.count >= 50 {
        print("e-ink panel md5: " + Data(inventory[34..<50]).map { String(format: "%02x", $0) }.joined())
    }
}

// ---------- commands ----------

func readItemStep(includeBattery: Bool, into box: Box<AppControlReadPlan>, contextToMap: @escaping (AppControlReadPlan) -> Void = { _ in }) -> Driver.Item {
    Driver.Item(name: "read-settings", make: { driver in
        let op = ReadOp(includeBattery: includeBattery)
        box.value = op.plan
        return op
    }, onDone: { driver in
        guard let plan = box.value else { return }
        driver.context.identity = plan.identity
        driver.context.wallpaperInventoryBody = plan.wallpaperInventory
        driver.context.common = plan.common
        driver.context.more = plan.more
        driver.context.battery = plan.batteryInfo
        driver.context.batteryAt = plan.batteryReadAt
        driver.context.batteryError = plan.batteryError
        contextToMap(plan)
    })
}

func runStatus(options: CommonOptions, map: ProtocolMap) -> Never {
    let box = Box<AppControlReadPlan>()
    let items = [readItemStep(includeBattery: true, into: box)]
    let (driver, code) = runSession(options: options, items: items)
    guard code == 0, box.value != nil else { sessionFailure(driver, options, exitCode: code) }
    printStatus(driver.context, map: map, json: options.json)
    exit(0)
}

func runBattery(options: CommonOptions, classic: Bool) -> Never {
    if classic {
        if options.json {
            if let level = SystemBattery.micProLevel() { jsonPrint(["ok": true, "percent": level, "source": "macos-bluetooth-cache"]); exit(0) }
            jsonPrint(["ok": false, "error": "not available while the device is not connected as an audio device"])
            exit(1)
        }
        if let level = SystemBattery.micProLevel() { print("\(level)%"); exit(0) }
        printErrorAndExit("no cached battery value; is the mic currently connected as an audio device?", 1)
    }
    let box = Box<AppControlReadPlan>()
    let (driver, code) = runSession(options: options, items: [readItemStep(includeBattery: true, into: box)])
    guard code == 0, box.value != nil else { sessionFailure(driver, options, exitCode: code) }
    let battery = batteryPayload(driver.context)
    if options.json { jsonPrint(["ok": true, "battery": battery]); exit(0) }
    if let percentAny = battery["percent"], let percent = percentAny as? Int {
        let powerType = battery["power_type"] as? Int ?? 0
        let charging = (battery["charging"] as? Bool) == true
        print("\(percent)%\((powerType == 1) ? (charging && percent < 100 ? " (charging)" : " (on power)") : "")")
    } else {
        print("battery unavailable: \(driver.context.batteryError ?? "no reading")")
        exit(1)
    }
    exit(0)
}

func runSettings(options: CommonOptions, map: ProtocolMap, raw: Bool) -> Never {
    let box = Box<AppControlReadPlan>()
    let (driver, code) = runSession(options: options, items: [readItemStep(includeBattery: false, into: box)])
    guard code == 0, box.value != nil else { sessionFailure(driver, options, exitCode: code) }
    if raw || options.json {
        var object: [String: Any] = ["ok": true, "transport": driver.context.transportName as Any]
        if let common = driver.context.common { object["common"] = decodedGroupJSON(0x1000, common, map: map) }
        if let more = driver.context.more { object["more"] = decodedGroupJSON(0x1012, more, map: map) }
        jsonPrint(object)
    } else {
        if let common = driver.context.common { printDecodedGroup(0x1000, common, map: map) }
        if let more = driver.context.more { printDecodedGroup(0x1012, more, map: map) }
        print("battery: \(String(describing: batteryPayload(driver.context)["percent"] ?? "n/a"))")
    }
    exit(0)
}

func runSet(options: CommonOptions, map: ProtocolMap, fieldName: String, value: String) -> Never {
    guard let field = field(named: fieldName, map: map) else {
        let names = allFields(map: map).map { $0.name }.sorted().joined(separator: ", ")
        printErrorAndExit("unknown field '\(fieldName)'. Known: \(names). Extra fields come from protocol-map.json (\(ProtocolMap.url.path))")
    }
    guard field.group == 0x1000 || field.group == 0x1012 else {
        printErrorAndExit("field '\(fieldName)' maps to group \(String(format: "0x%04X", field.group)); only 0x1000/0x1012 are writable here", 2)
    }
    // Validate the argument's semantics before opening any connection.
    do { _ = try proposeChange(field, argument: value, current: Data(repeating: 0, count: field.group == 0x1000 ? 6 : 12)) }
    catch CLIError.usage(let message) { printErrorAndExit(message) }
    catch { printErrorAndExit("invalid value '\(value)' for field '\(field.name)'") }
    let box = Box<AppControlReadPlan>()
    let writeBox = Box<SettingsWriteOp>()
    let writeStep = Driver.Item(name: "write-\(field.name)", make: { driver in
        guard let identity = driver.context.identity else { driver.itemCreationError = "identity missing; read step failed"; return nil }
        do {
            let op = try SettingsWriteOp(group: field.group, identity: identity) { current in
                try proposeChange(field, argument: value, current: current)
            }
            writeBox.value = op
            return op
        } catch CLIError.usage(let message) { driver.itemCreationError = message; return nil }
        catch { driver.itemCreationError = "could not prepare the write plan"; return nil }
    }, onDone: { driver in
        guard let op = writeBox.value else { return }
        driver.context.writeAcknowledged = op.acked
        if op.state == .unchanged { driver.context.writeUnchanged = true }
        if let proposed = op.proposedValues { driver.context.replaceGroup(field.group, values: proposed) }
    })
    let items = [readItemStep(includeBattery: false, into: box), writeStep]
    let (driver, code) = runSession(options: options, items: items)
    guard code == 0, writeBox.value != nil else { sessionFailure(driver, options, exitCode: code) }
    guard let op = writeBox.value else { sessionFailure(driver, options, exitCode: 1) }
    if op.state == .unchanged {
        if options.json { jsonPrint(["ok": true, "changed": false, "field": field.name, "value": value]) }
        else { print("\(field.name) already set to \(value); nothing written") }
        exit(0)
    }
    let verified = op.state == .ready
    let fresh = driver.context.group(field.group)
    if options.json {
        jsonPrint(["ok": verified, "changed": true, "field": field.name, "requested": value,
                   "value": fresh.map { decodeField(field, from: $0) } as Any,
                   "acknowledged": op.acked,
                   "readback_raw": fresh.map { hexDump($0) } as Any])
    } else {
        print("set \(field.name)=\(value): \(verified ? "verified by full-group read-back" : "NOT CONFIRMED") (device ack: \(op.acked ? "yes" : "no"))")
        if let fresh = fresh { print(String(format: "read-back 0x%04X: %@", field.group, hexDump(fresh) as NSString)) }
    }
    exit(verified ? 0 : 1)
}

func runFields(map: ProtocolMap) -> Never {
    print("field".padding(toLength: 12, withPad: " ", startingAt: 0)
        + "values".padding(toLength: 26, withPad: " ", startingAt: 0)
        + "location".padding(toLength: 12, withPad: " ", startingAt: 0)
        + "origin")
    for field in allFields(map: map) {
        let origin = knownFields.contains(where: { $0.name == field.name }) ? "built-in" : "protocol-map.json"
        let location = String(format: "0x%04X[%d]", field.group, field.index)
        print(field.name.padding(toLength: 12, withPad: " ", startingAt: 0)
            + field.valueText.padding(toLength: 26, withPad: " ", startingAt: 0)
            + location.padding(toLength: 12, withPad: " ", startingAt: 0)
            + origin)
    }
    exit(0)
}

// probe sessions read both known groups plus any user groups
func runProbeSession(options: CommonOptions, groups: [UInt16], includeBattery: Bool) -> (Driver, Int) {
    let box = Box<AppControlReadPlan>()
    let rawBox = Box<RawGroupReadOp>()
    let rawStep = Driver.Item(name: "raw-groups", make: { driver in
        guard let identity = driver.context.identity else { driver.itemCreationError = "identity not captured; read step failed"; return nil }
        let op = RawGroupReadOp(identity: identity, groups: groups)
        rawBox.value = op
        return op
    }, onDone: { driver in
        guard let op = rawBox.value else { return }
        driver.context.rawGroupValues.merge(op.values) { _, new in new }
        driver.context.rawGroupErrors.merge(op.errors) { _, new in new }
    })
    let items = [readItemStep(includeBattery: includeBattery, into: box), rawStep]
    return runSession(options: options, items: items)
}

func runProbeRead(options: CommonOptions, map: ProtocolMap, groupArguments: [String]) -> Never {
    var groups: [UInt16] = []
    for text in groupArguments {
        guard let group = parseHexGroup(text) else { printErrorAndExit("bad group hex '\(text)' (e.g. 0x1011)") }
        if !groups.contains(group) { groups.append(group) }
    }
    guard !groups.isEmpty else { printErrorAndExit("probe read needs at least one group, e.g. 0x1010") }
    let (driver, code) = runProbeSession(options: options, groups: groups, includeBattery: false)
    guard code == 0 else { sessionFailure(driver, options, exitCode: code) }
    var ok = driver.context.rawGroupErrors.isEmpty
    if options.json {
        var groupObject: [String: Any] = [:]
        for (group, values) in driver.context.rawGroupValues { groupObject[String(format: "0x%04X", group)] = hexDump(values) }
        var errorObject: [String: String] = [:]
        for (group, message) in driver.context.rawGroupErrors { errorObject[String(format: "0x%04X", group)] = message }
        jsonPrint(["ok": ok, "groups": groupObject, "errors": errorObject])
    } else {
        for group in groups {
            if let values = driver.context.rawGroupValues[group] {
                print(String(format: "group 0x%04X (%d bytes): %@", group, values.count, hexDump(values) as NSString))
            } else if let message = driver.context.rawGroupErrors[group] {
                ok = false
                print(String(format: "group 0x%04X rejected or invalid (%@)", group, message as NSString))
            }
        }
    }
    exit(ok ? 0 : 1)
}

func probeSnapshot(options: CommonOptions, groups: [UInt16]) -> (common: Data?, more: Data?, extra: [UInt16: Data])? {
    let (driver, code) = runProbeSession(options: options, groups: groups, includeBattery: false)
    guard code == 0 else {
        if options.json { sessionFailure(driver, options, exitCode: code) }
        printErrorAndExit(driver.context.warnings.first ?? "probe session failed", 1)
    }
    return (driver.context.common, driver.context.more, driver.context.rawGroupValues)
}

func runProbeDiff(options: CommonOptions, map: ProtocolMap, groupArguments: [String]) -> Never {
    var extraGroups: [UInt16] = []
    for text in groupArguments {
        guard let group = parseHexGroup(text) else { printErrorAndExit("bad group hex '\(text)' (e.g. 0x1011)") }
        if !extraGroups.contains(group) { extraGroups.append(group) }
    }
    print("== probe diff: snapshot 1 ==")
    guard let before = probeSnapshot(options: options, groups: extraGroups) else { exit(1) }
    print("snapshot 1 captured (\(Date().formatted()))")
    print("Now change exactly ONE setting — official mobile app or device buttons both work;")
    print("wait for the app / e-ink to confirm the change took, then press ENTER here…")
    _ = readLine()
    print("== probe diff: snapshot 2 ==")
    guard let after = probeSnapshot(options: options, groups: extraGroups) else { exit(1) }
    print("snapshot 2 captured (\(Date().formatted()))")
    for group in extraGroups where before.extra[group] == nil || after.extra[group] == nil {
        print("note: group \(String(format: "0x%04X", group)) unreadable in at least one snapshot; excluded from the diff")
    }
    var deltas: [(group: UInt16, index: Int, before: Int, after: Int)] = []
    var pairs: [(UInt16, Data?, Data?)] = [(0x1000, before.common, after.common), (0x1012, before.more, after.more)]
    for group in extraGroups { pairs.append((group, before.extra[group], after.extra[group])) }
    for (group, old, new) in pairs { guard let old = old, let new = new else { continue }
        for index in 0..<min(old.count, new.count) where old[old.startIndex + index] != new[new.startIndex + index] {
            deltas.append((group, index, Int(old[old.startIndex + index]), Int(new[new.startIndex + index])))
        }
    }
    if options.json {
        jsonPrint(["ok": deltas.count <= 1, "deltas": deltas.map { ["group": String(format: "0x%04X", $0.group), "index": $0.index, "before": $0.before, "after": $0.after] }])
        exit(deltas.count <= 1 ? 0 : 1)
    }
    if deltas.isEmpty { print("no differences: the change did not alter the settings groups (or did not stick)."); exit(0) }
    print("changed bytes:")
    for delta in deltas {
        print(String(format: "  group 0x%04X byte [%d]: %d -> %d", delta.group, delta.index, delta.before, delta.after))
    }
    if deltas.count == 1 {
        let d = deltas[0]
        print("""
        To let `set` command this field, add to \(ProtocolMap.url.path):
          {"<name>": {"group": "\(String(format: "0x%04X", d.group))",
                       "index": \(d.index),
                       "values": {"<value-a>": \(d.before), "<value-b>": \(d.after)}}}
        e.g. name=pattern, values omni/cardioid/figure8/stereo — verify each
        value's meaning by changing the physical setting once per value.
        """)
    } else {
        print("several bytes changed; repeat with a single-setting change to pin the byte.")
    }
    exit(0)
}

// wallpaper steps need the identity from a completed read step in the same session

func wallpaperReadStep(into box: Box<WallpaperReadOp>) -> Driver.Item {
    Driver.Item(name: "read-wallpaper", make: { driver in
        guard let identity = driver.context.identity else { driver.itemCreationError = "identity not captured"; return nil }
        let op = WallpaperReadOp(identity: identity)
        box.value = op
        return op
    }, onDone: { driver in
        guard let op = box.value else { return }
        driver.context.wallpaperFile = op.plan.file
        driver.context.wallpaperManifest = op.plan.manifest
        driver.context.wallpaperMissingCRC = op.plan.missingCRC
    })
}

func latestVerifiedBackup() -> URL? {
    let backups = DeviceConfig.dataDirectory.appendingPathComponent("backups", isDirectory: true)
    guard let children = try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil) else { return nil }
    return children
        .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
        .max { $0.lastPathComponent < $1.lastPathComponent }
}

func runWallpaperBackup(options: CommonOptions) -> Never {
    var options = options
    if options.transportWasExplicit && options.transport == .ble { printErrorAndExit("wallpaper works over the RFCOMM control channel only (upstream-validated transport)") }
    options.transport = .rfcomm
    let readBox = Box<AppControlReadPlan>()
    let wallBox = Box<WallpaperReadOp>()
    let (driver, code) = runSession(options: options, items: [readItemStep(includeBattery: false, into: readBox), wallpaperReadStep(into: wallBox)], hardDeadline: 600)
    guard code == 0, let plan = wallBox.value?.plan, let readPlan = readBox.value else { sessionFailure(driver, options, exitCode: code) }
    do {
        let url = try saveWallpaperBackup(plan: plan, readPlan: readPlan, id: UUID().uuidString)
        if options.json { jsonPrint(["ok": true, "backup_directory": url.path, "png": url.appendingPathComponent("original.png").path]) }
        else { print("verified backup saved: \(url.path)") }
        exit(0)
    } catch {
        if options.json { jsonPrint(["ok": false, "error": "read-back PNG/MD5/identity verification failed; not saved as a usable backup"]) }
        printErrorAndExit("read-back PNG/MD5/identity verification failed; raw copy in ~/Library/Application Support/MicProMac/logs/ if present", 1)
    }
}

func runWallpaperTransfer(options: CommonOptions, image: String?, backupDirectory: String?, restoring: Bool) -> Never {
    var options = options
    if options.transportWasExplicit && options.transport == .ble { printErrorAndExit("wallpaper works over the RFCOMM control channel only (upstream-validated transport)") }
    options.transport = .rfcomm
    let readBox = Box<AppControlReadPlan>()
    let uploadBox = Box<WallpaperUploadOp>()
    let assetsBox = Box<PreparedWallpaperUpload>()
    let secondReadBox = Box<AppControlReadPlan>()
    let verifyBox = Box<WallpaperReadOp>()
    let uploadStep = Driver.Item(name: restoring ? "upload - restore" : "upload", make: { driver in
        guard let readPlan = readBox.value else { driver.itemCreationError = "identity step not completed"; return nil }
        do {
            let assets: PreparedWallpaperUpload
            if restoring {
                guard let backup = backupDirectory else { throw CLIError.usage("restore requires --backup DIR (the directory produced by wallpaper backup)") }
                assets = try prepareWallpaperRestore(backup: backup, readPlan: readPlan)
            } else {
                guard let image = image else { throw CLIError.usage("upload requires an image path (png/jpg)") }
                let backup = backupDirectory ?? latestVerifiedBackup()?.path
                guard let chosen = backup else { throw CLIError.usage("no verified backup found yet; run `micproctl wallpaper backup` first or pass --backup DIR") }
                assets = try prepareWallpaperUpload(image: image, backup: chosen, readPlan: readPlan)
            }
            guard let identity = driver.context.identity else { throw CLIError.usage("identity missing") }
            let op = try WallpaperUploadOp(identity: identity, panel: assets.panel, png: assets.png)
            assetsBox.value = assets
            uploadBox.value = op
            driver.context.wallpaperFile = nil
            return op
        } catch CLIError.usage(let message) { driver.itemCreationError = message; return nil }
        catch { driver.itemCreationError = "backup/identity/image validation failed; refusing to start the upload"; return nil }
    }, onDone: { driver in printDebug("upload phase complete") })
    let sleepStep = Driver.Item(name: "wait-eink-refresh", make: { driver in
        driver.printLine("upload ACKed; waiting 28 s for the e-ink panel…")
        return SleepOp(seconds: 28, label: "e-ink refresh")
    }, onDone: { _ in })
    let verifyWallpaperStep = wallpaperReadStep(into: verifyBox)
    let items = [readItemStep(includeBattery: false, into: readBox),
                 uploadStep,
                 sleepStep,
                 readItemStep(includeBattery: false, into: secondReadBox),
                 verifyWallpaperStep]
    let (driver, code) = runSession(options: options, items: items, hardDeadline: 900)
    guard code == 0, let assets = assetsBox.value, let verify = verifyBox.value,
          let secondRead = secondReadBox.value else { sessionFailure(driver, options, exitCode: code) }
    // Confirm the screen now holds exactly what we sent.
    guard let file = driver.context.wallpaperFile, file == assets.png else {
        if options.json { jsonPrint(["ok": false, "error": "read-back mismatch: the panel does not hold the uploaded PNG"]) }
        printErrorAndExit("read-back mismatch: the panel does not hold the uploaded PNG; the backup is intact", 1)
    }
    do {
        let url = try saveWallpaperBackup(plan: verify.plan, readPlan: secondRead, id: UUID().uuidString)
        driver.context.verifiedBackupURL = url
        if restoring, let backupPath = backupDirectory {
            let manifestURL = URL(fileURLWithPath: backupPath).appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifestURL),
               var info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                info["upload_restore_verified"] = true
                info["restore_readback_at"] = ISO8601DateFormatter().string(from: Date())
                try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys, .prettyPrinted]).write(to: manifestURL, options: .atomic)
            }
        }
        if options.json { jsonPrint(["ok": true, "verified": true, "second_backup_directory": url.path]) }
        else { print("upload verified by full read-back; recovery backup: \(url.path)") }
        exit(0)
    } catch {
        if options.json { jsonPrint(["ok": false, "error": "post-upload verification could not be saved"]) }
        printErrorAndExit("post-upload verification failed unexpectedly (upload itself was read-back verified)", 1)
    }
}

// ---------- local utility commands ----------

func runDoctor() -> Never {
    print("micproctl doctor")
    if let target = DeviceConfig.target {
        print("  config: \(DeviceConfig.configURL.path)")
        print("    address = \(target.address)")
        print("    suffix  = …\(target.serialSuffix)")
    } else {
        print("  config: NOT CONFIGURED (\(DeviceConfig.configURL.path))")
        print("    run: micproctl configure --address <BT address> --suffix <6 trailing chars of device name>")
    }
    if let object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: ProtocolMap.url))) as? [String: Any] {
        print("  protocol-map.json: \(object.count) mapped field(s)")
    } else {
        print("  protocol-map.json: absent (pattern/mode/bit-depth unmapped)")
    }
    if let device = SystemBattery.device() {
        print("  paired device: \(device.name ?? "?") [\(device.addressString ?? "?")] connected=\(device.isConnected())")
        if device.isConnected() {
            if let services = device.services as? [IOBluetoothSDPServiceRecord] {
                var channels: [BluetoothRFCOMMChannelID] = []
                for record in services {
                    var channel: BluetoothRFCOMMChannelID = 0
                    if record.getRFCOMMChannelID(&channel) == 0 { channels.append(channel) }
                }
                print("  rfcomm channels published: \(channels.map { String($0) }.joined(separator: ", "))")
                if channels.contains(10) { print("    ch10 (settings/wallpaper control): available") }
            }
            if let level = SystemBattery.micProLevel() { print("  battery (system cache): \(level)%") }
            else { print("  battery (system cache): not reported yet") }
        }
    } else {
        print("  paired device: no paired classic Bluetooth device matches the configuration")
    }
    if let cached = UserDefaults.standard.string(forKey: "micproctl.verifiedPeripheralID") {
        print("  last verified BLE peripheral: \(cached)")
    } else {
        print("  last verified BLE peripheral: none yet")
    }
    exit(0)
}

func runConfigure(list: Bool, address: String?, suffix: String?) -> Never {
    if list {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
            .filter { $0.name?.contains("Mic Pro") == true }
        for device in devices {
            print( "\(device.name ?? "?")\t\(device.addressString?.uppercased().replacingOccurrences(of: "-", with: ":") ?? "?")" )
        }
        if devices.isEmpty { print("no paired devices with 'Mic Pro' in the name"); exit(1) }
        exit(0)
    }
    guard let address = address, let suffix = suffix else {
        if address == nil && suffix == nil { print("usage: micproctl configure --address AA:BB:CC:DD:EE:01 --suffix XXXXXX"); exit(2) }
        printErrorAndExit("configure requires both --address and --suffix")
    }
    let cleaned = address.uppercased().replacingOccurrences(of: "-", with: ":")
    let cleanedSuffix = suffix.uppercased()
    guard cleaned.range(of: "^[0-9A-F]{2}(:[0-9A-F]{2}){5}$", options: .regularExpression) != nil,
          cleaned != "00:00:00:00:00:00", cleaned != "FF:FF:FF:FF:FF:FF" else {
        printErrorAndExit("invalid Bluetooth address '\(address)'")
    }
    guard cleanedSuffix.range(of: "^[A-Z0-9]{6}$", options: .regularExpression) != nil else {
        printErrorAndExit("suffix must be exactly six letters/digits (the last six characters of the device name)")
    }
    var settings: [String: Any] = ["bluetooth_address": cleaned, "serial_suffix": cleanedSuffix, "codex_quota_enabled": false]
    if let existing = try? JSONSerialization.jsonObject(with: Data(contentsOf: DeviceConfig.configURL)) as? [String: Any] {
        if let codex = existing["codex_quota_enabled"] as? Bool { settings["codex_quota_enabled"] = codex }
        if let experimental = existing["experimental_features_enabled"] as? Bool { settings["experimental_features_enabled"] = experimental }
    }
    do {
        try FileManager.default.createDirectory(at: DeviceConfig.dataDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: DeviceConfig.configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: DeviceConfig.configURL.path)
        print("Saved device configuration to \(DeviceConfig.configURL.path)")
        exit(0)
    } catch {
        printErrorAndExit("could not write config: \(error.localizedDescription)", 1)
    }
}


func runAudioConnection(connect: Bool) -> Never {
    guard let device = SystemBattery.device() else { printErrorAndExit("no configured/paired device found; run micproctl doctor", 1) }
    let result = connect ? device.openConnection() : device.closeConnection()
    var waited = 0
    while waited < 10 {
        if device.isConnected() == connect { break }
        Thread.sleep(forTimeInterval: 0.5); waited += 1
    }
    if device.isConnected() == connect {
        print(connect ? "connected as an audio device" : "audio connection closed")
        exit(0)
    }
    printErrorAndExit(String(format: "bluetooth op return=%08X; state not reached — see Bluetooth settings", result), 1)
}

// ---------- entry point ----------

let rawArguments = Array(CommandLine.arguments.dropFirst())
if rawArguments.isEmpty { printHelp(); exit(2) }
let (parsed, parsedRest, problem) = parseOptions(rawArguments)
if let problem = problem { printErrorAndExit(problem, 2) }
var rest = parsedRest
guard !rest.isEmpty else { printHelp(); exit(2) }
let command = rest.removeFirst()
rest = rest.filter { !$0.isEmpty && $0 != "--" }
let options = parsed
let map = ProtocolMap.load()

switch command {
case "help", "--help", "-h": printHelp(); exit(0)
case "version": {
    let upstream = ((try? String(contentsOf: URL(fileURLWithPath: "VERSION"), encoding: .utf8)) ?? "0.8.0").trimmingCharacters(in: .whitespacesAndNewlines)
    print("micproctl \(cliVersion) — fork of george-wyy/mic-pro-mac \(upstream)")
    exit(0)
}()
case "status": runStatus(options: options, map: map)
case "battery":
    let classic = takeOption(&rest, "--classic", takesValue: false) != nil
    runBattery(options: options, classic: classic)
case "settings":
    let raw = takeOption(&rest, "--raw", takesValue: false) != nil
    runSettings(options: options, map: map, raw: raw)
case "set":
    guard rest.count >= 2 else { printErrorAndExit("usage: micproctl set <field> <value>. See: micproctl fields") }
    let name = rest.removeFirst()
    let value = rest.joined(separator: " ")
    runSet(options: options, map: map, fieldName: name.lowercased(), value: value)
case "fields": runFields(map: map)
case "probe":
    guard !rest.isEmpty else { printErrorAndExit("usage: micproctl probe read|diff …") }
    let sub = rest.removeFirst()
    if sub == "diff" { runProbeDiff(options: options, map: map, groupArguments: rest) }
    else if sub == "read" { runProbeRead(options: options, map: map, groupArguments: rest) }
    else { printErrorAndExit("probe expects read or diff") }
case "wallpaper":
    guard !rest.isEmpty else { printErrorAndExit("usage: micproctl wallpaper backup|upload|restore …") }
    let sub = rest.removeFirst()
    switch sub {
    case "backup": runWallpaperBackup(options: options)
    case "upload":
        let backup = takeOption(&rest, "--backup", takesValue: true)
        guard !rest.isEmpty else { printErrorAndExit("usage: micproctl wallpaper upload <image> [--backup DIR]") }
        runWallpaperTransfer(options: options, image: rest.first, backupDirectory: backup, restoring: false)
    case "restore":
        let backup = takeOption(&rest, "--backup", takesValue: true)
        runWallpaperTransfer(options: options, image: nil, backupDirectory: backup ?? latestVerifiedBackup()?.path, restoring: true)
    default: printErrorAndExit("wallpaper expects backup, upload or restore")
    }
case "doctor": runDoctor()
case "configure":
    let list = takeOption(&rest, "--list", takesValue: false) != nil
    let address = takeOption(&rest, "--address", takesValue: true)
    let suffix = takeOption(&rest, "--suffix", takesValue: true)
    runConfigure(list: list, address: address, suffix: suffix)
case "connect-audio": runAudioConnection(connect: true)
case "disconnect-audio": runAudioConnection(connect: false)
default: printErrorAndExit("unknown command '\(command)'; run micproctl help", 2)
}
