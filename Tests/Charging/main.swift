import Foundation
func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
let identity = Data("Insta360 TRC TX".utf8) + Data([0]) + Data("TEST0001TEST01".utf8) + Data([0,0])
let plugged = Data(repeating:0,count:32) + Data([55,1,1,0])
let unplugged = Data(repeating:0,count:32) + Data([65,1,0,0])
check(BatteryInfo.decode(plugged, identity:identity)?.powerType == 1,"plugged fixture")
check(BatteryInfo.decode(unplugged, identity:identity)?.powerType == 0,"unplugged fixture")
check(BatteryInfo.decode(plugged, identity:Data()) == nil,"must bind query to verified identity")
check(BatteryInfo.decode(plugged.dropLast(), identity:identity) == nil,"truncated reply")
check(BatteryInfo.decode(plugged + Data([0]), identity:identity) == nil,"unexpected trailing byte")
var invalid = plugged; invalid[32]=101
check(BatteryInfo.decode(invalid, identity:identity) == nil,"invalid percent")
invalid=plugged;invalid[34]=3
check(BatteryInfo.decode(invalid, identity:identity) == nil,"unknown power value")
invalid=plugged;invalid[35]=1
check(BatteryInfo.decode(invalid, identity:identity) == nil,"unsupported child layout")
invalid=plugged;invalid[0]=1
check(BatteryInfo.decode(invalid, identity:identity) == nil,"foreign identity")
let now=Date(timeIntervalSince1970:1000)
let state=BatteryPowerReading(info:BatteryInfo.decode(plugged,identity:identity)!,at:now)
check(state.label(connected:true,now:now) == "充电中","fresh charging label")
check(state.label(connected:false,now:now) == "充电状态未知","disconnect invalidates")
check(state.label(connected:true,now:now.addingTimeInterval(91)) == "充电状态未知","stale invalidates")
check(state.label(connected:true,now:now.addingTimeInterval(-1)) == "充电状态未知","future date invalidates")
let full=BatteryPowerReading(info:BatteryInfo(percent:100,batteryType:1,powerType:1),at:now)
check(full.label(connected:true,now:now) == "已接电源","never infer fully charged")
let off=BatteryPowerReading(info:BatteryInfo.decode(unplugged,identity:identity)!,at:now)
check(off.label(connected:true,now:now) == "未充电","fresh unplugged label")
print("PASS: real battery fixture, identity, format, field bounds, disconnect, freshness, full-battery supply label")
func request(_ plan: AppControlReadPlan) -> Frame { var stream=FrameStream();return stream.append(plan.nextRequest()!)[0] }
func reply(_ frame: Frame, _ body: Data) -> Frame { Frame(command:frame.command,sequence:0,payload:frame.payload.prefix(2)+Data([0])+body) }
func setup(_ plan: AppControlReadPlan) {
    let first=request(plan);plan.consume(reply(first,Data([1])+identity+Data([0])))
    let auth=request(plan);plan.consume(reply(auth,identity+Data([0])))
    let common=request(plan);plan.consume(reply(common,identity+Data([0,0x10])+Data([0,0,0,1,0,0])+Data([0,0,0])))
    let more=request(plan);plan.consume(reply(more,identity+Data([0x12,0x10])+Data([0,0,0,0,0,0,0,0,0,1,1,0])+Data([0,0,0])))
}
let extended=AppControlReadPlan(includeBattery:true);setup(extended)
check(extended.state == .battery,"explicit optional battery phase")
let batteryRequest=request(extended)
check(batteryRequest.command == 0x1005 && batteryRequest.payload.count == 2,"only GET1005, empty body")
extended.consume(Frame(command:0x1005,sequence:0,payload:Data([0,0,0])+plugged))
check(extended.state == .battery,"ignore unrelated query message")
extended.consume(reply(batteryRequest,plugged))
check(extended.state == .ready && extended.batteryInfo?.percent == 55,"correlated battery reply")
let timed=AppControlReadPlan(includeBattery:true);setup(timed);_ = request(timed);timed.timeout()
check(timed.state == .ready && timed.common != nil && timed.more != nil && timed.batteryInfo == nil && timed.batteryError != nil,"battery timeout preserves existing telemetry")
let malformed=AppControlReadPlan(includeBattery:true);setup(malformed);let malformedRequest=request(malformed)
malformed.consume(reply(malformedRequest,plugged.dropLast()))
check(malformed.state == .ready && malformed.batteryInfo == nil && malformed.batteryError != nil,"invalid battery does not discard recordings")
let normal=AppControlReadPlan();setup(normal)
check(normal.state == .ready && normal.nextRequest() == nil,"existing workflows do not issue extra request")
print("PASS: optional battery query, correlation, timeout, malformed response, existing workflows")
