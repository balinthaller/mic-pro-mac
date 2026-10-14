import AppKit
import CoreBluetooth
import IOBluetooth

let projectRoot = DeviceConfig.dataDirectory.path
let serviceID = CBUUID(string: "e49a25f8-f69a-11e8-8eb2-f2801f1b9fd1")
let writeID = CBUUID(string: "e49a25e0-f69a-11e8-8eb2-f2801f1b9fd1")
let batteryServiceID = CBUUID(string: "180F")
let batteryLevelID = CBUUID(string: "2A19")
let notifyID = CBUUID(string: "e49a28e1-f69a-11e8-8eb2-f2801f1b9fd1")

class Probe: NSObject, NSApplicationDelegate, CBCentralManagerDelegate, CBPeripheralDelegate, NSMenuDelegate, IOBluetoothRFCOMMChannelDelegate {
    var central: CBCentralManager!
    var discoveryObserver: DiscoveryObserver?
    var menuPopover: MenuPopover?
    var statusItem: NSStatusItem!
    var peripheral: CBPeripheral?
    var writer: CBCharacteristic?
    var receiver: CBCharacteristic?
    var batteryCharacteristic: CBCharacteristic?
    var batteryLevel: Int?
    var batteryPowerReading: BatteryPowerReading?
    var batteryIsCached = false
    var helperBatteryLevel: Int?
    var helperBatteryAt = Date.distantPast
    var batteryReadStarted = Date.distantPast
    var batteryReadPending = false
    var lastBatteryLevel: Int? = UserDefaults.standard.object(forKey: "lastBatteryLevel") as? Int
    var pulseWorkflow: PulseWorkflow?
    var lastControlMutationAt = Date.distantPast
    var lastRecordingTransferEndedAt = Date.distantPast
    var lastPowerSampleAt = Date.distantPast
    var recordingReader: InteractiveSerialTest?
    var lastTelemetryAttempt = Date.distantPast
    var telemetryError: String?
    var latestCommon: Data?
    var latestMore: Data?
    var powerWindow: PowerDashboard?
    var powerMenuLabels = [String: NSMenuItem]()
    var powerHistory = [PowerObservation]()
    var powerHistoryLoaded = false
    var lastPowerUIAt = Date.distantPast
    var lastInternalRecording: Bool?
    var lastInternalRecordingAt: Date?
    var bleBatteryLevel: Int?
    var batterySource: String?
    var systemBatteryTimer: Timer?
    var parallelBridging: Bool?
    var parallelTimer: Timer?
    var serialProbeChannel: IOBluetoothRFCOMMChannel?
    var serialReadProbe = false
    var serialStream = SerialPacketStream()
    var serialPulse: SerialPulse?
    var interactiveTest: InteractiveSerialTest?
    var usbRecordingTransfer: USBRecordingTransfer?
    var usbInventoryBusy = false
    var usbVolumeCheckedAt = Date.distantPast
    var cachedUSBVolumes = [USBRecordingStore]()
    var recordingFilesWindow: RecordingFilesWindow?
    var controlPanel: ControlPanel?
    var panelShortcut: PanelShortcut?
    var edgeDock: EdgeDock?
    var meetingModeSession: PortableMeetingModeSession?
    let codexQuota=CodexQuotaReader()
    var lastActionSummary: String?
    var screenUI: ScreenUIWorkflow?
    var handoffState = DeviceHandoffState(suppressed:UserDefaults.standard.bool(forKey:"handoffSuppressConnections"))
    var returnMacRequestID: String?
    var controlWanted = false
    var reconnectAttempts = 0
    var connectionToken = UUID()
    var switchingToControl = false
    var bluetoothOperation = false
    var bluetoothResult: String?
    var dockConnectRequested=false
    var batteryTimer: Timer?
    var stream = FrameStream()
    var window: NSWindow!
    var textView: NSTextView!
    var seen = Set<UUID>()
    var scanTimer: Timer?
    var queryButton: NSButton!
    var summaryLabel: NSTextField!
    var commandTimer: Timer?
    var agentDirectoryModification:Date?
    var identity: Data?
    var authorized = false
    var readGroup: UInt32 = 0x1000
    enum SettingsPhase { case preflight, guardRead, verifyChange, restoreGuard, verifyRestore }
    var settingsPhase: SettingsPhase?
    var originalMore: Data?
    var proposedMore: Data?
    var moreSettings: Data?
    var roundtripSettings = false
    var desiredEnabled: Bool?
    var activeField: MoreToggleField = .vibration
    var noiseTest = false
    var activeOffset: Int { noiseTest ? 3 : activeField.rawValue }
    var settingName: String {
        if noiseTest { return "降噪震动实验" }
        switch activeField { case .childLock: return "童锁"; case .vibration: return "震动反馈"; case .led: return "LED 指示灯" }
    }
    var writeAcknowledged = false
    var messageID: UInt16 = 0
    var pending: [UInt16: UInt16] = [:]
    let logURL = URL(fileURLWithPath: projectRoot + "/logs/probe.log")

