import AppKit

final class PowerDashboard {
    let window: NSWindow
    let battery = NSTextField(labelWithString: "")
    let activity = NSTextField(wrappingLabelWithString: "")
    let recording = NSTextField(labelWithString: "")
    let analysis = NSTextField(wrappingLabelWithString: "")
    let advice = NSTextField(wrappingLabelWithString: "")
    init(probe: Probe) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560), styleMask: [.titled,.closable,.miniaturizable], backing: .buffered, defer: false)
        window.title = "Mic Pro · 电量与省电"; window.isReleasedWhenClosed = false
        let root = window.contentView!
        battery.font = .systemFont(ofSize: 32, weight: .semibold)
        activity.font = .systemFont(ofSize: 16, weight: .medium)
        recording.font = .systemFont(ofSize: 16)
        analysis.font = .systemFont(ofSize: 14)
        advice.font = .systemFont(ofSize: 13); advice.textColor = .secondaryLabelColor
        for (view, frame) in [(battery,NSRect(x: 28,y: 482,width: 624,height: 48)),
                              (activity,NSRect(x: 28,y: 416,width: 624,height: 62)),
                              (recording,NSRect(x: 28,y: 378,width: 624,height: 30)),
                              (analysis,NSRect(x: 28,y: 170,width: 624,height: 198)),
                              (advice,NSRect(x: 28,y: 56,width: 624,height: 106))] {
            view.frame = frame; root.addSubview(view)
        }
        let refresh = NSButton(title: "刷新设备状态", target: probe, action: #selector(Probe.refreshPowerStatus))
        refresh.frame = NSRect(x: 26,y: 18,width: 166,height: 30); root.addSubview(refresh)
        let history = NSButton(title: "查看耗电记录", target: probe, action: #selector(Probe.openPowerHistory))
        history.frame = NSRect(x: 202,y: 18,width: 166,height: 30); root.addSubview(history)
        window.center()
    }
    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
}

