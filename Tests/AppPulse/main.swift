import Foundation
let identity = Data(repeating: 65, count: 32)
let original = Data([0,0,0,0,0,0])
func request(_ plan: AppControlPulsePlan) -> Frame {
    var stream = FrameStream(); return stream.append(plan.nextRequest()!)[0]
}
func reply(_ query: Frame, _ values: Data? = nil) -> Frame {
    Frame(command: query.command, sequence: 0, payload: query.payload.prefix(2) + Data([0]) + (values.map { identity + Data([0,0x10]) + $0 + Data([0,0,0]) } ?? Data()))
}
let plan = try! AppControlPulsePlan(identity: identity, original: original)
let guardRead = request(plan)
plan.consume(Frame(command: guardRead.command, sequence: 0, payload: Data([0,0,0])))
assert(plan.state == .guardRead && plan.nextRequest() == nil)
plan.consume(reply(guardRead, original))
let write = request(plan)
assert(write.command == 0x1015 && write.payload.dropFirst(2) == Data([1,0,0x10]) + identity + plan.proposed)
plan.consume(reply(write)); plan.consume(reply(request(plan), plan.proposed))
plan.consume(reply(request(plan), plan.proposed))
let restore = request(plan)
assert(restore.payload.dropFirst(2).suffix(6) == original)
plan.consume(reply(restore)); plan.consume(reply(request(plan), original))
assert(plan.state == .ready && plan.restored && plan.nextRequest() == nil)
let conflict = try! AppControlPulsePlan(identity: identity, original: original)
var external = original; external[1] = 1
conflict.consume(reply(request(conflict), external))
assert(conflict.state == .failed && !conflict.wroteChange)
let timeout = try! AppControlPulsePlan(identity: identity, original: original)
timeout.consume(reply(request(timeout), original)); _ = request(timeout); timeout.timeout()
assert(timeout.state == .verifyChange)
let recoveryRead = request(timeout); assert(recoveryRead.command == 0x1014)
timeout.consume(reply(recoveryRead, timeout.proposed)); timeout.consume(reply(request(timeout), external))
assert(timeout.state == .failed && !timeout.restored && timeout.nextRequest() == nil)
print("PASS: correlated pulse, full-group preservation/restoration, external-change guards, ambiguous SET timeout reads without retry")
let moment = Date(timeIntervalSince1970: 1000)
for hold: TimeInterval in [0.4,2] {
for initial: UInt8 in [0,1] {
    let more = Data([0,0,0,0,0,0,0,0,0,1,initial,0])
    let led = try! AppControlPulsePlan(identity: identity, original: more, kind: .led, ledHold: hold)
    assert(led.proposed[10] == 1-initial)
    for i in 0..<12 where i != 10 { assert(led.original[i] == led.proposed[i]) }
    func next(_ now: Date) -> Frame { var stream = FrameStream(); return stream.append(led.nextRequest(now: now)!)[0] }
    func ledReply(_ query: Frame, _ values: Data? = nil) -> Frame {
        Frame(command: query.command, sequence: 0, payload: query.payload.prefix(2) + Data([0]) + (values.map { identity + Data([0x12,0x10]) + $0 + Data([0,0,0]) } ?? Data()))
    }
    let guardQuery = next(moment)
    assert(guardQuery.payload.dropFirst(2).prefix(4) == Data([0x12,0x10,0,0]))
    led.consume(ledReply(guardQuery,more), now: moment)
    let set = next(moment); assert(set.payload.dropFirst(2).prefix(3) == Data([1,0x12,0x10]))
    led.consume(ledReply(set), now: moment)
    led.consume(ledReply(next(moment),led.proposed), now: moment)
    assert(led.nextRequest(now: moment.addingTimeInterval(hold-0.01)) == nil)
    let afterHold = moment.addingTimeInterval(hold+0.01)
    led.consume(ledReply(next(afterHold),led.proposed), now: afterHold)
    led.consume(ledReply(next(afterHold)), now: afterHold)
    led.consume(ledReply(next(afterHold),more), now: afterHold)
    assert(led.state == .ready && led.restored)
}
}
assert((try? AppControlPulsePlan(identity: identity, original: original, ledHold: 4)) == nil)
print("PASS: LED originally on/off, More-only write, 400ms/2s visibility gates and duration bounds, other eleven settings preserved, full restoration")
