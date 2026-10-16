import Foundation

// Field maps for the two known settings groups. Fact source: upstream
// Protocol.swift / main.swift decoding, validated on TX firmware 2.0.2.4.
// Unknown bytes are still displayed by `settings` and can be mapped at
// runtime (see protocol-map.json) so pattern/mode/bit-depth can be wired
// in without rebuilding once `probe diff` identifies them.

enum FieldKind { case boolean, gainDB, enumValues }

struct FieldSpec {
    let name: String
    let group: UInt16
    let index: Int
    let kind: FieldKind
    let values: [String: UInt8]
    /// Alternate spellings accepted at parse time. Never used for decode,
    /// which needs exactly one name per value to stay deterministic.
    var aliases: [String: UInt8] = [:]
    let summary: String
    var valueText: String {
        switch kind {
        case .boolean: return "on|off"
        case .gainDB: return "-12..12 (dB)"
        case .enumValues: return values.keys.isEmpty ? "(no values mapped)" : values.keys.sorted().joined(separator: "|")
        }
    }
}

let knownFields: [FieldSpec] = [
    FieldSpec(name: "mute", group: 0x1000, index: 1, kind: .boolean, values: [:], summary: "mute the transmitter"),
    FieldSpec(name: "gain", group: 0x1000, index: 2, kind: .gainDB, values: [:], summary: "input gain, -12...12 dB"),
    FieldSpec(name: "noise", group: 0x1000, index: 3, kind: .enumValues,
              values: ["off": 0, "low": 1, "high": 2], aliases: ["on": 1],
              summary: "noise reduction level (app labels: off/low/high)"),
    FieldSpec(name: "pattern", group: 0x1012, index: 6, kind: .enumValues,
              values: ["omni": 0, "cardioid": 1, "figure8": 2, "voicefocus": 3],
              summary: "sound direction / polar pattern (mapped by probe diff on firmware of 2026-01)"),
    FieldSpec(name: "stereo", group: 0x1012, index: 1, kind: .boolean, values: [:], summary: "stereo mode (off = mono)"),
    FieldSpec(name: "float32", group: 0x1012, index: 0, kind: .boolean, values: [:], summary: "32-bit float internal recording"),
    FieldSpec(name: "lowcut", group: 0x1012, index: 4, kind: .boolean, values: [:], summary: "low-cut filter"),
    FieldSpec(name: "childlock", group: 0x1012, index: 8, kind: .boolean, values: [:], summary: "button lock"),
    FieldSpec(name: "vibration", group: 0x1012, index: 9, kind: .boolean, values: [:], summary: "haptic feedback"),
    FieldSpec(name: "led", group: 0x1012, index: 10, kind: .boolean, values: [:], summary: "LED indicator"),
]

let commonLabels = ["recording state", "mute", "gain (dB Int8)", "noise reduction", "unknown[4]", "unknown[5]"]
let moreLabels = ["32-bit float", "stereo (mono when off)", "unknown[2]", "unknown[3]", "low-cut", "unknown[5]", "sound direction", "unknown[7]", "child lock", "vibration", "LED indicator", "unknown[11]"]

enum CLIError: Error { case usage(String), failed(String) }

/// Runtime extension loaded from ~/Library/Application Support/MicProMac/protocol-map.json.
/// Example:
/// {"pattern":{"group":"0x1012","index":6,"values":{"omni":0,"cardioid":1,"figure8":2,"stereo":3}}}
struct ProtocolMap {
    let fields: [FieldSpec]
    static let url: URL = DeviceConfig.dataDirectory.appendingPathComponent("protocol-map.json")
    static func load(url: URL = ProtocolMap.url) -> ProtocolMap {
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ProtocolMap(fields: []) }
        var result: [FieldSpec] = []
        for (name, raw) in object.sorted(by: { String(describing: $0.key) < String(describing: $1.key) }) {
            guard let entry = raw as? [String: Any],
                  let groupText = entry["group"] as? String,
                  let group = parseHex16(groupText),
                  let indexValue = entry["index"] as? Int,
                  let rawValues = entry["values"] as? [String: Any] else { continue }
            var values: [String: UInt8] = [:]
            for (key, value) in rawValues where values[key] == nil {
                if let number = value as? NSNumber { values[key] = UInt8(truncating: number) }
            }
            let summary = entry["summary"] as? String ?? "runtime-mapped field"
            result.append(FieldSpec(name: name, group: group, index: indexValue, kind: .enumValues, values: values, summary: summary))
        }
        return ProtocolMap(fields: result)
    }
}

func parseHex16(_ text: String) -> UInt16? {
    let cleaned = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
    return UInt16(cleaned, radix: 16)
}

func parseHexGroup(_ text: String) -> UInt16? {
    parseHex16(text)
}

func allFields(map: ProtocolMap) -> [FieldSpec] { knownFields + map.fields }

func field(named name: String, map: ProtocolMap) -> FieldSpec? { allFields(map: map).first { $0.name == name } }

