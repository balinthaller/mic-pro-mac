import Foundation

struct PowerObservation: Codable {
    var schema = 2
    let at: Date
    let battery: Int?
    let batteryReadAt: Date?
    let cached: Bool
    let connected: Bool
    let capturing: Bool?
    let clients: [String]?
    let recording: Bool?
    let recordingReadAt: Date?
    // Unknown in old logs; current TX power state supplies this after a verified read.
    var charging: Bool? = nil
    var settingsFingerprint: String? = nil
    var excludeUntil: Date? = nil
    var transferActive: Bool? = nil
    var mode: String? {
        if transferActive == true { return nil }
        if let until = excludeUntil, at <= until { return nil }
        guard schema == 2, connected, let recording = recording, let read = recordingReadAt,
              at.timeIntervalSince(read) >= 0, at.timeIntervalSince(read) <= 90, let capture = capturing else { return nil }
        return capture ? (recording ? "电脑收音＋设备内录" : "电脑收音") : (recording ? "设备内录" : "蓝牙连接空闲")
    }
    var validBattery: Bool {
        guard charging != true, !cached, let battery = battery, (1...100).contains(battery), let read = batteryReadAt else { return false }
        return at.timeIntervalSince(read) >= 0 && at.timeIntervalSince(read) <= 15
    }
}
struct PowerSegment {
    let mode: String
    let start: Date
    var end: Date
    let firstBattery: Int
    var lastBattery: Int
    var count: Int
    var duration: TimeInterval { end.timeIntervalSince(start) }
    var drop: Int { firstBattery - lastBattery }
    var rate: Double? { duration >= 1800 && count >= 3 && drop > 0 ? Double(drop) * 3600 / duration : nil }
}
struct PowerTransferInterval {
    let start: Date
    let end: Date // Includes a 120-second cooling interval after transfer ends.
}
enum PowerInsights {
    static func transferIntervals(log: String) -> [PowerTransferInterval] {
        let formatter = ISO8601DateFormatter()
        var active = [String:Date](); var deadlines = [String:Date](); var intervals = [PowerTransferInterval]()
        func finish(_ id: String, _ date: Date) {
            guard let start = active.removeValue(forKey:id), date >= start else { return }
            deadlines.removeValue(forKey:id)
            intervals.append(PowerTransferInterval(start:start,end:date.addingTimeInterval(120)))
        }
        for line in log.split(separator:"\n") {
            let text = String(line)
            guard let date = formatter.date(from:String(text.prefix(20))) else { continue }
            if text.contains("应用启动") {
                for (id,start) in Array(active) { finish(id,min(date,deadlines[id] ?? start.addingTimeInterval(180))) }
            }
            guard let range = text.range(of:"交互式测试 "),
                  let token = text[range.upperBound...].split(separator:" ").first,
                  UUID(uuidString:String(token)) != nil else { continue }
            let id = String(token)
            if text.contains("录音传输请求发送"), active[id] == nil { active[id] = date }
            if let budgetRange = text.range(of:"录音传输期限秒="),
               let token = text[budgetRange.upperBound...].split(separator:" ").first,
               let seconds = Double(token), seconds.isFinite, (180...21600).contains(seconds), active[id] != nil {
                // A manifest extends the legacy deadline; resumes never reset the budget.
                if deadlines[id] == nil { deadlines[id] = date.addingTimeInterval(seconds) }
            }
            if text.contains("[串口已关闭]") || text.contains("[测试结束，关闭未确认]") { finish(id,date) }
        }
        for (id,start) in Array(active) { finish(id,deadlines[id] ?? start.addingTimeInterval(180)) }
        return intervals.sorted { $0.start < $1.start }
    }
    static func excludingTransfers(_ observations: [PowerObservation], intervals: [PowerTransferInterval]) -> [PowerObservation] {
        observations.map { observation in
            var result = observation
            for interval in intervals where interval.start <= observation.at && observation.at <= interval.end {
                if result.excludeUntil == nil || result.excludeUntil! < interval.end { result.excludeUntil = interval.end }
            }
            return result
        }
    }

    static func mutationDates(log: String) -> [Date] {
        let formatter = ISO8601DateFormatter()
        return log.split(separator:"\n").compactMap { line in
            let text = String(line)
            let mutation = text.contains("壁纸上传阶段：") || text.contains("设置写入（无自动重试）") ||
                ((text.contains("10号提示阶段") || text.contains("10号震动阶段")) && (text.contains("阶段 change") || text.contains("阶段 restore，")))
            guard mutation else { return nil }
            return formatter.date(from:String(text.prefix(20)))
        }.sorted()
    }
    static func excludingMutations(_ observations: [PowerObservation], dates: [Date]) -> [PowerObservation] {
        observations.map { observation in
            var result = observation
            if let latest = dates.last(where: { $0 <= observation.at && observation.at.timeIntervalSince($0) <= 120 }) {
                let until = latest.addingTimeInterval(120)
                if result.excludeUntil == nil || result.excludeUntil! < until { result.excludeUntil = until }
            }
            return result
        }
    }

    static func segments(_ observations: [PowerObservation]) -> [PowerSegment] {
        var results = [PowerSegment](); var current: PowerSegment?; var fingerprint: String?
        func flush() { if let value = current { results.append(value) }; current = nil }
        for observation in observations {
            guard observation.validBattery, let mode = observation.mode, let battery = observation.battery else { flush(); continue }
            if let value = current, (observation.settingsFingerprint != fingerprint || mode != value.mode || observation.at.timeIntervalSince(value.end) > 90 || observation.at <= value.end || battery > value.lastBattery) { flush() }
            if current == nil { current = PowerSegment(mode: mode, start: observation.at, end: observation.at, firstBattery: battery, lastBattery: battery, count: 1); fingerprint = observation.settingsFingerprint }
            else { current?.end = observation.at; current?.lastBattery = battery; current?.count += 1 }
        }
        flush(); return results
    }
    static func summary(_ observations: [PowerObservation]) -> String {
        let segments = segments(observations)
        let modes = ["蓝牙连接空闲", "电脑收音", "设备内录", "电脑收音＋设备内录"]
        return modes.map { mode in
            let values = segments.filter { $0.mode == mode }
            let minutes = Int(values.reduce(0) { $0 + $1.duration } / 60)
            guard let best = values.filter({ $0.rate != nil }).max(by: { $0.duration < $1.duration }), let rate = best.rate else {
                return "\(mode)：有效观测 \(minutes) 分钟，尚无连续30分钟且电量下降的区间"
            }
            return String(format: "%@：最长稳定区间 %d 分钟，下降 %d 个百分点，观测均值 %.1f 个百分点/小时", mode, Int(best.duration/60), best.drop, rate)
        }.joined(separator: "\n\n")
    }
    static func recordingLabel(_ recording: Bool?, at: Date?, connected: Bool, now: Date = Date()) -> String {
        guard let recording = recording, let at = at else { return "未知 · 尚未读到设备状态" }
        let age = max(0, Int(now.timeIntervalSince(at)))
        let value = recording ? "录制中" : "未录制"
        return connected && age <= 90 ? "\(value) · \(age) 秒前读取" : "未知 · 上次\(value)（\(age)秒前）"
    }
}
