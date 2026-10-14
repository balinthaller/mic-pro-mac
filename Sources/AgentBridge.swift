import Foundation
import IOBluetooth

final class PulseWorkflow {
    enum Stage { case connecting, pulse, returning }
    let id: String
    let started = Date()
    var stage: Stage = .connecting
    var stageStarted = Date()
    var restored = false
    var error: String?
    var inputUID: String?
    init(id: String) { self.id = id }
}

extension Probe {
    var primaryControlAvailable: Bool {
        guard !handoffSuppressed, let device = SystemBattery.device(), device.isConnected(), let services = device.services as? [IOBluetoothSDPServiceRecord] else { return false }
        return services.contains { record in
            var channel: BluetoothRFCOMMChannelID = 0
            return record.getRFCOMMChannelID(&channel) == 0 && channel == 10
        }
    }
    var agentDirectory: URL { URL(fileURLWithPath: projectRoot + "/logs/agent") }
    func agentReply(_ id: String, _ payload: [String: Any]) {
        guard UUID(uuidString: id) != nil, let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        handleUIResult(id:id,payload:payload)
        recordingFilesWindow?.receive(id:id,payload:payload)
        let url = agentDirectory.appendingPathComponent(id + ".response.json")
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func agentStatus() -> [String: Any] {
        refreshBatteryDisplay()
        var result: [String: Any] = ["version":AppVersion.version,"build":AppVersion.build,"revision":AppVersion.revision,"ok": true, "busy": deviceTransactionBusy, "audio_connected": SystemBattery.device()?.isConnected() == true,
                "control_ready": !handoffSuppressed && authorized && moreSettings != nil, "battery_percent": batteryLevel as Any? ?? NSNull(),
                "battery_is_cached": batteryIsCached, "settings_restored": pulseWorkflow?.restored as Any? ?? NSNull()]
        result["codex_quota"] = ["remaining":codexQuota.summary,"reading":codexQuota.reading,"stale":codexQuota.snapshot?.stale() as Any? ?? NSNull(),"windows":codexQuota.snapshot?.windows.map{["used_percent":$0.used_percent,"window_minutes":$0.window_minutes,"resets_at":$0.resets_at]} as Any? ?? NSNull()]
        result["edge_dock"] = ["enabled":edgeDock?.enabled == true,"revealed":edgeDock?.revealed == true,"always_visible":edgeDock?.always == true,"compact":edgeDock?.compact == true,"position_fraction":edgeDock?.position ?? 0.6]
        result["panel"] = ["visible":controlPanel?.window.isVisible == true,
            "pinned":UserDefaults.standard.bool(forKey:"sidebarPinned"),
            "shortcut":panelShortcut?.label ?? "未注册", "shortcut_error":panelShortcut?.error as Any? ?? NSNull(),
            "tab":controlPanel?.selectedTab as Any? ?? NSNull()]
        result["handoff_phase"] = handoffState.phase.rawValue
        result["app_connections_suppressed"] = handoffSuppressed
        result["handoff_status"] = handoffDescription
        result["meeting_mode"] = ["switching":meetingModeSession != nil,"requested":UserDefaults.standard.bool(forKey:"meetingModeRequested"),"actual_mode_verified":false,"return_requires_pairing_window":true]
        result["phone_connected"] = NSNull()
        result["haptic_transport"] = primaryControlAvailable ? "rfcomm10" : authorized && moreSettings != nil ? "ble" as Any : NSNull()
        result["audio_data_continuity_verified"] = false
        result["transport_validation"] = "10号通道已由用户在固件2.0.2.4实测震动且语音连续；当前调用不采集音频验证"
        result["wallpaper_transport_available"] = primaryControlAvailable
        result["wallpaper_requires_verified_backup"] = true
        result["usb_connected"] = !connectedUSBVolumes().isEmpty
        result["usb_volumes"] = connectedUSBVolumes().map { ["name":$0.root.lastPathComponent,"path":$0.root.path] }
        result["recording_transfer"] = recordingTransferSnapshot() as Any? ?? NSNull()
        result["led_ready"] = primaryControlAvailable
        result["haptic_ready"] = !handoffSuppressed && (primaryControlAvailable || (authorized && moreSettings?[9] == 1))
        result["battery_read_at"] = batteryReadAt.map { ISO8601DateFormatter().string(from:$0) } as Any? ?? NSNull()
        result["charging"] = currentCharging as Any? ?? NSNull()
        result["charging_status"] = chargingLabel
        result["power_connected"] = currentBatteryPower.map { $0.info.powerType == 1 } as Any? ?? NSNull()
        result["charging_read_at"] = currentBatteryPower.map { ISO8601DateFormatter().string(from:$0.at) } as Any? ?? NSNull()
        result["battery_source"] = batterySource as Any? ?? NSNull()
        result["internal_recording"] = currentRecording.map { $0 as Any } ?? NSNull()
        result["internal_recording_read_at"] = lastInternalRecordingAt.map { ISO8601DateFormatter().string(from: $0) as Any } ?? NSNull()
        result["internal_recording_is_stale"] = currentRecording == nil
        result.merge(PowerMonitor.usage()) { _, new in new }
        return result
    }
    @objc func vibrateAndReconnect() { startAgentPulse(id: UUID().uuidString) }
    func startWallpaperUpload(id: String, action: String, image: String?, backup: String) {
        guard !handoffSuppressed else { agentReply(id,["ok":false,"error":"handed_off; explicit return-to-mac required"]); return }
        guard !bluetoothOperation, pulseWorkflow == nil, serialPulse == nil, pending.isEmpty, settingsPhase == nil else { agentReply(id,["ok":false,"error":"busy"]); return }
        guard primaryControlAvailable, peripheral == nil else { agentReply(id,["ok":false,"error":"control unavailable"]); return }
        if interactiveTest == nil { interactiveTest = InteractiveSerialTest(probe:self) }
        interactiveTest?.startWallpaperUpload(id:id,action:action,image:image,backup:backup)
    }
    @objc func backupWallpaper() { startWallpaperBackup(id:UUID().uuidString) }
    func startWallpaperBackup(id: String) {
        guard !handoffSuppressed else { agentReply(id,["ok":false,"error":"handed_off; explicit return-to-mac required"]); return }
        guard !bluetoothOperation, pulseWorkflow == nil, serialPulse == nil, pending.isEmpty, settingsPhase == nil else { agentReply(id,["ok":false,"error":"busy"]); return }
        guard primaryControlAvailable, peripheral == nil else { agentReply(id,["ok":false,"error":"control unavailable"]); return }
        if interactiveTest == nil { interactiveTest = InteractiveSerialTest(probe:self) }
        interactiveTest?.startWallpaperBackup(id:id)
    }
    @objc func blinkLights() { startAgentBlink(id: UUID().uuidString) }
    func startAgentBlink(id: String, duration: TimeInterval = 2) {
        guard !handoffSuppressed else { agentReply(id,["ok":false,"error":"handed_off; explicit return-to-mac required"]); return }
        guard duration.isFinite, (0.2...3).contains(duration) else { agentReply(id, ["ok": false, "error": "duration must be 0.2–3 seconds"]); return }
        guard serialPulse == nil, pulseWorkflow == nil, pending.isEmpty, settingsPhase == nil, !bluetoothOperation else {
            agentReply(id, ["ok": false, "error": "busy"]); return
        }
        guard primaryControlAvailable, peripheral == nil else { agentReply(id, ["ok": false, "error": "请先连接音频蓝牙并释放BLE控制连接"]); return }
        if interactiveTest == nil { interactiveTest = InteractiveSerialTest(probe: self) }
        interactiveTest?.startAgent(id: id, kind: .led, ledHold: duration)
    }
    func startAgentPulse(id: String) {
        guard !handoffSuppressed else { agentReply(id,["ok":false,"error":"handed_off; explicit return-to-mac required"]); return }
        guard serialPulse == nil, pulseWorkflow == nil, pending.isEmpty, settingsPhase == nil, !bluetoothOperation else {
            agentReply(id, ["ok": false, "error": "busy"]); return
        }
        guard SystemBattery.device() != nil else { agentReply(id, ["ok": false, "error": "Mic Pro is not paired"]); return }
        if SystemBattery.device()?.isConnected() == true {
            guard primaryControlAvailable, peripheral == nil else { agentReply(id, ["ok": false, "error": "primary_control_unavailable_or_ble_busy"]); return }
            if interactiveTest == nil { interactiveTest = InteractiveSerialTest(probe: self) }
            interactiveTest?.startAgent(id: id); return
        }
        let workflow = PulseWorkflow(id: id)
        if let devices = try? AudioRouting.devices(), let input = try? AudioRouting.current(.input) {
            workflow.inputUID = devices.first(where: { $0.id == input })?.uid
        }
        pulseWorkflow = workflow
        log("自动震动流程开始：连接控制、触发、恢复设置、返回音频。")
        if !(authorized && moreSettings != nil) { rescan() }
    }
    func returnPulseToAudio(_ error: String? = nil) {
        guard let workflow = pulseWorkflow, workflow.stage != .returning else { return }
        workflow.error = error; workflow.stage = .returning; workflow.stageStarted = Date()
        controlWanted = false
        central.stopScan(); scanTimer?.invalidate()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        guard let device = SystemBattery.device() else { finishAgentPulse(audioReady: false); return }
        bluetoothOperation = true
        log("震动流程：恢复音频蓝牙连接。")
        performClassicConnection(device, disconnect: false, source: "pulse-restore")
    }
    func finishAgentPulse(audioReady: Bool) {
        guard let workflow = pulseWorkflow else { return }
        var inputRestored = audioReady
        if audioReady, let uid = workflow.inputUID {
            do { try AudioRouting.select(uid: uid, direction: .input) }
            catch { inputRestored = false; workflow.error = "音频连接已恢复，但输入选择恢复失败" }
        }
        let ok = workflow.restored && audioReady && inputRestored && workflow.error == nil
        agentReply(workflow.id, ["ok": ok, "settings_restored": workflow.restored, "audio_connected": audioReady,
                                "input_restored": inputRestored, "elapsed_seconds": Date().timeIntervalSince(workflow.started),
                                "error": workflow.error as Any? ?? (ok ? NSNull() : "恢复未全部确认")])
        log(ok ? "PASS：自动震动流程完成，降噪及音频输入已恢复。" : "自动震动流程未全部完成，请检查日志。")
        pulseWorkflow = nil; refreshBatteryDisplay()
        summaryLabel.stringValue = audioReady ? "音频已恢复 · 可再次点击震动一下" : "音频恢复未成功，请检查连接"
    }
    func samplePowerState() {
        guard Date().timeIntervalSince(lastPowerSampleAt) >= 60 else { return }
        // Wait for the next query rather than log an already-aged device reading.
        if let reading = currentBatteryPower, Date().timeIntervalSince(reading.at) > 15 { return }
        lastPowerSampleAt = Date(); loadPowerHistory()
        let usage = PowerMonitor.usage()
        var sample = PowerObservation(at: Date(), battery: batteryLevel, batteryReadAt: batteryReadAt,
                                      cached: batteryIsCached, connected: SystemBattery.device()?.isConnected() == true,
                                      capturing: usage["mic_input_running"] as? Bool, clients: usage["active_input_clients"] as? [String],
                                      recording: lastInternalRecording, recordingReadAt: lastInternalRecordingAt)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        sample.excludeUntil = lastControlMutationAt == .distantPast ? nil : lastControlMutationAt.addingTimeInterval(120)
        sample.transferActive = (interactiveTest?.busy == true && interactiveTest?.recordingDownloadStarted != nil) || usbRecordingTransfer?.isRunning == true
        let transferUntil = sample.transferActive == true ? sample.at.addingTimeInterval(120) : lastRecordingTransferEndedAt.addingTimeInterval(120)
        if lastRecordingTransferEndedAt != .distantPast || sample.transferActive == true {
            sample.excludeUntil = max(sample.excludeUntil ?? .distantPast,transferUntil)
        }
        sample.charging = currentCharging
        sample.settingsFingerprint = latestCommon.map { $0.map { String(format: "%02X", $0) }.joined() }
        guard var data = try? encoder.encode(sample) else { return }
        powerHistory.append(sample); data.append(10)
        let url = URL(fileURLWithPath: projectRoot + "/logs/power-v2.jsonl")
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
        } else { try? data.write(to: url, options: .atomic) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func tickAgentBridge() {
        updatePowerUI()
        codexQuota.refresh()
        samplePowerState()
        if !FileManager.default.fileExists(atPath:agentDirectory.path){try? FileManager.default.createDirectory(at:agentDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        let modified=(try? FileManager.default.attributesOfItem(atPath:agentDirectory.path)[.modificationDate]) as? Date
        let shouldScan=modified == nil || modified != agentDirectoryModification
        agentDirectoryModification=modified
        let requests=shouldScan ? ((try? FileManager.default.contentsOfDirectory(at:agentDirectory,includingPropertiesForKeys:nil)) ?? []) : []
        for url in requests.filter({ $0.lastPathComponent.hasSuffix(".request.json") }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = String(url.lastPathComponent.dropLast(".request.json".count))
            guard UUID(uuidString: id) != nil else { continue }
            guard let data = try? Data(contentsOf: url), data.count <= 4096,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let action = object["action"] as? String else {
                try? FileManager.default.removeItem(at: url); agentReply(id, ["ok": false, "error": "invalid_request"]); continue
            }
            try? FileManager.default.removeItem(at: url)
            if FileManager.default.fileExists(atPath: agentDirectory.appendingPathComponent(id + ".response.json").path) || pulseWorkflow?.id == id || serialPulse?.id == id || interactiveTest?.agentRequestID == id { continue }
            if action == "status" { agentReply(id, agentStatus()) }
            else if action == "handoff-to-phone" { startDeviceHandoff(id:id) }
            else if action == "return-to-mac" { returnDeviceToMac(id:id) }
            else if ["wallpaper-upload", "wallpaper-restore"].contains(action) {
                guard let backup = object["backup"] as? String, action == "wallpaper-restore" || object["image"] is String else { agentReply(id,["ok":false,"error":"image and backup are required"]); continue }
                startWallpaperUpload(id:id,action:action,image:object["image"] as? String,backup:backup)
            }
            else if action == "recordings-progress" {
                let target=object["target_id"] as? String
                if let target=target,UUID(uuidString:target) == nil { agentReply(id,["ok":false,"error":"invalid_target_id"]);continue }
                if let progress=recordingTransferSnapshot(), target == nil || progress["request_id"] as? String == target { agentReply(id,["ok":true,"transfer":progress]) }
                else if let target=target,let data=try? Data(contentsOf:agentDirectory.appendingPathComponent(target+".response.json")),let result=try? JSONSerialization.jsonObject(with:data) { agentReply(id,["ok":true,"completed":true,"result":result]) }
                else { agentReply(id,["ok":true,"transfer":NSNull()]) }
            }
            else if action == "recordings-cancel" {
                guard let target=object["target_id"] as? String,UUID(uuidString:target) != nil else { agentReply(id,["ok":false,"error":"target_id is required"]);continue }
                agentReply(id,["ok":true,"cancel_requested":cancelRecordingTransfer(target),"target_id":target])
            }
            else if action == "recordings-list" || action == "recordings-download" {
                let fileID=(object["file_id"] as? String).flatMap(UInt32.init)
                let relative=object["relative_path"] as? String
                if action == "recordings-download",fileID == nil && relative == nil { agentReply(id,["ok":false,"error":"file_id or relative_path is required"]);continue }
                if let raw=object["fragment"],(raw as? String).flatMap(UInt16.init) == nil { agentReply(id,["ok":false,"error":"invalid_fragment"]);continue }
                if let raw=object["max_bytes"], (object["transport"] as? String != "bluetooth" || (raw as? String).flatMap(Int.init).map({(1...512*1024*1024).contains($0)}) != true) { agentReply(id,["ok":false,"error":"invalid_max_bytes"]);continue }
                startRecordingRequest(id:id,fileID:action == "recordings-download" ? fileID : nil,fragment:action == "recordings-download" ? (object["fragment"] as? String).flatMap(UInt16.init) : nil,transport:object["transport"] as? String ?? "auto",usbRoot:object["usb_root"] as? String,relative:action == "recordings-download" ? relative : nil,maxBytes:(object["max_bytes"] as? String).flatMap(Int.init) ?? 512*1024*1024)
            }
            else if action == "wallpaper-backup" { startWallpaperBackup(id:id) }
            else if action == "vibrate" { startAgentPulse(id: id) }
            else if action == "blink" {
                if let raw = object["duration"], !(raw is NSNumber) { agentReply(id, ["ok": false, "error": "invalid_duration"]) }
                else { startAgentBlink(id: id, duration: (object["duration"] as? NSNumber)?.doubleValue ?? 2) }
            }
            else { agentReply(id, ["ok": false, "error": "unsupported_action"]) }
        }
        pollRecordingIfNeeded()
        guard let workflow = pulseWorkflow else { return }
        switch workflow.stage {
        case .connecting:
            if authorized, let settings = moreSettings, pending.isEmpty, settingsPhase == nil {
                if settings[9] != 1 { returnPulseToAudio("请先开启震动反馈"); return }
                workflow.stage = .pulse; workflow.stageStarted = Date(); beginNoiseFeedbackTest()
            } else if Date().timeIntervalSince(workflow.stageStarted) > 35 { returnPulseToAudio("控制连接未就绪，可能需要设备进入配对模式") }
        case .pulse:
            if workflow.restored { returnPulseToAudio() }
            else if settingsPhase == nil && pending.isEmpty { returnPulseToAudio("降噪变更或恢复未得到确认") }
            else if Date().timeIntervalSince(workflow.stageStarted) > 25 { returnPulseToAudio("设置操作超时，原设置恢复未确认") }
        case .returning:
            let devicePresent = (try? AudioRouting.devices())?.contains(where: { $0.name.contains(DeviceConfig.serialSuffix) && $0.inputChannels > 0 }) == true
            if !bluetoothOperation && SystemBattery.device()?.isConnected() == true && devicePresent { finishAgentPulse(audioReady: true) }
            else if Date().timeIntervalSince(workflow.stageStarted) > 30 { finishAgentPulse(audioReady: false) }
        }
    }
}