func decodeField(_ spec: FieldSpec, from group: Data) -> String {
    guard group.count > spec.index else { return "?" }
    let byte = group[group.startIndex + spec.index]
    switch spec.kind {
    case .boolean: return byte == 0 ? "off" : byte == 1 ? "on" : "unknown(\(byte))"
    case .gainDB: return String(Int(Int8(bitPattern: byte))) + " dB"
    case .enumValues:
        if let name = spec.values.first(where: { $0.value == byte })?.key { return name }
        return "unknown(\(byte))"
    }
}

/// Build the proposed whole-group snapshot after changing one field, or throw a usage error.
func proposeChange(_ spec: FieldSpec, argument: String, current: Data) throws -> Data {
    guard current.count > spec.index else { throw CLIError.failed("field index \(spec.index) outside group") }
    var result = current
    let base = result.startIndex + spec.index
    switch spec.kind {
    case .boolean:
        guard argument == "on" || argument == "off" else { throw CLIError.usage("\(spec.name) expects on|off") }
        result[base] = argument == "on" ? 1 : 0
    case .gainDB:
        guard let value = Int(argument), (-12...12).contains(value) else { throw CLIError.usage("gain expects an integer -12...12") }
        result[base] = UInt8(bitPattern: Int8(value))
    case .enumValues:
        if let value = spec.values[argument] {
            result[base] = value
        } else if let value = spec.aliases[argument] {
            result[base] = value
        } else {
            throw CLIError.usage("\(spec.name) expects one of: \(spec.values.keys.sorted().joined(separator: "|"))")
        }
    }
    return result
}

// ---------- presets ----------

struct PresetChange { let field: String; let value: String; let changed: Bool }

/// Built-in profiles. "default" is the fork owner's preferred steady state;
/// users can add their own (and override "default") in presets.json.
let builtinPresets: [String: [String: String]] = [
    "default": ["stereo": "on", "float32": "on", "vibration": "on", "led": "on",
                "pattern": "omni", "lowcut": "off", "noise": "off", "gain": "0"],
    // Same base state as "default" with spoken-word overrides; the merged
    // writer means switching default<->voice only rewrites differing bytes.
    "voice": ["stereo": "on", "float32": "on", "vibration": "on", "led": "on",
              "pattern": "voicefocus", "lowcut": "on", "noise": "low", "gain": "0"],
]

enum PresetsFile {
    static let url = DeviceConfig.dataDirectory.appendingPathComponent("presets.json")
}

func loadPresetProfiles() -> [String: [String: String]] {
    guard let data = try? Data(contentsOf: PresetsFile.url),
          let object = try? JSONSerialization.jsonObject(with: data),
          let profiles = object as? [String: [String: String]] else { return [:] }
    return profiles
}

/// Folds every preset entry that targets `group` into the group's current
/// bytes. Pure: no I/O and no device, so offline tests cover the merge and
/// per-field diff logic. Fields outside `group` are ignored.
func applyPreset(entries: [(field: FieldSpec, value: String)], group: UInt16,
                 current: Data) throws -> (Data, [PresetChange]) {
    var merged = current
    var changes: [PresetChange] = []
    for entry in entries where entry.field.group == group {
        let index = merged.startIndex + Int(entry.field.index)
        let before = index < merged.endIndex ? merged[index] : nil
        merged = try proposeChange(entry.field, argument: entry.value, current: merged)
        let after = index < merged.endIndex ? merged[index] : nil
        changes.append(PresetChange(field: entry.field.name, value: entry.value, changed: before != after))
    }
    return (merged, changes)
}

func hexDump(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined(separator: " ") }

func decodeGroup(_ group: UInt16, _ values: Data, map: ProtocolMap) -> [(position: Int, label: String, value: String)] {
    let labels = group == 0x1000 ? commonLabels : group == 0x1012 ? moreLabels : []
    var rows: [(Int, String, String)] = []
    for index in 0..<values.count {
        let byte = UInt8(values[values.startIndex + index])
        var text = "0x\(String(format: "%02X", byte))"
        if let spec = allFields(map: map).first(where: { $0.group == group && $0.index == index }) {
            switch spec.kind {
            case .boolean: text = byte == 0 ? "off" : byte == 1 ? "on" : text
            case .gainDB: text = String(Int(Int8(bitPattern: byte))) + " dB"
            case .enumValues: if let name = spec.values.first(where: { $0.value == byte })?.key { text = name }
            }
        } else if let known = index < labels.count ? labels[index] : nil, known.contains("unknown") == false {
            if group == 0x1000 {
                if index == 0 { text = byte == 1 ? "active" : "inactive" }
                if index == 3 { text = byte == 0 ? "off" : byte == 1 ? "on" : byte == 2 ? "high" : text }
            }
        }
        let fallback = index < labels.count ? labels[index] : "byte[\(index)]"
        rows.append((index, fallback, text))
    }
    return rows
}
