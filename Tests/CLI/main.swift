import Foundation

// Field semantics
let gain = knownFields.first { $0.name == "gain" }!
let noise = knownFields.first { $0.name == "noise" }!
let led = knownFields.first { $0.name == "led" }!
let float32 = knownFields.first { $0.name == "float32" }!

var common = Data([1, 0, 5, 2, 0, 1])
var proposed = try! proposeChange(gain, argument: "-6", current: common)
assert(proposed.count == 6 && proposed[2] == UInt8(bitPattern: Int8(-6)) && proposed[0] == 1 && proposed[5] == 1)
assert((try? proposeChange(gain, argument: "13", current: common)) == nil)
assert((try? proposeChange(gain, argument: "abc", current: common)) == nil)
proposed = try! proposeChange(noise, argument: "off", current: common)
assert(proposed[3] == 0 && proposed[2] == 5)
assert((try? proposeChange(noise, argument: "windy", current: common)) == nil)

var more = Data([1, 0, 0, 0, 0, 2, 3, 1, 0, 1, 0, 0])
assert(try! proposeChange(led, argument: "on", current: more)[10] == 1)
assert(try! proposeChange(float32, argument: "off", current: more)[0] == 0)
// gain over a More-group buffer is rejected downstream by SettingsWriteOp's
// group validation (commonSettingsWriteBody requires the 6-byte Common group).

assert(decodeField(gain, from: common) == "5 dB")
assert(decodeField(noise, from: common) == "high")
assert(decodeField(led, from: Data([1, 0, 0, 0, 0, 2, 3, 1, 0, 1, 1, 0])) == "on")
assert(hexDump(Data([0xAB, 0xCD])) == "AB CD")

// Runtime protocol map
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("micproctl-test-map-\(UUID().uuidString).json")
let mapJSON = """
{"pattern":{"group":"0x1012","index":6,"values":{"omni":0,"cardioid":1,"figure8":2}},
 "bitdepth":{"group":"0x1012","index":5,"values":{"16":0,"24":1,"32f":2}}}
"""
try! Data(mapJSON.utf8).write(to: temporary)
let map = ProtocolMap.load(url: temporary)
let loaded = ProtocolMap.load(url: temporary)
assert(field(named: "pattern", map: loaded) != nil)
assert(field(named: "pattern", map: loaded)!.values["figure8"] == 2)
assert(field(named: "bitdepth", map: loaded)!.group == 0x1012)
assert(try! proposeChange(field(named: "pattern", map: loaded)!, argument: "figure8", current: more)[6] == 2)
assert((try? proposeChange(field(named: "pattern", map: loaded)!, argument: "stereo", current: more)) == nil)
try! FileManager.default.removeItem(at: temporary)
assert(parseHexGroup("0x1013") == 0x1013 && parseHexGroup("1010") == 0x1010)
assert(parseTransportMode("rfcomm") == .rfcomm && parseTransportMode("nope") == nil)

// Guarded write ladder: preflight read -> single write -> read-back verify
let identity = Data(repeating: 65, count: 32)
func outgoingFrame(_ op: SettingsWriteOp) -> Frame? {
    var stream = FrameStream()
    guard let data = op.outgoing(now: Date()).first else { return nil }
    return stream.append(data).first
}
func groupReply(_ query: Frame, identity: Data, group: UInt16, values: Data) -> Frame {
    Frame(command: query.command, sequence: 0,
          payload: query.payload.prefix(2) + Data([0]) + identity + Data([UInt8(group & 255), UInt8(group >> 8)]) + values + Data([0, 0, 0]))
}
func ackReply(_ query: Frame) -> Frame {
    Frame(command: query.command, sequence: 0, payload: query.payload.prefix(2) + Data([0]))
}
func statusReply(_ query: Frame, status: UInt8) -> Frame {
    Frame(command: query.command, sequence: 0, payload: query.payload.prefix(2) + Data([status]))
}

