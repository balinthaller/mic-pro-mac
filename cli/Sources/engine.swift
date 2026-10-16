import Foundation
import CoreBluetooth
import IOBluetooth
import AppKit

func printDebug(_ text: String) {
    if ProcessInfo.processInfo.environment["MICPROCTL_DEBUG"] == "1" {
        FileHandle.standardError.write(Data(("[debug] " + text + "\n").utf8))
    }
}

/// Collected results of one CLI session, consumed by the command printers.
final class SessionContext {
    var identity: Data?
    var wallpaperInventoryBody: Data?
    var derivedIdentityPrompt: String?
    var common: Data?
    var more: Data?
    var battery: BatteryInfo?
    var batteryAt: Date?
    var batteryError: String?
    var batteryCharacteristicLevel: Int?
    var writeAcknowledged: Bool?
    var writeUnchanged = false
    var rawGroupValues: [UInt16: Data] = [:]
    var rawGroupErrors: [UInt16: String] = [:]
    var wallpaperFile: Data?
    var wallpaperManifest: Data?
    var wallpaperMissingCRC: Bool?
    var verifiedBackupURL: URL?
    var transportName: String?
    var warnings: [String] = []
    func group(_ group: UInt16) -> Data? { group == 0x1000 ? common : group == 0x1012 ? more : nil }
    func replaceGroup(_ group: UInt16, values: Data) {
        if group == 0x1000 { common = values } else if group == 0x1012 { more = values }
    }
}

/// One transaction step; the driver runs steps strictly one at a time
/// (upstream rule: never overlap device control transactions).
protocol SessionPlan: AnyObject {
    var planTimeout: TimeInterval { get }
    var idleFrameTimeout: TimeInterval? { get }
    var finished: Bool { get }
    var failedText: String? { get }
    var awaitingConfirmation: Bool { get }
    func outgoing(now: Date) -> [Data]
    func consume(frame: Frame) -> [Data]
    func timeout(now: Date)
    func physicalConfirmationPush()
}

extension SessionPlan {
    var idleFrameTimeout: TimeInterval? { nil }
    var awaitingConfirmation: Bool { false }
    func physicalConfirmationPush() {}
}

protocol TransportChannel: AnyObject {
    var name: String { get }
    var isOpen: Bool { get }
    var onOpen: (() -> Void)? { get set }
    var onFrames: ((Frame) -> Void)? { get set }
    var onFail: ((String, TransportStage) -> Void)? { get set }
    func start()
    func write(_ data: Data)
    func close()
}

/// Wrapper around the upstream read ladder:
/// identity -> authorization (+physical confirm) -> common -> more -> (battery).
final class ReadOp: SessionPlan {
    let plan: AppControlReadPlan
    init(includeBattery: Bool) { plan = AppControlReadPlan(includeBattery: includeBattery) }
    var planTimeout: TimeInterval { 150 }
    var finished: Bool {
        if case .ready = plan.state { return true }
        if case .failed = plan.state { return true }
        return false
    }
    var failedText: String? { plan.error }
    var awaitingConfirmation: Bool {
        if case .awaitingConfirmation = plan.state { return true }
        return false
    }
    func outgoing(now: Date) -> [Data] { plan.nextRequest().map { [$0] } ?? [] }
    func consume(frame: Frame) -> [Data] { plan.consume(frame); return [] }
    func timeout(now: Date) { plan.timeout() }
    func physicalConfirmationPush() { plan.confirmationProvided() }
}

