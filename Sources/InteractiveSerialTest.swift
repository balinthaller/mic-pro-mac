import AppKit
import IOBluetooth

/// User-driven transport experiment; optional guarded pulse, no routing or recording changes.
final class InteractiveSerialTest: NSObject, NSWindowDelegate, IOBluetoothRFCOMMChannelDelegate {
    weak var probe: Probe?
    let window: NSWindow
    let phase = NSTextField(labelWithString: "准备测试")
    let countdown = NSTextField(labelWithString: "3 → 打开 → 5 秒 → 关闭")
    let detail = NSTextField(wrappingLabelWithString: "请先重新开启闪电说语音输入，并持续说话。点击开始后观察声音在哪个阶段消失。")
    let timeline = NSTextField(wrappingLabelWithString: "点击“现在听不到了”或“现在恢复了”，记录你感知到的时刻。")
    var startButton: NSButton!
    var holdMode: NSButton!
    var portSelector: NSPopUpButton!
    var selectedPort: BluetoothRFCOMMChannelID = 12
    var closeButton: NSButton!
    var keepOpen = false
    var acknowledgementProbe = false
    var tencentStream = TencentStream()
    var appStream = FrameStream()
    var recordingCancelled = false
    var recordingDownloadFragment: UInt16?
    var recordingDownloadStarted: Date?
    var recordingDownloadMaxBytes = 512*1024*1024
    var recordingDownloadID: UInt32?
    var recordingDownloadPlan: RecordingDownloadPlan?
    var recordingDownloadURL: URL?
    var recordingActivity = Date()
    var recordingsRequested = false
    var recordingListPlan: RecordingListPlan?
    var readPlan: AppControlReadPlan?
    var pulseRequested = false
    var requestedKind: AppControlPulsePlan.Kind = .noise
    var requestedLEDHold: TimeInterval = 2
    var agentRequestID: String?
    var wallpaperRequested = false
    var uploadAction: String?
    var uploadImagePath: String?
    var uploadBackupPath: String?
    var uploadAssets: PreparedWallpaperUpload?
    var wallpaperUploadPlan: WallpaperUploadPlan?
    var uploadWaitUntil: Date?
    var wallpaperReadPlan: WallpaperReadPlan?
    var wallpaperLastActivity = Date()
    var wallpaperBackupURL: URL?
    var wallpaperError: String?
    var telemetryCompletion: ((AppControlReadPlan?) -> Void)?
    var inputWasRunning = false
    var appPulsePlan: AppControlPulsePlan?
    var requestStarted: Date?
    var confirmationButton: NSButton!
    var observations: [NSButton] = []
    var channel: IOBluetoothRFCOMMChannel?
    var timer: Timer?
    var stream = SerialPacketStream()
    var testID: UUID?
    var started: Date?
    var opened: Date?
    var transitionStarted: Date?
    var stage = "准备"
    var events: [String] = []
    var busy = false

