import Foundation
let base = Date(timeIntervalSince1970: 10000)
func sample(_ second: Double, battery: Int = 90, capture: Bool? = false, record: Bool? = false, age: Double = 0, cached: Bool = false, connected: Bool = true) -> PowerObservation {
    let at = base.addingTimeInterval(second)
    return PowerObservation(at: at, battery: battery, batteryReadAt: at, cached: cached, connected: connected, capturing: capture, clients: [], recording: record, recordingReadAt: at.addingTimeInterval(-age))
}
let stable = (0...30).map { sample(Double($0*60), battery: $0 == 30 ? 80 : 90) }
let segments = PowerInsights.segments(stable)
assert(segments.count == 1 && segments[0].rate == 20)
assert(PowerInsights.segments([sample(0), sample(1800, battery: 80)]).allSatisfy { $0.rate == nil })
assert(sample(0, record: nil).mode == nil && sample(0, age: 91).mode == nil && sample(0, capture: nil).mode == nil)
assert(PowerInsights.segments([sample(0), sample(60, connected: false), sample(120)]).count == 2)
assert(PowerInsights.segments([sample(0), sample(60, capture: true)]).count == 2)
assert(PowerInsights.segments([sample(0), sample(60, battery: 100)]).count == 2)
assert(!sample(0, cached: true).validBattery)
assert(PowerInsights.recordingLabel(false, at: base, connected: false, now: base).hasPrefix("未知"))
print("PASS: stable drain, gaps, charging increases, mixed modes, stale/unknown recording, cached battery excluded")
var charged = sample(60); charged.charging = true
assert(!charged.validBattery)
var changed = sample(60); changed.settingsFingerprint = "noise=1"
assert(PowerInsights.segments([sample(0), changed]).count == 2)
let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
let restored = try! decoder.decode(PowerObservation.self, from: encoder.encode(sample(0)))
assert(restored.mode == "蓝牙连接空闲" && restored.charging == nil)
print("PASS: settings-change segmentation, explicit charging exclusion, observation log roundtrip")
let mutating = PowerInsights.excludingMutations([sample(0),sample(60),sample(180),sample(240)],dates:[base.addingTimeInterval(30)])
assert(mutating[0].mode != nil && mutating[1].mode == nil && mutating[2].mode != nil)
let logs = "2026-10-12T06:27:34Z 10号提示阶段 change，类型=led\n2026-10-12T06:27:35Z 10号提示阶段 restoreGuard，类型=led\n2026-10-12T06:27:36Z 10号提示阶段 restore，类型=led\n2026-10-12T06:53:52Z 壁纸上传阶段：data\n2026-10-12T06:53:59Z 标准设置请求 identity"
assert(PowerInsights.mutationDates(log:logs).count == 3)
print("PASS: control/write cooling window and historical experiment exclusion; read-only requests kept")
let transferLog = """
2026-10-12T08:30:00Z 交互式测试 11111111-1111-1111-1111-111111111111 +0.0s [串口已打开] 录音传输请求发送返回码=0
2026-10-12T08:30:03Z 交互式测试 22222222-2222-2222-2222-222222222222 +0.0s [串口已打开] 标准设置请求 identity
2026-10-12T08:30:05Z 交互式测试 22222222-2222-2222-2222-222222222222 +2.0s [串口已关闭] 串口已关闭
2026-10-12T08:34:00Z 交互式测试 11111111-1111-1111-1111-111111111111 +240.0s [串口已关闭] 串口已关闭
"""
let windows = PowerInsights.transferIntervals(log:transferLog)
assert(windows.count == 1 && windows[0].end.timeIntervalSince(windows[0].start) == 360)
var inTransfer = sample(0); inTransfer.transferActive = true; assert(inTransfer.mode == nil)
let start = windows[0].start
func sampleAt(_ offset: Double) -> PowerObservation {
 let t = start.addingTimeInterval(offset)
 return PowerObservation(at:t,battery:90,batteryReadAt:t,cached:false,connected:true,capturing:false,clients:[],recording:false,recordingReadAt:t)
}
let protected = PowerInsights.excludingTransfers([-1.0,0,180,360,361].map(sampleAt),intervals:windows)
assert(protected.map{$0.mode == nil} == [false,true,true,true,false])
let interrupted = PowerInsights.transferIntervals(log:String(transferLog.split(separator:"\n").prefix(1).joined(separator:"\n")))
assert(interrupted.count == 1 && interrupted[0].end.timeIntervalSince(interrupted[0].start) == 300)
print("PASS: ongoing transfers, UUID-correlated long windows, cooling boundary and missing end protection")

let longInterrupted = """
2026-10-12T08:30:00Z 交互式测试 11111111-1111-1111-1111-111111111111 +0.0s [串口已打开] 录音传输请求发送返回码=0
2026-10-12T08:30:02Z 交互式测试 11111111-1111-1111-1111-111111111111 +2.0s [串口已打开] 录音传输期限秒=10000
"""
let longWindow=PowerInsights.transferIntervals(log:longInterrupted)
assert(longWindow.count == 1 && longWindow[0].end.timeIntervalSince(longWindow[0].start) == 10122)
let restartLog=longInterrupted+"\n2026-10-12T08:40:00Z 应用启动"
let restartedWindow=PowerInsights.transferIntervals(log:restartLog)
assert(restartedWindow[0].end.timeIntervalSince(restartedWindow[0].start) == 720)
let malformedBudget=longInterrupted.replacingOccurrences(of:"10000",with:"nan")
assert(PowerInsights.transferIntervals(log:malformedBudget)[0].end.timeIntervalSince(longWindow[0].start) == 300)
let closedLog=longInterrupted+"\n2026-10-12T08:35:00Z 交互式测试 11111111-1111-1111-1111-111111111111 +300.0s [串口已关闭] 串口已关闭"
assert(PowerInsights.transferIntervals(log:closedLog)[0].end.timeIntervalSince(longWindow[0].start) == 420)
print("PASS: adaptive missing-end window, restart bound, invalid budget fallback and actual-close precedence")