/// Read arbitrary settings groups, read-only. Identity must already be
/// captured (RunOp precedes it in the same session).
final class RawGroupReadOp: SessionPlan {
    private enum State: Equatable { case requesting(Int), ready, failed }
    let groups: [UInt16]
    let identity: Data
    private var state: State
    private(set) var values: [UInt16: Data] = [:]
    private(set) var errors: [UInt16: String] = [:]
    private var pending: (command: UInt16, message: UInt16)?
    private var message: UInt16 = 0x40
    init(identity: Data, groups: [UInt16]) {
        self.identity = identity
        self.groups = groups
        self.state = groups.isEmpty ? .ready : .requesting(0)
    }
    var planTimeout: TimeInterval { 150 }
    var finished: Bool { state == .ready || state == .failed }
    var failedText: String? { nil }
    private func request(group: UInt16) -> Data {
        message &+= 1; pending = (0x1014, message)
        let body = Data([UInt8(group & 255), UInt8(group >> 8), 0, 0]) + identity
        let payload = Data([UInt8(message & 255), UInt8(message >> 8)]) + body
        return Data([0xFE,0xEF,1,0x14,0x10,0,0,UInt8(payload.count),0]) + payload
    }
    func outgoing(now: Date) -> [Data] {
        guard pending == nil, case .requesting(let index) = state else { return [] }
        return [request(group: groups[index])]
    }
    func consume(frame: Frame) -> [Data] {
        guard frame.sequence >> 14 == 0, let pending = pending, frame.command == pending.command,
              frame.payload.count >= 3, UInt16(frame.payload[0]) | UInt16(frame.payload[1]) << 8 == pending.message else { return [] }
        self.pending = nil
        guard case .requesting(let index) = state else { return [] }
        let group = groups[index]
        let body = Data(frame.payload.dropFirst(3))
        if frame.payload[2] != 0 { errors[group] = "device status=\(frame.payload[2])"; advance(); return [] }
        guard body.count >= 34, body.prefix(32) == identity,
              UInt16(body[32]) | UInt16(body[33]) << 8 == group else {
            errors[group] = "unexpected envelope (identity or group mismatch)"
            advance()
            return []
        }
        values[group] = Data(body[34...])
        advance()
        return []
    }
    func timeout(now: Date) {
        pending = nil
        guard case .requesting(let index) = state else { return }
        errors[groups[index]] = "timeout"
        advance()
    }
    private func advance() {
        guard case .requesting(let index) = state else { return }
        state = index + 1 < groups.count ? .requesting(index + 1) : .ready
    }
}

/// Guarded whole-group write with full read-back verification.
/// Ladder: preflight read -> (propose) -> single write -> verify.
/// Writes are never automatically retried; a write timeout still triggers a
/// fresh read-back to learn whether it landed (upstream discipline).
final class SettingsWriteOp: SessionPlan {
    enum State: Equatable { case guardRead, write, verify, ready, unchanged, failed }
    let group: UInt16
    let identity: Data
    let proposer: (Data) throws -> Data
    private(set) var state: State = .guardRead
    private(set) var failed: String?
    private(set) var acked = false
    private(set) var proposedValues: Data?
    private(set) var verifiedValues: Data?
    private(set) var originalValues: Data?
    private var pending: (command: UInt16, message: UInt16)?
    private var message: UInt16 = 0x80
    init(group: UInt16, identity: Data, proposer: @escaping (Data) throws -> Data) throws {
        guard identity.count == 32 else { throw CLIError.usage("identity invalid") }
        guard group == 0x1000 || group == 0x1012 else { throw CLIError.usage("writes only target groups 0x1000 and 0x1012") }
        self.group = group
        self.identity = identity
        self.proposer = proposer
    }
    var planTimeout: TimeInterval { 60 }
    var finished: Bool {
        switch state { case .ready, .unchanged, .failed: return true; default: return false }
    }
    var failedText: String? { failed }
    private func encode(values: Data) -> Data? {
        group == 0x1000 ? (try? commonSettingsWriteBody(identity: identity, values: values))
                        : (try? moreSettingsWriteBody(identity: identity, values: values))
    }
    func outgoing(now: Date) -> [Data] {
        guard pending == nil else { return [] }
        let command: UInt16; let body: Data
        switch state {
        case .guardRead, .verify:
            command = 0x1014
            body = Data([UInt8(group & 255), UInt8(group >> 8), 0, 0]) + identity
        case .write:
            guard let proposed = proposedValues, let encoded = encode(values: proposed) else {
                failed = "proposed group failed validation; refusing to write"
                state = .failed
                return []
            }
            command = 0x1015
            body = encoded
        default: return []
        }
        message &+= 1; pending = (command, message)
        let payload = Data([UInt8(message & 255), UInt8(message >> 8)]) + body
        return [Data([0xFE,0xEF,1,UInt8(command & 255),UInt8(command >> 8),0,0,UInt8(payload.count),0]) + payload]
    }
    func consume(frame: Frame) -> [Data] {
        guard frame.sequence >> 14 == 0, let pending = pending, frame.command == pending.command,
              frame.payload.count >= 3, UInt16(frame.payload[0]) | UInt16(frame.payload[1]) << 8 == pending.message else { return [] }
        self.pending = nil
        let body = Data(frame.payload.dropFirst(3))
        switch state {
        case .write:
            acked = frame.payload[2] == 0 && body.isEmpty
            state = .verify
            return []
        case .guardRead, .verify:
            guard frame.payload[2] == 0 else { failed = "device rejected the group read (status=\(frame.payload[2]))"; state = .failed; return [] }
            guard let values = try? settingsResponse(body, identity: identity, group: group) else {
                failed = "read-back envelope invalid (identity or format mismatch)"
                state = .failed
                return []
            }
            if state == .guardRead {
                originalValues = values
                do { proposedValues = try proposer(values) }
                catch CLIError.usage(let message) { failed = message; state = .failed; return [] }
                catch { failed = "could not compose the change"; state = .failed; return [] }
                if proposedValues == values { state = .unchanged; return [] }
                state = .write
            } else {
                guard values == proposedValues else { failed = "write not confirmed: read-back differs from the proposal"; state = .failed; return [] }
                verifiedValues = values
                state = .ready
            }
            return []
        default: return []
        }
    }
    func timeout(now: Date) {
        pending = nil
        switch state {
        case .write: state = .verify
        case .guardRead, .verify: failed = "request timeout"; state = .failed
        default: break
        }
    }
}

