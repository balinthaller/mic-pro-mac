import Foundation

struct CodexQuotaWindow: Codable {
    let used_percent: Double
    let window_minutes: Int
    let resets_at: Double
    var remaining: Double {max(0,min(100,100-used_percent))}
    var label: String {window_minutes == 10080 ? "周额度" : window_minutes == 1440 ? "日额度" : window_minutes % 60 == 0 ? "\(window_minutes/60)小时额度" : "\(window_minutes)分钟额度"}
    var percent: String {String(format:"%.0f%%",remaining)}
}
struct CodexQuotaSnapshot: Codable {
    let read_at: Double
    let windows: [CodexQuotaWindow]
    static func parse(_ data: Data) -> CodexQuotaSnapshot? {
        guard let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],object["ok"] as? Bool == true,
              let snapshot=try? JSONDecoder().decode(Self.self,from:data),snapshot.read_at.isFinite,snapshot.read_at>0,
              !snapshot.windows.isEmpty,snapshot.windows.count<=4,
              snapshot.windows.allSatisfy({$0.used_percent.isFinite && (0...100).contains($0.used_percent) && $0.window_minutes>0 && $0.resets_at.isFinite && $0.resets_at>0}) else{return nil}
        return snapshot
    }
    func stale(now: Date=Date()) -> Bool {now.timeIntervalSince1970-read_at > 900 || read_at>now.timeIntervalSince1970+60 || windows.contains(where:{$0.resets_at <= now.timeIntervalSince1970})}
    var summary: String {windows.first?.percent ?? "—"}
    func detail(now: Date=Date()) -> String {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"zh_CN");formatter.timeZone = .autoupdatingCurrent;formatter.dateFormat="MM-dd HH:mm"
        var rows=windows.map{"\($0.label)：剩余 \($0.percent) · 已用 \(String(format:"%.0f%%",$0.used_percent))\n重置：\(formatter.string(from:Date(timeIntervalSince1970:$0.resets_at)))"}
        if windows.count==1 {rows.append("第二额度窗口：未提供")}
        rows.append(stale(now:now) ? "上次读取已过期" : "\(max(0,Int(now.timeIntervalSince1970-read_at)))秒前更新 · Codex app-server")
        return rows.joined(separator:"\n\n")
    }
}
final class CodexQuotaReader {
    private(set) var snapshot: CodexQuotaSnapshot?
    private(set) var reading=false
    private(set) var error: String?
    private var lastAttempt=Date.distantPast
    var didUpdate: (() -> Void)?
    var summary: String {if !DeviceConfig.codexQuotaEnabled {return "未启用"};return (snapshot?.summary ?? "—")+(snapshot?.stale() == true ? "*" : "")}
    var detail: String {
        if !DeviceConfig.codexQuotaEnabled {return "可选 Codex 额度模块默认关闭。\n在 config.json 中将 codex_quota_enabled 设为 true 后重启。"}
        if let snapshot=snapshot {return snapshot.detail()+(error == nil ? "" : "\n\n最近刷新失败，保留上次读取")}
        return reading ? "正在读取真实账户额度…" : "额度暂不可读，请确认 Codex 已登录。\n"+(error ?? "尚未读取")
    }
    func refresh(force: Bool=false) {
        guard DeviceConfig.codexQuotaEnabled, !reading,Date().timeIntervalSince(lastAttempt) >= (force ? 10 : 300) else{return}
        lastAttempt=Date();reading=true;didUpdate?()
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
            let script=Bundle.main.resourceURL?.appendingPathComponent("codex-quota.py")
            process.arguments=[script?.path ?? ""]
            let pipe=Pipe();process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
            var result: CodexQuotaSnapshot?,failure: String?
            do {
                try process.run()
                DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+20){if process.isRunning {process.terminate()}}
                let bytes=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
                if bytes.count <= 16384,process.terminationStatus==0 {result=CodexQuotaSnapshot.parse(bytes)}
                if result==nil {failure="读取失败；可在额度页重试"}
            } catch {failure="官方 Codex 读取器不可用"}
            DispatchQueue.main.async { [weak self] in
                guard let self=self else{return};self.reading=false;self.error=failure;if let result=result {self.snapshot=result};self.didUpdate?()
            }
        }
    }
}
