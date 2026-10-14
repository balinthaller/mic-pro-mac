import Foundation
func request(_ plan: AppControlReadPlan) -> Frame {
    var stream = FrameStream(); return stream.append(plan.nextRequest()!)[0]
}
func reply(_ request: Frame, _ body: Data) -> Frame {
    Frame(command: request.command, sequence: 0, payload: request.payload.prefix(2) + Data([0]) + body)
}
let identity = Data("Insta360 TRC TX".utf8) + Data(repeating: 0, count: 1) + Data("TEST0001TEST01".utf8) + Data(repeating: 0, count: 2)
assert(identity.count == 32)
let plan = AppControlReadPlan(); let first = request(plan)
assert(plan.nextRequest() == nil)
plan.consume(Frame(command: first.command, sequence: 0, payload: Data([0,0,0,1]) + identity + Data([0])))
assert(plan.state == .identity) // unrelated message cannot advance to authorization
plan.consume(reply(first, Data([1]) + identity + Data([0])))
let auth = request(plan); plan.consume(reply(auth, identity + Data([1])))
assert(plan.state == .awaitingConfirmation && plan.nextRequest() == nil)
plan.confirmationProvided(); let confirmed = request(plan)
plan.consume(reply(confirmed, identity + Data([0])))
let common = request(plan)
assert(common.command == 0x1014 && common.payload.dropFirst(2).prefix(4) == Data([0,0x10,0,0]))
plan.consume(reply(common, identity + Data([0,0x10]) + Data([0,0,0,1,0,0]) + Data([0,0,0])))
let more = request(plan)
plan.consume(reply(more, identity + Data([0x12,0x10]) + Data([0,0,0,0,0,0,0,0,0,1,1,0]) + Data([0,0,0])))
assert(plan.state == .ready && plan.common?[3] == 1 && plan.more?[9] == 1 && plan.nextRequest() == nil)
let wrong = AppControlReadPlan(); let query = request(wrong)
var mismatch = identity; mismatch[29] = 65
wrong.consume(reply(query, Data([1]) + mismatch + Data([0])))
assert(wrong.state == .failed && wrong.nextRequest() == nil)
let timed = AppControlReadPlan(); _ = request(timed); timed.timeout()
assert(timed.state == .failed && timed.nextRequest() == nil)
print("PASS: message correlation, physical-confirmation gate, identity binding, two complete read groups, timeout without retries")