var opProbe = try! SettingsWriteOp(group: 0x1000, identity: identity) { current in
    try proposeChange(gain, argument: "-6", current: current)
}
assert(opProbe.proposedValues == nil)
let guardQuery = outgoingFrame(opProbe)!
assert(guardQuery.command == 0x1014 && guardQuery.payload[2] == UInt8(0x1000 & 255) && guardQuery.payload[3] == 0x10)
opProbe.consume(frame: statusReply(guardQuery, status: 3))
assert(opProbe.state == .failed && opProbe.failedText != nil)

opProbe = try! SettingsWriteOp(group: 0x1000, identity: identity) { current in
    try proposeChange(gain, argument: "-6", current: current)
}
opProbe.consume(frame: groupReply(outgoingFrame(opProbe)!, identity: identity, group: 0x1000, values: common))
assert(opProbe.state == .write && opProbe.proposedValues == Data([1, 0, 0xFA, 2, 0, 1]))
let writeQuery = outgoingFrame(opProbe)!
assert(writeQuery.command == 0x1015 && writeQuery.payload.dropFirst(2).prefix(4) == Data([1, 0, 0x10]) + identity.prefix(1))
opProbe.consume(frame: ackReply(writeQuery))
assert(opProbe.state == .verify && opProbe.acked)
opProbe.consume(frame: groupReply(outgoingFrame(opProbe)!, identity: identity, group: 0x1000, values: opProbe.proposedValues!))
assert(opProbe.state == .ready && opProbe.verifiedValues == opProbe.proposedValues && opProbe.finished)

// Write timeout must fall through to a single verification read, never a write retry
var timeoutOp = try! SettingsWriteOp(group: 0x1000, identity: identity) { current in
    try proposeChange(noise, argument: "off", current: current)
}
timeoutOp.consume(frame: groupReply(outgoingFrame(timeoutOp)!, identity: identity, group: 0x1000, values: common))
_ = outgoingFrame(timeoutOp)!
timeoutOp.timeout(now: Date())
assert(timeoutOp.state == .verify)
let recovery = outgoingFrame(timeoutOp)!
assert(recovery.command == 0x1014)
assert(outgoingFrame(timeoutOp) == nil) // one outstanding request at a time; no retry burst

// External mutation between proposal and write aborts the transaction
var conflict = try! SettingsWriteOp(group: 0x1000, identity: identity) { current in
    try proposeChange(gain, argument: "-6", current: current)
}
conflict.consume(frame: groupReply(outgoingFrame(conflict)!, identity: identity, group: 0x1000, values: Data([1, 1, 5, 2, 0, 1])))
let conflictWrite = outgoingFrame(conflict)!
conflict.consume(frame: ackReply(conflictWrite))
conflict.consume(frame: groupReply(outgoingFrame(conflict)!, identity: identity, group: 0x1000, values: common))
assert(conflict.state == .failed && conflict.acked) // acked but read-back mismatch aborts

// Same-value request is a clean no-op instead of a write
var unchanged = try! SettingsWriteOp(group: 0x1012, identity: identity) { current in current }
unchanged.consume(frame: groupReply(outgoingFrame(unchanged)!, identity: identity, group: 0x1012, values: more))
assert(unchanged.state == .unchanged && unchanged.finished && unchanged.failedText == nil)

// Refuse writes validated against upstream group constraints
var invalid = try! SettingsWriteOp(group: 0x1000, identity: identity) { current in
    var result = current; result[2] = 0x7F; return result
}
invalid.consume(frame: groupReply(outgoingFrame(invalid)!, identity: identity, group: 0x1000, values: common))
assert(invalid.state == .write) // proposer output accepted; rejection happens at request-build time
assert(invalid.outgoing(now: Date()).isEmpty && invalid.state == .failed)

