import Foundation
var stream = FrameStream()
assert(stream.append(Data([0x77,0xFE])).isEmpty)
assert(stream.append(Data([0xEF,1,0x14,0x10,0,0,3,0,1])).isEmpty)
let result = stream.append(Data([0,0]))
assert(result.count == 1 && result[0].command == 0x1014 && result[0].payload == Data([1,0,0]))
var snapshot = Data([1,0,1,0,1,2,3,0,0,1,1,0])
let changed = try! vibrationSnapshot(snapshot, enabled: false)
assert(changed[9] == 0)
for i in 0..<12 where i != 9 { assert(changed[i] == snapshot[i]) }
do { _ = try vibrationSnapshot(Data([1,2]), enabled: true); fatalError("short snapshot accepted") } catch {}
snapshot[11] = 4
do { _ = try vibrationSnapshot(snapshot, enabled: true); fatalError("unknown enum accepted") } catch {}
print("PASS: split stream, preservation, invalid settings rejected")
let identity = Data(repeating: 65, count: 32)
let attributes = Data([0,0,0,0,0,1,0,0,0,1,1,1])
let response = identity + Data([0x12,0x10]) + attributes + Data([0,0,0])
assert(try! settingsResponse(response, identity: identity, group: 0x1012) == attributes)
do { _ = try settingsResponse(response, identity: Data(repeating:66,count:32), group:0x1012); fatalError("identity mismatch accepted") } catch {}
var corrupt = response; corrupt[34+5] = 9
do { _ = try settingsResponse(corrupt, identity: identity, group:0x1012); fatalError("invalid enum accepted") } catch {}
print("PASS: captured settings shape, identity binding, invalid enum")
let setBody = try! moreSettingsWriteBody(identity: identity, values: attributes)
assert(setBody.count == 47)
assert(setBody.prefix(3) == Data([1,0x12,0x10]))
assert(setBody[3..<35] == identity)
assert(setBody.suffix(12) == attributes)
do { _ = try moreSettingsWriteBody(identity: Data([1]), values: attributes); fatalError("short identity accepted") } catch {}
print("PASS: independently encoded More group write layout and identity length")
let ledOff = try! moreToggleSnapshot(attributes, field: .led, enabled: false)
assert(ledOff[10] == 0)
for i in 0..<12 where i != 10 { assert(ledOff[i] == attributes[i]) }
assert(ledOff[9] == attributes[9])
do { _ = try moreToggleSnapshot(Data([0]), field: .led, enabled: false); fatalError("short LED settings accepted") } catch {}
print("PASS: LED toggle preserves vibration and every peer setting")

let locked = try! moreToggleSnapshot(attributes, field: .childLock, enabled: true)
assert(locked[8] == 1)
for i in 0..<12 where i != 8 { assert(locked[i] == attributes[i]) }
print("PASS: child lock changes only its byte and preserves haptic feedback")

let common = Data([1,1,0xFA,1,1,2])
let noise = try! noiseFeedbackSnapshot(common)
assert(noise[3] == 2)
for i in 0..<6 where i != 3 { assert(noise[i] == common[i]) }
assert(try! commonSettingsWriteBody(identity: identity, values: noise) == Data([1,0,0x10]) + identity + noise)
assert(try! noiseFeedbackSnapshot(Data([0,0,0,0,0,0]))[3] == 1)
do { _ = try noiseFeedbackSnapshot(Data([0,0,0,3,0,0])); fatalError("invalid noise accepted") } catch {}
print("PASS: noise experiment preserves recording, mute, gain and other audio settings")