extension Probe {
    var currentRecording: Bool? {
        guard SystemBattery.device()?.isConnected() == true, let at = lastInternalRecordingAt, Date().timeIntervalSince(at) <= 90 else { return nil }
        return lastInternalRecording
    }
    func loadPowerHistory() {
        guard !powerHistoryLoaded else { return }; powerHistoryLoaded = true
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let contents = try? String(contentsOfFile: projectRoot + "/logs/power-v2.jsonl", encoding: .utf8) else { return }
        powerHistory = contents.split(separator: "\n").suffix(5000).compactMap { try? decoder.decode(PowerObservation.self, from: Data($0.utf8)) }
        if let log = try? String(contentsOfFile:projectRoot + "/logs/probe.log",encoding:.utf8) {
            powerHistory = PowerInsights.excludingTransfers(PowerInsights.excludingMutations(powerHistory,dates:PowerInsights.mutationDates(log:log)),intervals:PowerInsights.transferIntervals(log:log))
        }
    }
    func pollRecordingIfNeeded(force: Bool = false) {
        guard !handoffSuppressed, Date().timeIntervalSince(lastTelemetryAttempt) >= (force ? 5 : 30), primaryControlAvailable,
              !bluetoothOperation, pulseWorkflow == nil, serialPulse == nil, settingsPhase == nil, pending.isEmpty,
              peripheral == nil, central?.isScanning != true else { return }
        lastTelemetryAttempt = Date()
        if recordingReader == nil { recordingReader = InteractiveSerialTest(probe: self) }
        recordingReader?.startTelemetry { [weak self] plan in
            guard let self = self else { return }
            if let common = plan?.common, let more = plan?.more {
                self.latestCommon = common; self.latestMore = more
                self.lastInternalRecording = common[0] == 1; self.lastInternalRecordingAt = Date(); self.telemetryError = nil
                self.batteryPowerReading = plan?.batteryInfo.map { BatteryPowerReading(info:$0,at:plan?.batteryReadAt ?? Date()) }
                if let reading = self.batteryPowerReading {
                    self.log("电池只读：电量=\(reading.info.percent)，power_type=\(reading.info.powerType)")
                }
                self.refreshBatteryDisplay()
            } else { self.batteryPowerReading = nil; self.telemetryError = "设备状态查询未完成" }
            self.lastPowerUIAt = .distantPast; self.updatePowerUI()
        }
    }
    var currentBatteryPower: BatteryPowerReading? {
        guard !handoffSuppressed, let reading = batteryPowerReading,
              reading.fresh(connected:SystemBattery.device()?.isConnected() == true) else { return nil }
        return reading
    }
    var chargingLabel: String { currentBatteryPower?.label(connected:true) ?? "充电状态未知" }
    var currentCharging: Bool? {
        guard let reading = currentBatteryPower else { return nil }
        if reading.info.powerType == 0 { return false }
        return reading.info.percent < 100 ? true : nil
    }
    var batteryReadAt: Date? {
        currentBatteryPower?.at ?? (helperBatteryAt == .distantPast ? nil : helperBatteryAt)
    }
    var chargingTooltip: String {
        "充电/供电状态由设备报告，最多约30秒更新；满电接线显示已接电源，不推断充满或仍在充电。"
    }
    func powerStrings() -> (battery: String, read: String, activity: String, recording: String, advice: String) {
        let usage = PowerMonitor.usage(maxAge:0.8)
        let connected = SystemBattery.device()?.isConnected() == true
        let names = usage["active_input_client_names"] as? [String]
        let running = usage["mic_input_running"] as? Bool
        let activity: String
        if !connected { activity = "电脑收音：设备未连接" }
        else if let names = names, !names.isEmpty { activity = "正在使用麦克风：" + names.joined(separator: "、") }
        else if running == true { activity = "电脑正在采集 · 软件名称未识别" }
        else if running == false { activity = "电脑收音：未检测到软件正在采集" }
        else { activity = "电脑收音：状态暂不可读" }
        let battery = "Mic Pro 电量：" + (batteryLevel.map { "\($0)%" + (batteryIsCached ? "（上次读取）" : "") } ?? "未知") + " · " + chargingLabel
        let read = batteryReadAt.map { "电量读取：\(max(0, Int(Date().timeIntervalSince($0)))) 秒前 · \(batterySource ?? "未知来源")" } ?? "电量等待更新"
        let recording = "设备内录：" + PowerInsights.recordingLabel(lastInternalRecording, at: lastInternalRecordingAt, connected: connected)
        var advice = ""
        if running == true { advice += "不用语音输入时，可在占用软件里结束监听，避免持续采集。\n" }
        if currentRecording == true { advice += "设备正在内录；如果不需要本地备份，可手动停止内录。\n" }
        advice += "电量/充电与内录约30秒只读查询，完成即关闭控制通道；macOS后备电量约5秒刷新。满电接线显示已接电源。\n电量精度由设备/macOS决定，短时间不变化不代表不耗电；观测均值不用于推算精确续航。"
        return (battery,read,activity,recording,advice)
    }
    func addPowerMenu(to menu: NSMenu) {
        for key in ["read", "activity", "recording"] {
            let item = NSMenuItem(title: "更新中…", action: nil, keyEquivalent: ""); item.isEnabled = false
            powerMenuLabels[key] = item; menu.addItem(item)
        }
        let details = menu.addItem(withTitle: "电量与省电详情…", action: #selector(showPowerDashboard), keyEquivalent: ""); details.target = self
        lastPowerUIAt = .distantPast; updatePowerUI(force:true)
    }
    func updatePowerUI(force:Bool=false) {
        guard Date().timeIntervalSince(lastPowerUIAt) >= 1 else { return }; lastPowerUIAt = Date()
        updateStatusTitle()
        recordingFilesWindow?.tick()
        guard force || controlPanel?.window.isVisible == true || menuPopover?.popover.isShown == true || powerWindow?.window.isVisible == true else{return}
        let text = powerStrings()
        powerMenuLabels["battery"]?.title = text.battery
        powerMenuLabels["read"]?.title = text.read
        powerMenuLabels["activity"]?.title = text.activity
        powerMenuLabels["recording"]?.title = text.recording
        controlPanel?.update(probe:self)
        menuPopover?.update(probe:self)
        guard let dashboard = powerWindow, dashboard.window.isVisible else { return }
        loadPowerHistory()
        dashboard.battery.stringValue = text.battery
        dashboard.activity.stringValue = text.activity + "\n" + text.read
        dashboard.recording.stringValue = text.recording
        dashboard.analysis.stringValue = PowerInsights.summary(powerHistory)
        dashboard.advice.stringValue = text.advice + (telemetryError.map { "\n" + $0 + "，稍后重查。" } ?? "")
    }
    @objc func showPowerDashboard() {
        if powerWindow == nil { powerWindow = PowerDashboard(probe: self) }
        powerWindow?.show(); lastPowerUIAt = .distantPast; updatePowerUI(); refreshPowerStatus()
    }
    @objc func refreshPowerStatus() { requestFreshBattery(); pollRecordingIfNeeded(force: true) }
    @objc func openPowerHistory() { NSWorkspace.shared.selectFile(projectRoot + "/logs/power-v2.jsonl", inFileViewerRootedAtPath: projectRoot + "/logs") }
}