// Raw group reads: several groups in sequence, errors recorded per group
let raw = RawGroupReadOp(identity: identity, groups: [0x1011, 0x1013])
func rawReply(_ query: Frame, identity: Data, group: UInt16, values: Data) -> Frame {
    Frame(command: query.command, sequence: 0,
          payload: query.payload.prefix(2) + Data([0]) + identity + Data([UInt8(group & 255), UInt8(group >> 8)]) + values + Data([0, 0, 0]))
}
let rawFirst = raw.outgoing(now: Date()).first!
var stream = FrameStream()
let rawFirstFrame = stream.append(rawFirst).first!
raw.consume(frame: rawReply(rawFirstFrame, identity: identity, group: 0x1011, values: Data([9, 8, 7])))
// raw reads store the full tail after the group header (including the 3-byte zero suffix)
assert(raw.values[0x1011] == Data([9, 8, 7, 0, 0, 0]))
let rawSecondFrame = stream.append(raw.outgoing(now: Date()).first!).first!
raw.consume(frame: rawReply(rawSecondFrame, identity: identity, group: 0x1013, values: Data([1])))
assert(raw.values[0x1013] == Data([1, 0, 0, 0]))
assert(raw.finished)

let failing = RawGroupReadOp(identity: identity, groups: [0x1020])
let failingQuery = stream.append(failing.outgoing(now: Date()).first!).first!
failing.consume(frame: statusReply(failingQuery, status: 4))
assert(failing.errors[0x1020] != nil && failing.values.isEmpty && failing.finished)

// Identity/group envelope mismatch is rejected, not stored
let mismatch = RawGroupReadOp(identity: identity, groups: [0x1011])
let mismatchQuery = stream.append(mismatch.outgoing(now: Date()).first!).first!
mismatch.consume(frame: rawReply(mismatchQuery, identity: Data(repeating: 66, count: 32), group: 0x1011, values: Data([1])))
assert(mismatch.errors[0x1011] != nil && mismatch.values.isEmpty)

print("PASS: field semantics, runtime protocol map, guarded write ladder (ack, verify, external-change abort, no-op same-value, validation refusal, write timeout -> verify-only), raw group reads and envelope guards")

// Preset fold: group-merged writes with per-field diff reporting
do {
    let stereo = knownFields.first { $0.name == "stereo" }!
    let float = knownFields.first { $0.name == "float32" }!
    let pattern = knownFields.first { $0.name == "pattern" }!
    let gain = knownFields.first { $0.name == "gain" }!
    let entrySpecs = [(stereo, "on"), (float, "on"), (pattern, "omni")]
    let typed: [(field: FieldSpec, value: String)] = entrySpecs.map { ($0.0, $0.1) }
    // group entries are folded over current bytes; pattern was cardioid(1), so all three move
    let first = try applyPreset(entries: typed, group: 0x1012, current: Data([0x00, 0x00, 0x00, 0, 0, 0, 0x01, 0, 0, 0, 0, 0]))
    assert(first.0 == Data([0x01, 0x01, 0x00, 0, 0, 0, 0x00, 0, 0, 0, 0, 0]))
    assert(first.1.map { $0.changed } == [true, true, true])
    assert(first.1.map { $0.field } == ["stereo", "float32", "pattern"])
    // applying the same preset again is a no-op: nothing changed, nothing written
    let second = try applyPreset(entries: typed, group: 0x1012, current: first.0)
    assert(second.0 == first.0 && second.1.allSatisfy { !$0.changed })
    // common group: gain 5 -> 0 is a real change; unrelated bytes survive the fold
    let commonResult = try applyPreset(entries: [(gain, "0")], group: 0x1000, current: Data([1, 0, 5, 2, 0, 1]))
    assert(commonResult.0 == Data([1, 0, 0, 2, 0, 1]) && commonResult.1[0].changed)
    // invalid value is rejected, leaving the fold to fail before any write
    do { _ = try applyPreset(entries: [(gain, "99")], group: 0x1000, current: Data(repeating: 0, count: 6)); assert(false) }
    catch {}
    // the built-in default profile resolves and validates against known fields
    let profile = builtinPresets["default"]!
    assert(profile.count == 8)
    for (name, value) in profile {
        guard let spec = knownFields.first(where: { $0.name == name }) else { assert(false); continue }
        assert(spec.group == 0x1000 || spec.group == 0x1012)
        _ = try proposeChange(spec, argument: value, current: Data(repeating: 0, count: spec.group == 0x1000 ? 6 : 12))
    }
}
print("PASS: preset fold (group-merged bytes, per-field diff, idempotence, validation, built-in default resolves)")