/// Upstream wallpaper upload state machine, batched ten frames at a time.
final class WallpaperUploadOp: SessionPlan {
    let plan: WallpaperUploadPlan
    init(identity: Data, panel: Data, png: Data) throws { plan = try WallpaperUploadPlan(identity: identity, panel: panel, png: png) }
    var planTimeout: TimeInterval { 420 }
    var idleFrameTimeout: TimeInterval? { 20 }
    var finished: Bool {
        switch plan.state { case .ready, .failed: return true; default: return false }
    }
    var failedText: String? { plan.error }
    func outgoing(now: Date) -> [Data] {
        printDebug("upload phase \(plan.state)")
        return plan.requests()
    }
    func consume(frame: Frame) -> [Data] { plan.consume(frame); return [] }
    func timeout(now: Date) { plan.timeout() }
}

/// Upstream wallpaper read-back plan; answers device ACKs from consume().
final class WallpaperReadOp: SessionPlan {
    let plan: WallpaperReadPlan
    init(identity: Data) { plan = WallpaperReadPlan(identity: identity) }
    var planTimeout: TimeInterval { 240 }
    var idleFrameTimeout: TimeInterval? { 30 }
    var finished: Bool {
        switch plan.state { case .ready, .failed: return true; default: return false }
    }
    var failedText: String? { plan.error }
    func outgoing(now: Date) -> [Data] { plan.nextRequest().map { [$0] } ?? [] }
    func consume(frame: Frame) -> [Data] {
        printDebug("wallpaper read frame cmd=\(String(format: "%04X", frame.command)) len=\(frame.payload.count)")
        let ack = plan.consume(frame)
        return ack.map { [$0] } ?? []
    }
    func timeout(now: Date) { plan.timeout() }
}

/// No-op wait (e-ink refresh after an upload ACKs).
final class SleepOp: SessionPlan {
    let until: Date
    let label: String
    private let timeoutValue: TimeInterval
    init(seconds: TimeInterval, label: String) {
        until = Date().addingTimeInterval(seconds)
        timeoutValue = seconds + 5
        self.label = label
    }
    var planTimeout: TimeInterval { .infinity }
    var finished: Bool { Date() >= until }
    var failedText: String? { nil }
    func outgoing(now: Date) -> [Data] { [] }
    func consume(frame: Frame) -> [Data] { [] }
    func timeout(now: Date) {}
}