    init(probe: Probe) {
        self.probe = probe
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled,.closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Mic Pro · 交互式音频测试"
        window.isReleasedWhenClosed = false; window.delegate = self
        let root = window.contentView!
        phase.font = .systemFont(ofSize: 26, weight: .semibold)
        phase.frame = NSRect(x: 28, y: 338, width: 544, height: 36); root.addSubview(phase)
        countdown.font = .monospacedDigitSystemFont(ofSize: 32, weight: .medium)
        countdown.frame = NSRect(x: 28, y: 284, width: 544, height: 44); root.addSubview(countdown)
        detail.frame = NSRect(x: 28, y: 230, width: 544, height: 48); root.addSubview(detail)
        holdMode = NSButton(checkboxWithTitle: "保持串口打开，手动关闭", target: self, action: #selector(previewMode))
        holdMode.frame = NSRect(x: 28, y: 202, width: 260, height: 26); root.addSubview(holdMode)
        portSelector = NSPopUpButton(frame: NSRect(x: 300, y: 202, width: 118, height: 26), pullsDown: false)
        portSelector.addItems(withTitles: ["音频端口 12", "腾讯端口 11", "设置端口 10"])
        portSelector.item(at: 0)?.tag = 12; portSelector.item(at: 1)?.tag = 11; portSelector.item(at: 2)?.tag = 10
        root.addSubview(portSelector)
        closeButton = NSButton(title: "关闭串口", target: self, action: #selector(manualClose))
        closeButton.frame = NSRect(x: 424, y: 201, width: 146, height: 28)
        closeButton.isEnabled = false; root.addSubview(closeButton)
        startButton = NSButton(title: "开始只读测试", target: self, action: #selector(start))
        startButton.bezelStyle = .rounded; startButton.frame = NSRect(x: 24, y: 170, width: 174, height: 34); root.addSubview(startButton)
        for (index, title) in ["现在听不到了", "现在恢复了"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(observe(_:)))
            button.tag = index; button.isEnabled = false; button.bezelStyle = .rounded
            button.frame = NSRect(x: 210 + index * 184, y: 170, width: 174, height: 34)
            observations.append(button); root.addSubview(button)
        }
        timeline.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        timeline.frame = NSRect(x: 28, y: 22, width: 544, height: 105); root.addSubview(timeline)
        confirmationButton = NSButton(title: "已按电源确认，继续读取", target: self, action: #selector(confirmAuthorization))
        confirmationButton.frame = NSRect(x: 28, y: 134, width: 260, height: 28)
        confirmationButton.isEnabled = false; root.addSubview(confirmationButton)
        window.center()
    }
    @objc func previewMode() {
        guard !busy else { return }
        countdown.stringValue = holdMode.state == .on ? "3 → 打开 → 手动关闭" : "3 → 打开 → 5 秒 → 关闭"
    }
    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func note(_ message: String) {
        let elapsed = started.map { Date().timeIntervalSince($0) } ?? 0
        let line = String(format: "+%.2fs [%@] %@", elapsed, stage, message)
        events.append(line); timeline.stringValue = events.suffix(8).joined(separator: "\n")
        probe?.log("交互式测试 \(testID?.uuidString ?? "-") " + line)
    }
    func startTelemetry(completion: @escaping (AppControlReadPlan?) -> Void) {
        guard !busy else { completion(nil); return }
        telemetryCompletion = completion; pulseRequested = false
        portSelector.selectItem(at: 2); holdMode.state = .off
        start()
        guard busy else { telemetryCompletion = nil; completion(nil); return }
        open()
    }
    func startRecordings(id: String, fileID: UInt32? = nil, fragment: UInt16? = nil, maxBytes: Int = 512*1024*1024) {
        recordingDownloadMaxBytes=maxBytes
        guard !busy else { probe?.agentReply(id,["ok":false,"error":"busy"]); return }
        recordingCancelled=false;recordingDownloadFragment = fragment; recordingDownloadStarted = nil
        recordingDownloadID = fileID; recordingDownloadURL = nil; recordingDownloadPlan = nil
        agentRequestID = id; recordingsRequested = true; pulseRequested = false
        portSelector.selectItem(at:2); holdMode.state = .on; start()
        guard busy else { recordingsRequested = false; agentRequestID = nil; probe?.agentReply(id,["ok":false,"error":"control unavailable"]); return }
        open()
    }
    func advanceRecordings() {
        guard let plan = recordingListPlan, busy, stage == "串口已打开" else { return }
        if let id = agentRequestID { probe?.recordingFilesWindow?.updateProgress(id:id,found:plan.state == .list ? plan.total : (plan.selectedDetailsOnly ? 1 : plan.total),details:plan.metadata.count,scanning:plan.state == .list) }
        if plan.state == .failed { requestStarted = nil; close(); return }
        if plan.state == .ready {
            requestStarted = nil
            if let id = recordingDownloadID {
                guard let metadata = plan.selectedMetadata, little32(metadata,64) == id,
                      let identity = readPlan?.identity,
                      let download = try? RecordingDownloadPlan(metadata:metadata,identity:identity,maxBytes:recordingDownloadMaxBytes), readPlan?.common?[0] == 0 else { note("仅下载已列出的完整录音，内录进行中暂不下载"); close(); return }
                download.onUpdate = { [weak self] in self?.advanceRecordingDownload() }
                recordingDownloadPlan = download; recordingDownloadStarted = Date(); recordingActivity = Date(); advanceRecordingDownload()
            } else { close() }
            return
        }
        if let data = plan.nextRequest(), let channel = channel {
            var bytes = Array(data); requestStarted = Date()
            let code = bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress,length:UInt16($0.count)) }
            note("录音只读请求发送返回码=\(code)")
            if code != 0 { plan.timeout(); close() }
        }
    }
    func advanceRecordingDownload() {
        guard busy, stage == "串口已打开", let plan = recordingDownloadPlan else { return }
        if plan.state == .failed { note(plan.error ?? "下载失败"); close(); return }
        if plan.state == .ready {
            do {
                guard plan.fileURL != nil, let id = agentRequestID else { throw ProtocolError.invalidSettings }
                let folder = URL(fileURLWithPath:projectRoot + "/recordings/" + id)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let name = String(decoding:plan.identifier.prefix(64).prefix(while:{$0 != 0}),as:UTF8.self)
                guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains(".."), name.hasSuffix(".ogg") else { throw ProtocolError.invalidSettings }
                let url = folder.appendingPathComponent(name)
                try plan.publish(to:url); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
                recordingDownloadURL = url; note("录音下载完整，保存 \(plan.size) 字节")
            } catch { note("录音保存失败") }
            close(); return
        }
        if let data = plan.nextRequest(), let channel = channel {
            var bytes = Array(data); recordingActivity = Date()
            let code = bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress,length:UInt16($0.count)) }
            note("录音传输请求发送返回码=\(code)")
            if code != 0 { plan.timeout(); close() }
        }
    }
    func startWallpaperUpload(id: String, action: String, image: String?, backup: String) {
        guard !busy else { probe?.agentReply(id,["ok":false,"error":"busy"]); return }
        agentRequestID = id; uploadAction = action; uploadImagePath = image; uploadBackupPath = backup
        wallpaperRequested = false; pulseRequested = false
        portSelector.selectItem(at:2); holdMode.state = .on; start()
        guard busy else { agentRequestID = nil; uploadAction = nil; probe?.agentReply(id,["ok":false,"error":"control unavailable"]); return }
        open()
    }
    func startWallpaperBackup(id: String) {
        guard !busy else { probe?.agentReply(id,["ok":false,"error":"busy"]); return }
        agentRequestID = id; wallpaperRequested = true; pulseRequested = false
        portSelector.selectItem(at:2); holdMode.state = .on
        start()
        guard busy else { agentRequestID = nil; wallpaperRequested = false; probe?.agentReply(id,["ok":false,"error":"control unavailable"]); return }
        open()
    }
    func startAgent(id: String, kind: AppControlPulsePlan.Kind = .noise, ledHold: TimeInterval = 2) {
        guard !busy else { probe?.agentReply(id, ["ok": false, "error": "busy"]); return }
        agentRequestID = id; pulseRequested = true; requestedKind = kind; requestedLEDHold = ledHold; portSelector.selectItem(at: 2); holdMode.state = .off
        start()
        guard busy else { agentRequestID = nil; pulseRequested = false; probe?.agentReply(id, ["ok": false, "error": "primary_control_unavailable"]); return }
        open() // User-requested production pulse has no experimental countdown or popup.
    }
    @objc func start() {
        guard let probe = probe, !probe.handoffSuppressed, !busy, !probe.bluetoothOperation, probe.pulseWorkflow == nil, probe.serialPulse == nil,
              probe.peripheral == nil, (portSelector.selectedItem?.tag == 10 ? probe.primaryControlAvailable : probe.serialHapticAvailable) else { detail.stringValue = "请先保持 Mic Pro 音频连接，并等待其他操作结束。"; return }
        guard PowerMonitor.usage()["mic_input_running"] as? Bool == true || ((acknowledgementProbe && portSelector.selectedItem?.tag == 11) || portSelector.selectedItem?.tag == 10) else {
            detail.stringValue = "Mic Pro 输入流尚未运行。请先重新开启闪电说语音输入，再点击开始。"; return
        }
        inputWasRunning = PowerMonitor.usage()["mic_input_running"] as? Bool == true
        busy = true; probe.bluetoothOperation = true; startButton.isEnabled = false
        keepOpen = holdMode.state == .on; holdMode.isEnabled = false
        selectedPort = BluetoothRFCOMMChannelID(portSelector.selectedItem?.tag ?? 12); portSelector.isEnabled = false
        pulseRequested = pulseRequested && selectedPort == 10
        observations.forEach { $0.isEnabled = true }
        testID = UUID(); started = Date(); opened = nil; transitionStarted = nil; stream = SerialPacketStream(); tencentStream = TencentStream(); appStream = FrameStream(); events = []
        recordingListPlan = nil; recordingDownloadPlan = nil; recordingDownloadURL = nil; wallpaperReadPlan = nil; wallpaperBackupURL = nil; wallpaperError = nil; wallpaperUploadPlan = nil; uploadAssets = nil; uploadWaitUntil = nil
        readPlan = selectedPort == 10 ? AppControlReadPlan(includeBattery:telemetryCompletion != nil) : nil; requestStarted = nil; appPulsePlan = nil
        confirmationButton.isEnabled = false
        stage = "倒计时"; phase.stringValue = "准备打开串口"; phase.textColor = .systemOrange
        detail.stringValue = selectedPort == 11 ? "独立端口协议应答测试；不修改设置、不震动。请持续说话。" : "只读取降噪设置，不修改设置、不震动。请持续说话。"; note("测试端口=\(selectedPort)；先倒数 3 秒")
        timer?.invalidate()
        let testTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        timer = testTimer; RunLoop.main.add(testTimer, forMode: .common); tick()
    }
    func tick() {
        guard let started = started, busy else { return }
        let elapsed = Date().timeIntervalSince(started)
        if stage == "倒计时" {
            let remaining = max(0, 3 - elapsed)
            countdown.stringValue = "\(Int(ceil(remaining)))"
            if remaining == 0 { open() }
        } else if stage == "串口已打开", let opened = opened {
            let remaining = max(0, 5 - Date().timeIntervalSince(opened))
            countdown.stringValue = String(format: "保持打开 %.1f 秒", remaining)
            if keepOpen {
                countdown.stringValue = String(format: "串口保持打开 %.1f 秒", Date().timeIntervalSince(opened))
            } else if remaining == 0, (readPlan == nil || readPlan?.state == .ready), (!pulseRequested || appPulsePlan?.state == .ready) { close() }
            if let requestStarted = requestStarted, Date().timeIntervalSince(requestStarted) > 3 {
                if recordingListPlan != nil { recordingListPlan?.timeout(); advanceRecordings() }
                else if appPulsePlan != nil { appPulsePlan?.timeout(); self.requestStarted = nil; advanceAppPulse() }
                else { readPlan?.timeout(); advanceReadPlan() }
            }
            if let pulse = appPulsePlan, requestStarted == nil, let resumeAt = pulse.resumeAt, Date() >= resumeAt { advanceAppPulse() }
            if readPlan?.state == .awaitingConfirmation { countdown.stringValue = "等待按电源确认" }
            if let until = uploadWaitUntil, Date() >= until {
                uploadWaitUntil = nil; wallpaperUploadPlan = nil; wallpaperRequested = true; readPlan = AppControlReadPlan(); requestStarted = nil; advanceReadPlan()
            }
            if let start = recordingDownloadStarted, Date().timeIntervalSince(start) > (recordingDownloadPlan?.deadlineSeconds ?? 180) { recordingDownloadPlan?.timeout(); advanceRecordingDownload() }
            if let download = recordingDownloadPlan, download.state != .verifying, Date().timeIntervalSince(recordingActivity) > 20 { recordingDownloadPlan?.timeout(); advanceRecordingDownload() }
            if wallpaperUploadPlan != nil, uploadWaitUntil == nil, Date().timeIntervalSince(wallpaperLastActivity) > 10 { wallpaperUploadPlan?.timeout(); advanceUpload() }
            if wallpaperReadPlan != nil, Date().timeIntervalSince(wallpaperLastActivity) > 10 { wallpaperReadPlan?.timeout(); advanceWallpaper() }
            if selectedPort == 10, Date().timeIntervalSince(opened) > (recordingsRequested ? 22680 : uploadAction != nil ? 180 : 60) { note("授权等待超时，释放通道"); close() }
        }
        if let transitionStarted = transitionStarted, Date().timeIntervalSince(transitionStarted) > 5,
           stage == "正在打开" || stage == "正在关闭" { end("打开或关闭串口超时，关闭状态未确认") }
    }
    func open() {
        guard let device = SystemBattery.device(), let services = device.services as? [IOBluetoothSDPServiceRecord] else { end("串口服务不可用"); return }
        let published = services.contains { record in
            var id: BluetoothRFCOMMChannelID = 0
            return record.getRFCOMMChannelID(&id) == 0 && id == selectedPort
        }
        guard published else { end("所选端口未公布，未连接"); return }
        let port = selectedPort
        transitionStarted = Date(); stage = "正在打开"; phase.stringValue = "正在打开串口"; countdown.stringValue = "现在留意声音"; note("已发出打开请求")
        let id = testID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var openedChannel: IOBluetoothRFCOMMChannel?
            let result = device.openRFCOMMChannelAsync(&openedChannel, withChannelID: port, delegate: self)
            DispatchQueue.main.async {
                guard self.busy, self.testID == id else { _ = openedChannel?.close(); return }
                self.channel = openedChannel
                if result != 0 { self.end("打开失败：\(result)") }
            }
        }
    }
    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.busy, self.stage == "正在打开" else { _ = channel?.close(); return }
            guard status == 0 else { self.end("串口打开失败：\(status)"); return }
            self.channel = channel; self.opened = Date(); self.transitionStarted = nil; self.stage = "串口已打开"
            self.phase.stringValue = "串口已打开"; self.phase.textColor = .systemBlue
            self.closeButton.isEnabled = true
            self.note(self.keepOpen ? "设备确认打开；保持到手动关闭" : "设备确认打开；保持 5 秒")
            if self.keepOpen { self.detail.stringValue = "保持串口打开时，请重新开启闪电说语音输入；若能收音，点“现在恢复了”。暂时不要关闭串口。" }
            if self.selectedPort == 10 {
                self.advanceReadPlan()
            } else if self.selectedPort == 12 {
                var bytes = Array(serialNoiseRequest())
                let result = bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
                self.note("只读查询返回码=\(result)")
            } else {
                if self.acknowledgementProbe {
                    var bytes = Array(tencentAcknowledgementProbe())
                    let result = bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
                    self.note("腾讯 type2 应答测试写入=\(result)；不执行 type1 设备信息/绑定请求")
                } else { self.note("候选端口仅监听；未发送任何协议数据") }
            }
        }
    }
    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length count: Int) {
        let bytes = Data(bytes: pointer, count: count)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.busy else { return }
            if self.selectedPort == 11 {
                self.note("候选接收 \(bytes.count) 字节；协议头=" + bytes.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " "))
            }
            if self.selectedPort == 11 {
                for frame in self.tencentStream.append(bytes) {
                    self.note(String(format: "腾讯控制回复：type=%02X cmd=%02X seq=%02X len=%d", frame.type, frame.command, frame.sequence, frame.payload.count))
                    if frame.type == 4, frame.command == 0x40, frame.sequence == 0x31, frame.payload.isEmpty {
                        self.note("PASS：独立控制通道应答确认；未修改设备设置")
                    }
                }
            }
            if self.selectedPort == 10 {
                for frame in self.appStream.append(bytes) {
                    if frame.command != 0x43 { self.note(String(format: "标准设置回复：cmd=%04X seq=%04X len=%d",frame.command,frame.sequence,frame.payload.count)) }
                    if let download = self.recordingDownloadPlan {
                        if frame.command == 0x43 || frame.command == 0x35 || frame.command == 0x38 || frame.command == 0x39 || frame.command == 0x1014 { self.recordingActivity = Date() }
                        let previous = download.state
                        download.consume(frame)
                        if previous == .start, download.state == .receiving {
                            self.note("录音传输期限秒=\(Int(download.deadlineSeconds))")
                        }
                        self.advanceRecordingDownload()
                    } else if let recordings = self.recordingListPlan {
                        let previous = recordings.responses; recordings.consume(frame)
                        if recordings.responses != previous { self.requestStarted = nil; self.advanceRecordings() }
                    } else if let uploader = self.wallpaperUploadPlan {
                        self.wallpaperLastActivity = Date(); uploader.consume(frame); self.advanceUpload()
                    } else if let wallpaper = self.wallpaperReadPlan {
                        self.wallpaperLastActivity = Date()
                        if let ack = wallpaper.consume(frame) { self.writeWallpaper(ack) }
                        self.advanceWallpaper()
                    } else if let pulse = self.appPulsePlan {
                        let previous = pulse.state; pulse.consume(frame)
                        if pulse.state != previous { self.requestStarted = nil; self.advanceAppPulse() }
                    } else {
                        let previous = self.readPlan?.state; self.readPlan?.consume(frame)
                        if self.readPlan?.state != previous { self.requestStarted = nil; self.advanceReadPlan() }
                    }
                }
            }
            for packet in self.stream.append(bytes) {
                if let value = serialNoiseValue(packet) { self.note("读回降噪=\(value)；未修改") }
            }
        }
    }
    func advanceReadPlan() {
        guard busy, let plan = readPlan else { return }
        if plan.state == .failed { note(plan.error ?? "读取失败"); close(); return }
        if plan.state == .awaitingConfirmation {
            if agentRequestID != nil || telemetryCompletion != nil { note("需要物理授权，请先运行交互式只读测试完成确认"); close(); return }
            confirmationButton.isEnabled = true
            detail.stringValue = "设备要求授权：请单按 Mic Pro 电源键，再点击“已按电源确认，继续读取”。请同时观察语音是否连续。"
            note("等待设备物理确认；未修改设置")
            return
        }
        if plan.state == .ready {
            note("PASS：身份、授权、Common 与 More 均已校验；降噪=\(plan.common?[3] ?? 255)，震动反馈=\(plan.more?[9] ?? 255)；未修改设置")
            if recordingsRequested {
                recordingListPlan = RecordingListPlan(preferredFileID:recordingDownloadID,preferredFragment:recordingDownloadFragment,selectedDetailsOnly:recordingDownloadID != nil); advanceRecordings()
            } else if uploadAction != nil, uploadAssets == nil {
                do {
                    guard let path = uploadBackupPath else { throw ProtocolError.invalidSettings }
                    let assets = try uploadAction == "wallpaper-restore" ? prepareWallpaperRestore(backup:path,readPlan:plan) : prepareWallpaperUpload(image:uploadImagePath ?? "",backup:path,readPlan:plan)
                    guard let identity = plan.identity else { throw ProtocolError.invalidSettings }
                    uploadAssets = assets; wallpaperUploadPlan = try WallpaperUploadPlan(identity:identity,panel:assets.panel,png:assets.png)
                    wallpaperLastActivity = Date(); advanceUpload()
                } catch { wallpaperError = "上传前备份/身份/新鲜壁纸清单/图片校验失败，未发送BEGIN"; close() }
            } else if wallpaperRequested {
                guard let identity = plan.identity else { close(); return }
                wallpaperReadPlan = WallpaperReadPlan(identity:identity); wallpaperLastActivity = Date(); advanceWallpaper()
            } else if pulseRequested {
                guard (requestedKind == .led || plan.more?[9] == 1), let identity = plan.identity, let original = (requestedKind == .led ? plan.more : plan.common),
                      let pulse = try? AppControlPulsePlan(identity: identity, original: original, kind: requestedKind, ledHold: requestedLEDHold) else { note("震动反馈未开启或预检失败"); close(); return }
                note("原始提示参数快照=" + original.map { String(format: "%02X", $0) }.joined())
                appPulsePlan = pulse; advanceAppPulse()
            } else if telemetryCompletion != nil { close() }
            return
        }
        guard let data = plan.nextRequest(), let channel = channel else { return }
        var bytes = Array(data)
        requestStarted = Date()
        let result = bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
        note("标准设置请求 \(plan.state)，写入返回码=\(result)")
        if result != 0 { note("请求发送失败"); close() }
    }
    func advanceUpload() {
        guard busy, stage == "串口已打开", let plan = wallpaperUploadPlan else { return }
        if plan.state == .failed { wallpaperError = plan.error; note(plan.error ?? "传输失败，原壁纸备份保留"); close(); return }
        if plan.state == .ready {
            if uploadWaitUntil == nil { uploadWaitUntil = Date().addingTimeInterval(28); note("两阶段传输ACK完成；等待墨水屏刷新，随后重新读取完整壁纸验证") }
            return
        }
        let requests = plan.requests()
        if !requests.isEmpty { note("壁纸上传阶段：\(plan.state)，帧数=\(requests.count)，已进入擦写=\(plan.destructiveStarted)") }
        for data in requests { writeWallpaper(data); if stage != "串口已打开" { return } }
    }
    func writeWallpaper(_ data: Data) {
        guard let channel = channel else { return }
        if data.count >= 5, [UInt16(0x20),0x21,0x22,0x100A].contains(little16(data,3)) { probe?.lastControlMutationAt = Date() }
        var bytes = Array(data)
        let result = bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress,length:UInt16($0.count)) }
        if result != 0 { wallpaperError = "只读文件请求发送失败"; close() }
    }
    func advanceWallpaper() {
        guard busy, stage == "串口已打开", let plan = wallpaperReadPlan else { return }
        if plan.state == .failed { wallpaperError = plan.error; note(plan.error ?? "壁纸读取失败"); close(); return }
        if plan.state == .ready {
            do {
                if let assets = uploadAssets, plan.file != assets.png { throw ProtocolError.invalidSettings }
                if let read = readPlan, let id = agentRequestID {
                    wallpaperBackupURL = try saveWallpaperBackup(plan:plan,readPlan:read,id:id)
                    if let path = wallpaperBackupURL?.appendingPathComponent("original.png").path { UserDefaults.standard.set(path,forKey:"lastVerifiedWallpaperPNG") }
                }
                if uploadAction == "wallpaper-restore", let directory = uploadAssets?.backupDirectory {
                    let url = directory.appendingPathComponent("manifest.json")
                    if let data = try? Data(contentsOf:url), var info = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
                        info["upload_restore_verified"] = true; info["restore_readback_at"] = ISO8601DateFormatter().string(from:Date())
                        try JSONSerialization.data(withJSONObject:info,options:[.sortedKeys,.prettyPrinted]).write(to:url,options:.atomic)
                    }
                }
            } catch {
                wallpaperError = "文件已收齐，但PNG/调色板/壁纸MD5校验未通过，不能作为可恢复备份"
                if let data = plan.file, let id = agentRequestID { try? data.write(to:URL(fileURLWithPath:projectRoot + "/logs/wallpaper-unverified-" + id + ".bin"),options:.atomic) }
            }
            note(wallpaperBackupURL == nil ? (wallpaperError ?? "备份验证失败") : "PASS：完整PNG校验及当前壁纸MD5匹配，备份已保存")
            close(); return
        }
        if let request = plan.nextRequest() { note("只读壁纸阶段：\(plan.state)"); writeWallpaper(request) }
    }
    func advanceAppPulse() {
        guard busy, let plan = appPulsePlan else { return }
        if plan.state == .failed { note("提示测试停止：\(plan.error ?? "未知")；恢复确认=\(plan.restored)"); close(); return }
        if plan.state == .ready { note("PASS：10号提示切换及原值恢复均完整读回；实际触觉/灯光由用户确认"); close(); return }
        guard let data = plan.nextRequest(), let channel = channel else { return }
        if plan.state == .change || plan.state == .restore { probe?.lastControlMutationAt = Date() }
        var bytes = Array(data); requestStarted = Date()
        let result = bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
        let offset = plan.kind == .led ? 10 : 3
        note("10号提示阶段 \(plan.state)，类型=\(plan.kind)，发送返回码=\(result)；\(plan.original[offset])→\(plan.proposed[offset])→\(plan.original[offset])")
        if result != 0 { plan.timeout(); requestStarted = nil; advanceAppPulse() }
    }
    @objc func confirmAuthorization() {
        guard busy, readPlan?.state == .awaitingConfirmation else { return }
        confirmationButton.isEnabled = false
        readPlan?.confirmationProvided(); advanceReadPlan()
    }
    @objc func manualClose() { if busy, stage == "串口已打开" { close() } }
    func close() {
        closeButton.isEnabled = false
        transitionStarted = Date(); stage = "正在关闭"; phase.stringValue = "正在关闭串口"; phase.textColor = .systemOrange
        countdown.stringValue = "现在留意声音"; note("已发出关闭请求")
        let result = channel?.close() ?? -1
        if result != 0 { end("关闭返回码=\(result)") }
    }
    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        DispatchQueue.main.async { [weak self] in self?.end("串口已关闭；继续观察声音是否恢复", closedConfirmed: true) }
    }
    func end(_ message: String, closedConfirmed: Bool = false) {
        guard busy else { return }
        if recordingDownloadStarted != nil { probe?.lastRecordingTransferEndedAt = Date() }
        busy = false; timer?.invalidate(); timer = nil
        confirmationButton.isEnabled = false; requestStarted = nil
        transitionStarted = nil; stage = closedConfirmed ? "串口已关闭" : "测试结束，关闭未确认"
        phase.stringValue = message; phase.textColor = closedConfirmed ? .systemGreen : .systemOrange
        countdown.stringValue = "测试结束 · 可记录反馈"
        note(message); channel?.setDelegate(nil); _ = channel?.close(); channel = nil
        probe?.bluetoothOperation = false; startButton.isEnabled = true; holdMode.isEnabled = true; portSelector.isEnabled = true; closeButton.isEnabled = false
        detail.stringValue = "若声音消失，请点“现在听不到了”；恢复时点“现在恢复了”。需要重开闪电说时，也请告诉我。"
        if let id = agentRequestID, recordingsRequested {
            let planPageSize = recordingListPlan?.pageSize ?? 20
            let success = !recordingCancelled && recordingListPlan?.state == .ready && closedConfirmed && (recordingDownloadID == nil || recordingDownloadURL != nil)
            probe?.agentReply(id,["ok":success,"action":recordingDownloadID == nil ? "recordings-list" : "recordings-download", "file":recordingDownloadURL?.path as Any? ?? NSNull(), "bytes":recordingDownloadURL == nil ? NSNull() : (recordingDownloadPlan?.size ?? 0) as Any,"cancelled":recordingCancelled, "transport":"bluetooth", "integrity":recordingDownloadURL == nil ? NSNull() : "packet_crc16+ogg_page_crc32+eos+manifest_size", "device_crc_matches":recordingDownloadPlan?.deviceCRCMatches as Any? ?? NSNull(),"measurements":recordingDownloadPlan?.measurements as Any? ?? NSNull(),"total":recordingListPlan?.result.count ?? 0,"index_total":recordingListPlan?.total ?? 0,"items":recordingListPlan?.result ?? [],"page_size":planPageSize,"index_complete":recordingListPlan?.listingComplete ?? false,"reported_total":recordingListPlan?.reportedTotal ?? 0,"metadata_complete":recordingListPlan?.metadataComplete ?? false,"scope":recordingDownloadID == nil ? "meeting_ogg_index" : "selected_meeting_ogg_metadata","device_storage_complete":false,"read_only":true,"audio_connected":SystemBattery.device()?.isConnected() == true,"audio_connection_changed":false,"audio_data_continuity_verified":false,"elapsed_seconds":started.map{Date().timeIntervalSince($0)} ?? 0,"error":success ? NSNull() : (recordingCancelled ? "已取消，原录音保留。" : recordingDownloadPlan?.error ?? recordingListPlan?.error ?? readPlan?.error ?? message) as Any])
            agentRequestID = nil
        }
        recordingsRequested = false; recordingDownloadFragment = nil; recordingDownloadStarted = nil; recordingDownloadID = nil; recordingDownloadPlan = nil
        if let id = agentRequestID, wallpaperRequested || uploadAction != nil {
            probe?.agentReply(id,["ok": wallpaperBackupURL != nil && closedConfirmed, "action":uploadAction ?? "wallpaper-backup", "backup_directory": wallpaperBackupURL?.path as Any? ?? NSNull(), "error": (wallpaperError ?? readPlan?.error ?? wallpaperUploadPlan?.error) as Any? ?? (wallpaperBackupURL != nil && closedConfirmed ? NSNull() : message) as Any, "hardware_readback_verified":wallpaperBackupURL != nil, "requires_verified_backup":true, "restoration_backup":uploadAssets?.backupDirectory.path as Any? ?? NSNull()])
            probe?.summaryLabel.stringValue = wallpaperBackupURL != nil ? "屏幕操作已完整读回校验 · 文件已保存" : "屏幕操作未确认，请查看诊断日志"
            agentRequestID = nil
        }
        wallpaperRequested = false; uploadAction = nil; uploadAssets = nil; wallpaperUploadPlan = nil; uploadWaitUntil = nil
        if let id = agentRequestID {
            let audioConnected = SystemBattery.device()?.isConnected() == true
            let success = appPulsePlan?.state == .ready && closedConfirmed && audioConnected
            probe?.agentReply(id, ["ok": success, "action": requestedKind == .led ? "blink" : "vibrate", "transport": "rfcomm10", "settings_restored": appPulsePlan?.restored ?? false,
                                  "audio_connected": audioConnected, "audio_connection_changed": false,
                                  "input_was_running": inputWasRunning, "input_running_after": PowerMonitor.usage()["mic_input_running"] ?? false,
                                  "audio_data_continuity_verified": false,
                                  "transport_validation": "10号控制通道已实测；当前调用不检测物理灯光/震动或采集音频验证",
                                  "elapsed_seconds": started.map { Date().timeIntervalSince($0) } ?? 0,
                                  "error": success ? NSNull() : (appPulsePlan?.error ?? message) as Any])
            probe?.summaryLabel.stringValue = success ? "提示指令完成 · 设置已恢复 · 音频保持连接" : "提示未全部确认，请检查日志"
            agentRequestID = nil
        }
        if let completion = telemetryCompletion {
            telemetryCompletion = nil
            completion(readPlan?.state == .ready ? readPlan : nil)
        }
        pulseRequested = false; requestedKind = .noise
    }
    @objc func observe(_ sender: NSButton) { note(sender.tag == 0 ? "用户：现在听不到了" : "用户：现在恢复了") }
    func windowWillClose(_ notification: Notification) { if busy { end("用户关闭测试窗口，已请求释放串口") } }
}

extension Probe {
    @objc func showInteractiveTest() {
        if interactiveTest == nil { interactiveTest = InteractiveSerialTest(probe: self) }
        interactiveTest?.show()
    }
}
