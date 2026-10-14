import AppKit
import IOBluetooth

extension Probe {
    var handoffSuppressed: Bool { handoffState.suppressAppConnections }
    var deviceTransactionBusy: Bool {
        meetingModeSession != nil || bluetoothOperation || pulseWorkflow != nil || serialPulse != nil || !pending.isEmpty || settingsPhase != nil ||
        interactiveTest?.busy == true || recordingReader?.busy == true || usbRecordingTransfer != nil ||
        usbInventoryBusy || screenUI != nil || parallelTimer != nil || serialReadProbe
    }
    var handoffDescription: String {
        switch handoffState.phase {
        case .mac: return "由 Mac 使用"
        case .releasing: return "正在释放 Mac 连接…"
        case .released: return SystemBattery.device()?.isConnected() == true ? "Mac 连接再次出现 · 本应用仍暂停主动连接" : "Mac 已断开 · 手机连接尚未确认"
        case .unconfirmed: return "已暂停本应用连接 · Mac 释放状态待确认"
        }
    }
    func persistHandoffIntent() { UserDefaults.standard.set(handoffSuppressed,forKey:"handoffSuppressConnections") }
    @objc func handoffToPhone() { startDeviceHandoff(id:nil) }
    @objc func connectBackToMac() { returnDeviceToMac(id:nil) }
    @objc func toggleDeviceOwnership() { if handoffSuppressed { connectBackToMac() } else { handoffToPhone() } }
    func startDeviceHandoff(id: String?) {
        guard handoffState.beginRelease(busy:deviceTransactionBusy) else {
            lastActionSummary="操作进行中，完成后再交接。不会取消传输或内录。"
            if let id=id { agentReply(id,["ok":false,"error":"busy"]) };return
        }
        persistHandoffIntent(); bluetoothOperation=true; controlWanted=false; reconnectAttempts=0; switchingToControl=false
        startHandoffObservation()
        connectionToken=UUID();central.stopScan();scanTimer?.invalidate();scanTimer=nil;batteryTimer?.invalidate();batteryTimer=nil
        if let p=peripheral { central.cancelPeripheralConnection(p) }
        if let channel=serialProbeChannel { _=channel.close();serialProbeChannel=nil }
        lastActionSummary=handoffDescription;log("交给手机：暂停本应用连接，释放BLE和经典连接，不解除配对。")
        waitForHandoffControl(id:id,attempt:0)
    }
    func waitForHandoffControl(id: String?,attempt: Int) {
        if peripheral != nil {
            guard attempt<25 else { completeDeviceHandoff(id:id,timedOut:true);return }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { [weak self] in self?.waitForHandoffControl(id:id,attempt:attempt+1) };return
        }
        guard let device=SystemBattery.device(),device.isConnected() else { completeDeviceHandoff(id:id,timedOut:false);return }
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result=device.closeConnection()
            DispatchQueue.main.async { self?.verifyDeviceHandoff(id:id,result:result,attempt:0) }
        }
    }
    func verifyDeviceHandoff(id: String?,result: IOReturn,attempt: Int) {
        if SystemBattery.device()?.isConnected() != true && peripheral == nil { completeDeviceHandoff(id:id,timedOut:false);return }
        guard attempt<20 else { log(String(format:"交接释放未确认，返回码=%08X",result));completeDeviceHandoff(id:id,timedOut:true);return }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in self?.verifyDeviceHandoff(id:id,result:result,attempt:attempt+1) }
    }
    func completeDeviceHandoff(id: String?,timedOut: Bool) {
        _=handoffState.observeRelease(classicConnected:SystemBattery.device()?.isConnected() == true,controlConnected:peripheral != nil || serialProbeChannel != nil,timedOut:timedOut)
        bluetoothOperation=false;lastActionSummary=handoffState.phase == .released ? "Mac 已断开，手机接管尚未验证；当前实测三按后仍可能无法发现设备。" : handoffDescription;bluetoothResult=handoffState.phase == .released ? nil : handoffDescription
        log(handoffDescription);refreshBatteryDisplay()
        if let id=id { agentReply(id,["ok":handoffState.phase == .released,"mac_released":handoffState.phase == .released,"app_connections_suppressed":true,"phone_connected":NSNull(),"phone_connection_verified":false,"phone_discovery_status":"unverified","pairing_removed":false,"error":handoffState.phase == .released ? NSNull() : "release_unconfirmed" as Any]) }
    }
    func returnDeviceToMac(id: String?) {
        guard !deviceTransactionBusy else { if let id=id { agentReply(id,["ok":false,"error":"busy"]) };lastActionSummary="请等待当前操作结束再连接回 Mac";return }
        guard let device=SystemBattery.device() else { lastActionSummary="未找到已配对 Mic Pro，请打开系统蓝牙设置";if let id=id { agentReply(id,["ok":false,"error":"not_paired"]) };return }
        log("收到返回 Mac 请求：source=\(id == nil ? "ui" : "agent")，request=\(id ?? "none")，此前suppressed=\(handoffSuppressed)")
        stopHandoffObservation(source: id == nil ? "ui" : "agent")
        _=handoffState.returnToMac(busy:false);persistHandoffIntent();lastActionSummary="正在连接回 Mac · 如手机仍占用，请先在手机断开"
        if device.isConnected() { UserDefaults.standard.removeObject(forKey:"meetingModeRequested");refreshBatteryDisplay();if let id=id { agentReply(id,["ok":true,"audio_connected":true]) };return }
        returnMacRequestID=id;bluetoothOperation=true;bluetoothResult=nil;controlWanted=false
        if let p=peripheral { central.cancelPeripheralConnection(p) }
        performClassicConnection(device,disconnect:false,source:id == nil ? "handoff-ui" : "handoff-agent")
    }
    func replyMacReturn(success: Bool) {
        guard let id=returnMacRequestID else{return};returnMacRequestID=nil
        agentReply(id,["ok":success,"audio_connected":success,"app_connections_suppressed":false,"phone_connected":NSNull(),"error":success ? NSNull() : "mac_connection_unconfirmed" as Any])
    }
}