/// Runs a sequence of steps over one transport, one active plan at a time,
/// then stops the shared run loop and reports the exit code.
final class Driver: NSObject {
    struct Item { let name: String; let make: (Driver) -> SessionPlan?; let onDone: (Driver) -> Void }
    let jsonOutput: Bool
    private(set) var context = SessionContext()
    private var items: [Item]
    private var cursor = 0
    private var transport: TransportChannel?
    private var lastRequestAt: Date?
    private var lastFrameAt: Date?
    private var promptedConfirmation = false
    private let startedAt = Date()
    private let hardDeadline: TimeInterval
    private var exitCallback: ((Int) -> Void)?
    private var requestedClose = false
    var itemCreationError: String?
    var jsonLines: [String] = []
    private var activeItem: Item?
    private var activePlan: SessionPlan?
    private var timer: Timer?
    let allowBleFallback: Bool
    let rfcommChannelOverride: BluetoothRFCOMMChannelID?
    init(jsonOutput: Bool, hardDeadline: TimeInterval = 2400, items: [Item],
         allowBleFallback: Bool = true, rfcommChannelOverride: BluetoothRFCOMMChannelID? = nil) {
        self.jsonOutput = jsonOutput
        self.hardDeadline = hardDeadline
        self.items = items
        self.allowBleFallback = allowBleFallback
        self.rfcommChannelOverride = rfcommChannelOverride
        super.init()
    }