    func log(_ value: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + " " + value + "\n"
        textView?.textStorage?.append(NSAttributedString(string: line))
        textView?.scrollToEndOfDocument(nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8))
        } else { try? Data(line.utf8).write(to: logURL) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        for name in ["logs","backups","recordings"] {try? FileManager.default.createDirectory(at:DeviceConfig.dataDirectory.appendingPathComponent(name),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        setupAudioMenu()
        codexQuota.didUpdate = { [weak self] in guard let self=self else{return};self.controlPanel?.update(probe:self);self.menuPopover?.update(probe:self) };codexQuota.refresh()
        panelShortcut=PanelShortcut();panelShortcut?.onToggle = { [weak self] in self?.toggleControlPanel() }
        if let error=panelShortcut?.error { log(error) }
        DispatchQueue.main.async { [weak self] in guard let self=self else{return};self.edgeDock=EdgeDock(probe:self) }
        if SidebarPresentation.restore(pinned:UserDefaults.standard.bool(forKey:"sidebarPinned"),wasVisible:UserDefaults.standard.bool(forKey:"sidebarWasVisible")) { DispatchQueue.main.async { [weak self] in self?.showControlPanel() } }
        refreshBatteryDisplay()
        systemBatteryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshBatteryDisplay() }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 540), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        window.title = "Mic Pro · 音频选择与蓝牙诊断"
        window.isReleasedWhenClosed = false
        let root = window.contentView!
        let label = NSTextField(labelWithString: "蓝牙诊断：连续按三下电源键进入配对模式，提示确认时再单按。")
        label.frame = NSRect(x: 20, y: 492, width: 610, height: 24); root.addSubview(label)
        let audioButton = NSButton(title: "选择音频输入 / 输出", target: self, action: #selector(showAudioMenu(_:)))
        audioButton.frame = NSRect(x: 640, y: 488, width: 180, height: 32); root.addSubview(audioButton)
        let scan = NSButton(title: "重新扫描", target: self, action: #selector(rescan))
        scan.frame = NSRect(x: 20, y: 450, width: 120, height: 32); root.addSubview(scan)
        queryButton = NSButton(title: "刷新设备与设置", target: self, action: #selector(query))
        queryButton.frame = NSRect(x: 154, y: 450, width: 220, height: 32); queryButton.isEnabled = false; root.addSubview(queryButton)
        summaryLabel = NSTextField(labelWithString: "蓝牙控制待连接 · 连接后可切换震动反馈")
        summaryLabel.frame = NSRect(x: 386, y: 452, width: 440, height: 26)
        root.addSubview(summaryLabel)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 800, height: 414))
        scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width,.height]
        textView = NSTextView(frame: scroll.bounds); textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        scroll.documentView = textView; root.addSubview(scroll)
        window.center()
        log("应用启动（固定签名）；仅连接名称包含 \(DeviceConfig.serialSuffix) 的设备。设置操作将记录写入和读回结果。")
        central = CBCentralManager(delegate: self, queue: .main)
        if DeviceConfig.target == nil {lastActionSummary="尚未配置设备，请参照 README 配置你的 Mic Pro。";DispatchQueue.main.async {[weak self] in self?.showControlPanel()}}
        commandTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.tickAgentBridge()
            guard DeviceConfig.experimentalFeaturesEnabled else { return }
            let url = URL(fileURLWithPath: projectRoot + "/logs/action.txt")
            guard let action = try? String(contentsOf: url, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: url)
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "observe-discovery" { self.startDiscoveryObservation() }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "stop-discovery-observation" { self.stopDiscoveryObservation() }
            if ["app-control-query-now", "app-control-pulse-now"].contains(action.trimmingCharacters(in: .whitespacesAndNewlines)) {
                self.showInteractiveTest(); self.interactiveTest?.portSelector.selectItem(at: 2)
                self.interactiveTest?.pulseRequested = action.trimmingCharacters(in: .whitespacesAndNewlines) == "app-control-pulse-now"
                self.interactiveTest?.holdMode.state = .off; self.interactiveTest?.previewMode()
                self.interactiveTest?.start()
            }
            if ["interactive-candidate-ack", "candidate-ack-now"].contains(action.trimmingCharacters(in: .whitespacesAndNewlines)) {
                self.showInteractiveTest(); self.interactiveTest?.portSelector.selectItem(at: 1)
                self.interactiveTest?.holdMode.state = .off; self.interactiveTest?.previewMode()
                self.interactiveTest?.acknowledgementProbe = true
                self.interactiveTest?.detail.stringValue = "端口11：腾讯协议应答测试，只发 type2 包，不执行设置或绑定。验证声音连续性时请先开启语音输入。"
                if action.trimmingCharacters(in: .whitespacesAndNewlines) == "candidate-ack-now" { self.interactiveTest?.start() }
            }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "interactive-candidate" {
                self.showInteractiveTest(); self.interactiveTest?.portSelector.selectItem(at: 1)
                self.interactiveTest?.acknowledgementProbe = false
                self.interactiveTest?.holdMode.state = .off; self.interactiveTest?.previewMode()
                self.interactiveTest?.detail.stringValue = "候选端口 11：只连接监听，不发送设置命令。请先重新开启语音输入，再点开始。"
            }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "show-menu-popover" { self.toggleMenuPopover() }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "show-control-panel" { self.showControlPanel() }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "show-wallpaper-library" { self.chooseWallpaperImage() }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "interactive-test" { self.showInteractiveTest() }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "query" { self.query() }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "probe-serial-read" { self.startSerialProbe(asynchronous: true, readOnly:true) }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "probe-serial-async" { self.startSerialProbe(asynchronous: true) }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "probe-serial" { self.startSerialProbe() }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "probe-parallel" { self.startParallelProbe(bridging: false) }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "probe-parallel-bridge" { self.startParallelProbe(bridging: true) }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "scan" { self.rescan() }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "test-vibration" { self.beginVibrationTest() }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "test-noise-feedback" { self.beginNoiseFeedbackTest() }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "test-child-lock" { self.beginSettingsChange(field: .childLock, enabled: nil, roundtrip: true) }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "test-led" { self.beginSettingsChange(field: .led, enabled: nil, roundtrip: true) }
            if action.trimmingCharacters(in: .whitespacesAndNewlines) == "read-more" { self.readGroup = 0x1012; self.readAttributes() }
        }
        if let timer = commandTimer { timer.tolerance=0.05;RunLoop.main.add(timer, forMode: .common) }
        if let timer = systemBatteryTimer { timer.tolerance=0.25;RunLoop.main.add(timer, forMode: .common) }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("CoreBluetooth 状态=\(central.state.rawValue)，授权=\(CBCentralManager.authorization.rawValue)")
        if central.state == .poweredOn { log("蓝牙控制可用；需要诊断时点击重新扫描。顶部 Mic 菜单可独立选择音频输入和输出。") }
        if central.state == .unauthorized { log("需要在系统设置 → 隐私与安全性 → 蓝牙，允许 Mic Pro Probe。") }
    }
    @objc func rescan() {
        guard DeviceConfig.target != nil else {lastActionSummary="请先运行 scripts/configure-device.py 配置你的 Mic Pro，再重启小工具。";return}
        guard !handoffSuppressed else { lastActionSummary="请先点击连接回 Mac"; return }
        guard central.state == .poweredOn else { log("蓝牙尚未可用"); return }
        if peripheral?.state == .connected { log("目标已经连接"); return }
        guard peripheral == nil else { log("控制连接正在建立，请稍候"); return }
        guard !bluetoothOperation else { log("正在切换蓝牙连接，请稍候"); return }
        if let device = SystemBattery.device(), device.isConnected() {
            switchingToControl = true; bluetoothOperation = true; bluetoothResult = nil
            summaryLabel.stringValue = "正在释放音频连接，准备设置控制…"
            log("进入设置控制前，先断开 Mic Pro 音频蓝牙。")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = device.closeConnection()
                DispatchQueue.main.async { self?.waitForAudioRelease(result: result) }
            }
            return
        }
        controlWanted = true; reconnectAttempts = 0
        seen.removeAll(); central.stopScan(); scanTimer?.invalidate()
        let known = central.retrieveConnectedPeripherals(withServices: [serviceID])
        for p in known where p.name?.contains(DeviceConfig.serialSuffix) == true { connect(p); return }
        let cached = UserDefaults.standard.string(forKey: "verifiedPeripheralID") ?? ""
        if let id = UUID(uuidString: cached), let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            log("使用已验证设备标识直连控制通道，避免依赖重新扫描广播。")
            connect(p); return
        }
        log("开始扫描 BLE 广播（30 秒）。如仍未发现，请连续按三下电源键。")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self = self else { return }; self.central.stopScan()
            if self.peripheral == nil { self.log("扫描结束：没有发现 \(DeviceConfig.serialSuffix) 的 BLE 广播。音频连接不代表控制广播可用；需要设备进入配对模式后重新扫描。") }
        }
    }
    func waitForAudioRelease(result: IOReturn, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if SystemBattery.device()?.isConnected() != true {
                self.switchingToControl = false; self.bluetoothOperation = false
                self.log("音频连接已释放，开始连接设置控制。")
                self.refreshBatteryDisplay(); self.rescan()
            } else if attempt < 19 {
                self.waitForAudioRelease(result: result, attempt: attempt + 1)
            } else {
                self.switchingToControl = false; self.bluetoothOperation = false
                self.bluetoothResult = "音频连接未释放，无法进入设置控制"
                self.summaryLabel.stringValue = self.bluetoothResult!
                self.log(String(format: "音频释放超时，返回码=%08X", result))
            }
        }
    }
    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.log(String(format: "SPP open callback=%08X",status))
            if self.serialPulse != nil { self.serialPulseOpened(channel, status: status); return }
            if status == 0, self.serialReadProbe {
                var bytes = Array(serialNoiseRequest())
                let result = bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
                self.log(String(format:"SPP 只读降噪查询写入=%08X",result))
            }
        }
    }
    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.log("SPP channel closed callback")
            if self.serialPulse != nil, channel === self.serialProbeChannel { self.finishSerialPulse(error: "串口连接关闭，恢复状态未确认") }
        }
    }
    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length count: Int) {
        let data = Data(bytes: pointer, count: count)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for packet in self.serialStream.append(data) {
                self.log("SPP 控制包：cmd=\(packet.command), data=" + packet.payload.map { String(format: "%02X", $0) }.joined(separator: " "))
                self.handleSerialPulse(packet)
            }
        }
    }

    func startSerialProbe(asynchronous: Bool = false, readOnly: Bool = false) {
        guard !handoffSuppressed else { return }
        guard pulseWorkflow == nil, !bluetoothOperation, peripheral == nil, let device = SystemBattery.device(), device.isConnected(),
              let services = device.services as? [IOBluetoothSDPServiceRecord], let service = services.first(where: { $0.matchesUUID16(0x1101) }) else { log("SPP 实验前置条件不满足"); return }
        var id: BluetoothRFCOMMChannelID = 0
        guard service.getRFCOMMChannelID(&id) == 0 else { log("无法读取公布的 SPP 端口"); return }
        serialReadProbe = readOnly; bluetoothOperation = true
        log("SPP 只读实验开始：使用已公布端口 \(id)，保留音频连接。")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var channel: IOBluetoothRFCOMMChannel?
            let result = asynchronous ? device.openRFCOMMChannelAsync(&channel, withChannelID: id, delegate: self) : device.openRFCOMMChannelSync(&channel, withChannelID: id, delegate: self)
            // A distinct vendor handshake was observed; do not replay BLE frames into it.
            DispatchQueue.main.async {
                self.log(String(format:"SPP open=%08X, write=%@, audio=%@",result,"not sent",String(device.isConnected())))
                self.serialProbeChannel = channel
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    _ = self.serialProbeChannel?.close(); self.serialProbeChannel = nil; self.serialReadProbe = false; self.bluetoothOperation = false
                    self.log("SPP 实验结束，audio=\(device.isConnected())")
                }
            }
        }
    }
    func startParallelProbe(bridging: Bool) {
        guard !handoffSuppressed else { return }
        guard !bridging else { log("Apple 传输桥接选项在 macOS SDK 中明确不可用，未发送此选项。"); return }
        guard pulseWorkflow == nil, pending.isEmpty, settingsPhase == nil, peripheral == nil, !bluetoothOperation,
              central.state == .poweredOn, SystemBattery.device()?.isConnected() == true else { log("并行实验需要音频已连接、控制未连接且无其他操作"); return }
        let id = UserDefaults.standard.string(forKey: "verifiedPeripheralID") ?? ""
        guard let uuid = UUID(uuidString: id), let p = central.retrievePeripherals(withIdentifiers: [uuid]).first else { log("并行实验无法获取目标"); return }
        parallelBridging = bridging; controlWanted = false; bluetoothOperation = true
        let started = Date(); var previous = ""
        log("并行实验开始：保留音频，bridging=\(bridging)，不发送主动音频断开。")
        parallelTimer?.invalidate()
        parallelTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let audio = SystemBattery.device()?.isConnected() == true
            let available = (try? AudioRouting.devices())?.contains(where: { $0.name.contains(DeviceConfig.serialSuffix) && $0.inputChannels > 0 }) == true
            let state = "audio=\(audio),inputPresent=\(available),control=\(self.peripheral?.state.rawValue ?? -1),authorized=\(self.authorized)"
            if state != previous { self.log("并行观察：" + state); previous = state }
            if Date().timeIntervalSince(started) >= 24 {
                timer.invalidate(); self.parallelTimer = nil; self.parallelBridging = nil; self.bluetoothOperation = false
                if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
                self.log("并行实验结束：" + state)
            }
        }
        if let timer = parallelTimer { RunLoop.main.add(timer, forMode: .common) }
        connect(p)
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        if seen.insert(peripheral.identifier).inserted && name.lowercased().contains("insta") { log("发现 \(name)，RSSI=\(RSSI)") }
        if name.contains(DeviceConfig.serialSuffix) { connect(peripheral) }
    }
    func connect(_ p: CBPeripheral) {
        guard !handoffSuppressed else { return }
        guard peripheral == nil else { return }
        central.stopScan(); scanTimer?.invalidate(); peripheral = p; p.delegate = self
        connectionToken = UUID(); let token = connectionToken
        log("连接目标：\(p.name ?? DeviceConfig.serialSuffix)，BLE ID=\(p.identifier)")
        summaryLabel.stringValue = "设置控制连接中…"
        central.connect(p, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self = self, self.connectionToken == token, self.peripheral?.identifier == p.identifier, self.peripheral?.state == .connecting else { return }
            self.log("连接超时；请确认设备处于配对模式。"); self.central.cancelPeripheralConnection(p)
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !handoffSuppressed else { central.cancelPeripheralConnection(peripheral); return }
        reconnectAttempts = 0
        log("BLE 已连接；开始发现控制服务"); peripheral.discoverServices([serviceID, batteryServiceID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("连接失败：\(String(describing:error))"); reset(); reconnectControlIfNeeded()
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("BLE 已断开：\(String(describing:error))"); reset(); reconnectControlIfNeeded()
    }
    func reconnectControlIfNeeded() {
        guard !handoffSuppressed else { lastActionSummary="请先点击连接回 Mac"; return }
        guard controlWanted, central.state == .poweredOn, reconnectAttempts < 2 else {
            if controlWanted { log("控制重连未成功：设备可能没有开放控制广播，需要三按电源键后再连接。") }
            return
        }
        reconnectAttempts += 1
        let id = UserDefaults.standard.string(forKey: "verifiedPeripheralID") ?? ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, !self.handoffSuppressed, self.controlWanted, self.peripheral == nil, self.central.state == .poweredOn,
                  let uuid = UUID(uuidString: id), let p = self.central.retrievePeripherals(withIdentifiers: [uuid]).first else { return }
            self.log("尝试恢复控制连接（不重发设置写入）。")
            self.connect(p)
        }
    }
    func reset() { batteryTimer?.invalidate(); batteryTimer = nil; batteryCharacteristic = nil; bleBatteryLevel = nil; refreshBatteryDisplay(); summaryLabel.stringValue = "已断开 · 点击重新扫描"; peripheral = nil; writer = nil; receiver = nil; pending.removeAll(); stream = FrameStream(); identity = nil; authorized = false; moreSettings = nil; settingsPhase = nil; originalMore = nil; proposedMore = nil; queryButton.isEnabled = false }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { log("服务发现失败：\(error)"); return }
        if let battery = peripheral.services?.first(where: { $0.uuid == batteryServiceID }) {
            peripheral.discoverCharacteristics([batteryLevelID], for: battery)
        } else { log("未提供标准 BLE 电量服务，继续检查其他电量来源。") }
        guard let service = peripheral.services?.first(where: {$0.uuid == serviceID}) else { log("未找到预期控制服务"); return }
        log("确认控制服务：\(service.uuid)"); peripheral.discoverCharacteristics([writeID,notifyID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error { log("特征发现失败：\(error)"); return }
        if service.uuid == batteryServiceID {
            guard let c = service.characteristics?.first(where: { $0.uuid == batteryLevelID }) else { return }
            batteryCharacteristic = c
            if c.properties.contains(.read) { peripheral.readValue(for: c) }
            if c.properties.contains(.notify) { peripheral.setNotifyValue(true, for: c) }
            batteryTimer?.invalidate()
            batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                guard let self = self, let p = self.peripheral, p.state == .connected, let c = self.batteryCharacteristic, c.properties.contains(.read) else { return }
                p.readValue(for: c)
            }
            return
        }
        for c in service.characteristics ?? [] {
            log("特征 \(c.uuid)，properties=\(c.properties.rawValue)")
            if c.uuid == writeID { writer = c }
            if c.uuid == notifyID { receiver = c }
        }
        guard let rx = receiver, let tx = writer, rx.properties.contains(.notify), tx.properties.contains(.write) || tx.properties.contains(.writeWithoutResponse) else { log("控制特征拓扑不匹配"); return }
        peripheral.setNotifyValue(true, for: rx)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == batteryLevelID { return }
        if let error = error { log("通知订阅失败：\(error)"); return }
        log("通知订阅=\(characteristic.isNotifying)；可进行只读协议验证")
        queryButton.isEnabled = characteristic.isNotifying
        if characteristic.isNotifying { sendRead(command: 0x1009) }
    }
    @objc func query() {
        guard !handoffSuppressed else { return }
        refreshBatteryDisplay()
        if let p = peripheral, p.state == .connected, let c = batteryCharacteristic, c.properties.contains(.read) { p.readValue(for: c) }
        guard pending.isEmpty, settingsPhase == nil else { log("等待当前查询或设置操作完成"); return }
        readGroup = 0x1000
        sendRead(command: 0x1009)
    }
    func sendRead(command: UInt16, body: Data = Data()) {
        guard !handoffSuppressed else { return }
        if command == 0x1015 { lastControlMutationAt = Date() }
        guard let p = peripheral, let tx = writer, receiver?.isNotifying == true else { return }
        messageID &+= 1; let id = messageID
        let payload = Data([UInt8(id & 255),UInt8(id >> 8)]) + body
        let bytes: [UInt8] = [0xFE,0xEF,1,UInt8(command & 255),UInt8(command >> 8),0,0,UInt8(payload.count & 255),UInt8(payload.count >> 8)] + payload
        pending[id] = command
        log(String(format:"%@ command=%04X message=%d", command == 0x1015 ? "设置写入（无自动重试）" : "只读请求",command,id))
        p.writeValue(Data(bytes), for: tx, type: tx.properties.contains(.write) ? .withResponse : .withoutResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.pending.removeValue(forKey:id) != nil {
                self?.log("请求超时；设置写入不会自动重试。")
                if command == 0x1015 { self?.readAttributes() }
                else if self?.settingsPhase != nil { self?.log("设置操作暂停：读回失败，原值保存在本地日志"); self?.settingsPhase = nil }
            }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error { log("GATT 请求发送错误：\(error)") }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error { log("通知错误：\(error)"); return }
        guard let value = characteristic.value else { return }
        if characteristic.uuid == batteryLevelID {
            guard value.count == 1, let level = value.first, level <= 100 else { log("电量响应格式无效"); return }
            bleBatteryLevel = Int(level); refreshBatteryDisplay()
            log("标准 BLE 电量：\(level)%")
            return
        }
        log("收到通知：\(value.map{String(format:"%02X",$0)}.joined(separator:" "))")
        for frame in stream.append(value) {
            log(String(format:"帧 command=%04X seq=%04X payload=%d",frame.command,frame.sequence,frame.payload.count))
            if frame.command == 0x100E, frame.sequence == 0, frame.payload.count == 38,
               let identity = identity, Data(frame.payload[2..<33]) == identity.prefix(31) {
                log("收到匹配设备身份的物理确认通知：授权字节=\(frame.payload[34])")
                sendRead(command: 0x100D, body: identity)
                continue
            }
            guard frame.sequence >> 14 == 0, frame.payload.count >= 3 else { continue }
            let payload = [UInt8](frame.payload)
            let id = UInt16(payload[0]) | UInt16(payload[1]) << 8
            guard pending[id] == frame.command else { continue }
            pending.removeValue(forKey:id)
            handleResponse(command: frame.command, status: payload[2], body: Data(payload.dropFirst(3)))
            log("响应已关联 message=\(id)，status=\(payload[2])，body=\(payload.dropFirst(3).map{String(format:"%02X",$0)}.joined(separator:" "))")
        }
    }
    func readAttributes() {
        guard authorized, let identity = identity else { log("尚未授权，暂停参数查询"); return }
        let group = Data([UInt8(readGroup & 255), UInt8((readGroup >> 8) & 255), 0, 0])
        log("读取已验证设置组 group=\(String(readGroup, radix:16))")
        sendRead(command: 0x1014, body: group + identity)
    }
    func handleResponse(command: UInt16, status: UInt8, body: Data) {
        if command == 0x1009 && status == 0 && body.count >= 34 && body[0] == 1 {
            let raw = Data(body[1..<33])
            let serial = String(decoding: raw.dropFirst(16).prefix(while: {$0 != 0}), as: UTF8.self)
            guard serial.hasSuffix(DeviceConfig.serialSuffix) else { log("身份与 \(DeviceConfig.serialSuffix) 不符，停止查询"); return }
            identity = raw
            log("设备身份已核对，开始带身份的授权状态查询")
            sendRead(command: 0x100D, body: raw)
        }
        if command == 0x1014 {
            log("参数查询返回：status=\(status)，body 字节数=\(body.count)")
            guard status == 0, let identity = identity,
                  let values = try? settingsResponse(body, identity: identity, group: UInt16(readGroup)) else {
                log("设置响应不符合已验证格式，停止"); return
            }
            log("完整设置已核验：\(values.map{String(format:"%02X",$0)}.joined(separator:" "))")
            if readGroup == 0x1000 { lastInternalRecording = values[0] == 1; lastInternalRecordingAt = Date(); latestCommon = values }
            if readGroup == 0x1012 { moreSettings = values }
            if settingsPhase != nil { handleSettingsRead(values); return }
            if readGroup == 0x1000 {
                log("Common：录音=\(values[0])，静音=\(values[1])，增益=\(Int8(bitPattern:values[2])) dB，降噪=\(values[3])")
                readGroup = 0x1012; readAttributes()
            } else {
                refreshMoreSummary(values)
                log("More：震动反馈=\(values[9] == 1 ? "开启" : "关闭")，32位浮点=\(values[0])，低切=\(values[4])")
            }
        }
        if command == 0x1015 {
            writeAcknowledged = status == 0 && body.isEmpty
            log("设置写入 ACK=\(writeAcknowledged)，开始全组读回")
            readAttributes()
        }
        if command == 0x100D {
            log("授权回复：status=\(status)，body 字节数=\(body.count)")
            if status == 0, body.count == 33, let identity = identity, body.prefix(32) == identity, body[32] == 0 {
                authorized = true
                if let p = peripheral { UserDefaults.standard.set(p.identifier.uuidString, forKey: "verifiedPeripheralID") }
                log("设备授权已确认，开始读取 Common 设置")
                readAttributes()
            } else {
                log("等待设备物理确认；尚未发送设置写入")
                summaryLabel.stringValue = "等待电源键单按确认"
            }
        }
    }
    @objc func beginVibrationTest() { beginSettingsChange(field: .vibration, enabled: nil, roundtrip: true) }
    @objc func toggleVibration() {
        guard let values = moreSettings else { return }
        beginSettingsChange(field: .vibration, enabled: values[9] == 0, roundtrip: false)
    }
    @objc func toggleLeds() {
        guard let values = moreSettings else { return }
        beginSettingsChange(field: .led, enabled: values[10] == 0, roundtrip: false)
    }
    func beginSettingsChange(field: MoreToggleField, enabled: Bool?, roundtrip: Bool) {
        guard !handoffSuppressed else { return }
        guard authorized, peripheral?.state == .connected, identity != nil, pending.isEmpty, settingsPhase == nil else {
            log("请先连接并读取麦克风设置，等待当前操作完成"); return
        }
        noiseTest = false; activeField = field; desiredEnabled = enabled; roundtripSettings = roundtrip
        originalMore = nil; proposedMore = nil; settingsPhase = .preflight
        readGroup = 0x1012; readAttributes()
    }
    @objc func beginNoiseFeedbackTest() {
        guard !handoffSuppressed else { return }
        guard authorized, peripheral?.state == .connected, identity != nil, pending.isEmpty, settingsPhase == nil, moreSettings?[9] == 1 else {
            log("降噪震动测试需要控制连接已授权且震动反馈已开启"); return
        }
        noiseTest = true; roundtripSettings = true
        originalMore = nil; proposedMore = nil; settingsPhase = .preflight
        readGroup = 0x1000; readAttributes()
    }
    func refreshMoreSummary(_ values: Data) {
        guard values.count == 12 else { return }
        summaryLabel.stringValue = "震动反馈：\(values[9] == 1 ? "开" : "关") · LED：\(values[10] == 1 ? "开" : "关")"
    }
    func writeMore(_ values: Data) {
        guard authorized, let identity = identity, let body = try? (noiseTest ? commonSettingsWriteBody(identity: identity, values: values) : moreSettingsWriteBody(identity: identity, values: values)) else {
            log("设置写入前校验失败"); settingsPhase = nil; return
        }
        writeAcknowledged = false
        sendRead(command: 0x1015, body: body)
    }
    func handleSettingsRead(_ values: Data) {
        switch settingsPhase {
        case .preflight:
            if !noiseTest && activeField == .childLock && values[9] != 1 {
                log("童锁震动实验取消：震动反馈未开启。"); settingsPhase = nil; return
            }
            originalMore = values
            let desired = desiredEnabled ?? (values[activeOffset] == 0)
            guard let target = try? (noiseTest ? noiseFeedbackSnapshot(values) : moreToggleSnapshot(values, field: activeField, enabled: desired)) else { settingsPhase = nil; return }
            guard values != target else { log("\(settingName)已是所选状态"); settingsPhase = nil; return }
            proposedMore = target
            log("\(settingName)：\(values[activeOffset]) → \(target[activeOffset])；另外 \(values.count - 1) 个设置字节保持原值。测试模式=\(roundtripSettings)")
            settingsPhase = .guardRead; readAttributes()
        case .guardRead:
            guard values == originalMore, let target = proposedMore else { log("设置在预检后变化，取消写入"); settingsPhase = nil; return }
            settingsPhase = .verifyChange; writeMore(target)
        case .verifyChange:
            guard values == proposedMore else { log("写入未得到预期全组读回，停止；原始组=\(originalMore?.map{String(format:"%02X",$0)}.joined() ?? "未知")"); settingsPhase = nil; return }
            log("\(settingName)变更已全组读回确认，ACK=\(writeAcknowledged)")
            if roundtripSettings {
                settingsPhase = .restoreGuard
                if noiseTest {
                    log("降噪变更已确认，立即读取并恢复原值；不额外等待。")
                    readAttributes()
                } else if activeField == .childLock {
                    log("\(settingName)：保持 5 秒供触觉观察，然后读取设置并恢复原值；读回成功不代表已经震动。")
                    Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                        guard let self = self, self.settingsPhase == .restoreGuard else { return }
                        guard self.authorized, self.peripheral?.state == .connected else {
                            self.log("\(self.settingName)恢复中断：连接已断开，需要重新读取状态。"); self.settingsPhase = nil; return
                        }
                        self.readAttributes()
                    }
                } else { readAttributes() }
            }
            else { settingsPhase = nil; refreshMoreSummary(values) }
        case .restoreGuard:
            guard values == proposedMore, let original = originalMore else { log("设置发生变化，暂停恢复"); settingsPhase = nil; return }
            settingsPhase = .verifyRestore; writeMore(original)
        case .verifyRestore:
            guard values == originalMore else { log("原值恢复读回不匹配，需要检查日志"); settingsPhase = nil; return }
            log("PASS：\(settingName)变更及恢复均全组读回确认，其他 \(values.count - 1) 字节一致，恢复 ACK=\(writeAcknowledged)")
            refreshMoreSummary(values)
            if noiseTest { pulseWorkflow?.restored = true }
            settingsPhase = nil
        case nil: break
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func setupAudioMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Mic"
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Mic Pro 音频选择")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.toolTip = "分别选择麦克风输入与耳机输出"
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self; statusItem.menu = nil
        statusItem.button?.target=self;statusItem.button?.action=#selector(toggleMenuPopover)
        statusItem.button?.sendAction(on:[.leftMouseUp,.rightMouseUp])
    }
    func requestFreshBattery() {
        guard !batteryReadPending, Date().timeIntervalSince(batteryReadStarted) > 4 else { return }
        batteryReadPending = true; batteryReadStarted = Date()
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MicProBatteryReader")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process(); process.executableURL = path
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            var level: Int?
            do {
                try process.run()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let value = object["percent"] as? Int, (1...100).contains(value) { level = value }
            } catch {}
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.batteryReadPending = false
                if let value = level {
                    self.helperBatteryLevel = value; self.helperBatteryAt = Date()
                    self.lastBatteryLevel = value; UserDefaults.standard.set(value, forKey: "lastBatteryLevel")
                }
                self.refreshBatteryDisplay()
            }
        }
    }
    func refreshBatteryDisplay() {
        let previous = batteryLevel
        batteryIsCached = false
        if SystemBattery.device()?.isConnected() != true || handoffSuppressed { batteryPowerReading = nil }
        if SystemBattery.device()?.isConnected() == true, currentBatteryPower == nil { requestFreshBattery() }
        if let reading = currentBatteryPower {
            batteryLevel = reading.info.percent; lastBatteryLevel = reading.info.percent; batterySource = "设备电池只读"
        } else if SystemBattery.device()?.isConnected() == true, Date().timeIntervalSince(helperBatteryAt) < 12, let level = helperBatteryLevel {
            batteryLevel = level; lastBatteryLevel = level; batterySource = "macOS 独立读取"
        } else if let level = SystemBattery.micProLevel() {
            batteryLevel = level; batterySource = "macOS 蓝牙"; lastBatteryLevel = level
            UserDefaults.standard.set(level, forKey: "lastBatteryLevel")
        } else if SystemBattery.device()?.isConnected() == true, let last = lastBatteryLevel {
            batteryLevel = last; batteryIsCached = true; batterySource = "macOS 上次读取"
        }
        else if peripheral?.state == .connected, let level = bleBatteryLevel { batteryLevel = level; batterySource = "BLE" }
        else { batteryLevel = nil; batterySource = nil }
        updateStatusTitle()
        if batteryLevel != previous, let level = batteryLevel { log("电量更新：\(level)%，来源=\(batterySource ?? "未知")") }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        buildCompactMenu(menu)
    }
    @objc func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(url) }
    }
    @objc func toggleControlConnection() {
        guard !handoffSuppressed else { lastActionSummary="请先点击连接回 Mac"; return }
        guard settingsPhase == nil, pending.isEmpty, !bluetoothOperation else { return }
        if let p = peripheral, p.state == .connected || p.state == .connecting { controlWanted = false; central.cancelPeripheralConnection(p) }
        else { rescan() }
    }
    @objc func toggleBluetooth() {
        guard !handoffSuppressed else { lastActionSummary="请先点击连接回 Mac"; return }
        guard !bluetoothOperation, settingsPhase == nil, pending.isEmpty, let device = SystemBattery.device() else { return }
        let disconnect = device.isConnected()
        bluetoothOperation = true; bluetoothResult = nil
        controlWanted = false
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        log(disconnect ? "正在断开 Mic Pro 音频蓝牙…" : "正在连接 Mic Pro 音频蓝牙，先释放设置控制通道…")
        performClassicConnection(device, disconnect: disconnect, source: "audio-menu")
    }
    func performClassicConnection(_ device: IOBluetoothDevice, disconnect: Bool, source: String, attempt: Int = 0) {
        guard disconnect || !handoffSuppressed else {
            log("已阻止交接期间的音频重连：source=\(source)")
            replyMacReturn(success:false); return
        }
        if attempt == 0 { log("经典蓝牙请求：source=\(source)，disconnect=\(disconnect)，suppressed=\(handoffSuppressed)") }
        if peripheral != nil {
            guard attempt < 25 else {
                dockConnectRequested=false; bluetoothOperation = false; bluetoothResult = "控制通道尚未断开，请稍后再连接音频"; replyMacReturn(success:false); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.performClassicConnection(device, disconnect: disconnect, source: source, attempt: attempt + 1)
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = disconnect ? device.closeConnection() : device.openConnection()
            DispatchQueue.main.async {
                self?.verifyBluetoothOperation(disconnect: disconnect, result: result)
            }
        }
    }

    func verifyBluetoothOperation(disconnect: Bool, result: IOReturn, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            let connected = SystemBattery.device()?.isConnected() == true
            if connected == !disconnect {
                self.lastActionSummary = disconnect ? "Mac 蓝牙已断开" : "Mac 蓝牙已连接 · 可选择麦克风输入"
                if !disconnect { UserDefaults.standard.removeObject(forKey:"meetingModeRequested");self.replyMacReturn(success:true) }
                self.dockConnectRequested=false; self.bluetoothOperation = false; self.bluetoothResult = nil
                self.log(disconnect ? "Mic Pro 蓝牙已断开" : "Mic Pro 蓝牙已连接；可在输入菜单选择麦克风")
                self.refreshBatteryDisplay()
            } else if attempt < 9 {
                self.verifyBluetoothOperation(disconnect: disconnect, result: result, attempt: attempt + 1)
            } else {
                self.dockConnectRequested=false; self.bluetoothOperation = false
                self.replyMacReturn(success:false)
                self.bluetoothResult = "连接未完成：请确认麦克风开机、手机已断开；必要时进入配对模式再试"
                self.lastActionSummary=self.bluetoothResult
                self.log(String(format: "蓝牙状态未达到预期，返回码=%08X", result))
                self.refreshBatteryDisplay()
            }
        }
    }
    @objc func selectAudio(_ item: NSMenuItem) {
        guard let uid = item.representedObject as? String else { return }
        do {
            try AudioRouting.select(uid: uid, direction: item.tag == 0 ? .input : .output)
            if item.tag == 0 { pulseWorkflow?.inputUID = uid }
            log("已切换\(item.tag == 0 ? "输入" : "输出")：\(item.title)")
        } catch {
            log(error.localizedDescription)
            let alert = NSAlert(); alert.messageText = "音频切换失败"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    @objc func showAudioMenu(_ sender: NSButton) {
        let menu=NSMenu();addAudioChoices(to:menu);menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.height),in:sender)
    }
    @objc func showDiagnostic() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationWillTerminate(_ notification: Notification) { meetingModeSession?.cancel();panelShortcut=nil;edgeDock=nil }
    @objc func quitApp() { NSApp.terminate(nil) }

}
let app = NSApplication.shared
let delegate = Probe()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