    func run(mode: TransportMode, completion: @escaping (Int) -> Void) {
        exitCallback = completion
        // IOBluetooth's notification machinery must be initialized BEFORE the
        // NSApplication loop starts: a first touch inside the loop silently
        // breaks async callback delivery (bisected and reproduced locally).
        _ = IOBluetoothDevice.pairedDevices()
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        // The transport must be opened from INSIDE the running app loop —
        // IOBluetooth async callbacks only deliver then (proven on this toolchain).
        let boot = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in self?.activateAndRun(mode) }
        RunLoop.main.add(boot, forMode: .default)
        let tick = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = tick
        RunLoop.main.add(tick, forMode: .default)
        application.run()
    }

    private func activateAndRun(_ mode: TransportMode) {
        var fellBack = false
        func activate(_ chosen: TransportMode) -> Bool {
            transport = makeTransport(mode: chosen, channelOverride: rfcommChannelOverride, driver: self)
            guard let channel = transport else { return false }
            context.transportName = channel.name
            printDebug("transport: \(channel.name)")
            channel.onOpen = { [weak self] in self?.tick() }
            channel.onFrames = { [weak self] frame in self?.consume(frame: frame) }
            channel.onFail = { [weak self] message, stage in
                guard let self = self else { return }
                let primaryWasRfcomm = channel is RfcommChannel
                if stage == .open, !fellBack, self.allowBleFallback {
                    let fallbackMode: TransportMode = primaryWasRfcomm ? .ble : .rfcomm
                    if fallbackMode == .rfcomm && RfcommChannel.selectSettingsChannel(preferred: rfcommChannelOverride ?? 10) == nil {
                        self.fail(transportMessage: message)
                        return
                    }
                    fellBack = true
                    self.transport?.close()
                    self.printLine(primaryWasRfcomm
                        ? "rfcomm control unusable; retrying the same operation over BLE…"
                        : "ble control unusable; retrying over the RFCOMM serial…")
                    self.printLine(message)
                    // restart the session cleanly over the other transport
                    self.activeItem = nil; self.activePlan = nil
                    self.cursor = 0
                    self.lastRequestAt = nil; self.lastFrameAt = nil
                    self.promptedConfirmation = false
                    self.context.identity = nil
                    self.context.wallpaperInventoryBody = nil
                    self.context.common = nil
                    self.context.more = nil
                    if !activate(fallbackMode) { self.fail(transportMessage: message) }
                    return
                }
                self.fail(transportMessage: message)
            }
            channel.start()
            return true
        }
        guard activate(mode) else {
            requestedClose = true
            exitCallback?(2)
            stopApplication()
            return
        }
    }

    /// Stops the accessory app loop while preserving our exit code
    /// (terminate() would exit(0) and swallow it).
    private func stopApplication() {
        let application = NSApplication.shared
        application.stop(nil)
        let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)
        if let event = event { application.postEvent(event, atStart: true) }
    }

    private func fail(transportMessage: String) {
        guard !requestedClose else { return }
        context.warnings.append(transportMessage)
        finish(exitCode: 1, message: transportMessage)
    }

    private func consume(frame: Frame) {
        lastFrameAt = Date()
        guard let plan = activePlan, !plan.finished else { return }
        if frame.command == 0x100E, frame.sequence == 0, frame.payload.count == 38 {
            if let identity = context.identity, frame.payload.count >= 33,
               Data(frame.payload[2..<33]) != identity.prefix(31) {
                printDebug("physical confirmation push for a different identity; ignored")
                return
            }
            printLine("device pushed physical confirmation (0x100E); continuing")
            plan.physicalConfirmationPush()
            return
        }
        let responses = plan.consume(frame: frame)
        lastRequestAt = nil
        for response in responses { transport?.write(response) }
    }

    private func tick() {
        guard !requestedClose else { return }
        if Date().timeIntervalSince(startedAt) > hardDeadline { finish(exitCode: 1, message: "overall session timeout"); return }
        // Nothing may hang silently waiting for a transport to open.
        if let transport = transport, !transport.isOpen,
           Date().timeIntervalSince(startedAt) > 90 {
            finish(exitCode: 1, message: "transport \(transport.name) never opened within 90 s — see the hints printed above (link down? permission prompt pending? device asleep?)")
            return
        }
        if let plan = activePlan, plan.finished, let item = activeItem {
            if let failed = plan.failedText {
                context.warnings.append("\(item.name): \(failed)")
                finish(exitCode: 1, message: "\(item.name): \(failed)")
                return
            }
            item.onDone(self)
            cursor += 1
            activeItem = nil; activePlan = nil
            lastRequestAt = nil; lastFrameAt = nil
            promptedConfirmation = false
            printDebug("finished step \(item.name)")
        }
        if activePlan == nil {
            guard cursor < items.count else { finish(exitCode: 0, message: nil); return }
            let item = items[cursor]
            guard let plan = item.make(self) else {
                finish(exitCode: 1, message: itemCreationError ?? "\(item.name): step could not be prepared")
                return
            }
            activeItem = item; activePlan = plan
            printDebug("starting step \(item.name)")
        }
        guard let plan = activePlan, let transport = transport, transport.isOpen, !plan.finished else { return }
        if plan.awaitingConfirmation && !promptedConfirmation {
            promptedConfirmation = true
            printLine("AUTHORIZATION: single-press the power button on the Mic Pro now, then wait…")
        }
        if let last = lastFrameAt, let idle = plan.idleFrameTimeout, Date().timeIntervalSince(last) > idle {
            lastFrameAt = nil; lastRequestAt = nil
            plan.timeout(now: Date())
            return
        }
        if let last = lastRequestAt, Date().timeIntervalSince(last) > plan.planTimeout, plan.planTimeout != .infinity {
            lastRequestAt = nil
            plan.timeout(now: Date())
            return
        }
        if lastRequestAt == nil {
            let outgoing = plan.outgoing(now: Date())
            if !outgoing.isEmpty {
                for data in outgoing { transport.write(data) }
                lastRequestAt = Date()
            }
        }
    }

    private func finish(exitCode: Int, message: String?) {
        guard !requestedClose else { return }
        requestedClose = true
        // Text-mode error printing belongs to the command's failure handler
        // (sessionFailure) so the message is emitted exactly once.
        if let message = message, jsonOutput { jsonLines.append(message) }
        transport?.close()
        exitCallback?(exitCode)
        stopApplication()
    }

    func printLine(_ text: String) {
        if !jsonOutput { print(text) }
        else { jsonLines.append(text) }
    }
}
