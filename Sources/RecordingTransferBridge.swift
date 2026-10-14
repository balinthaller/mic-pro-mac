import Foundation

extension Probe {
    func updateStatusTitle() {
        statusItem.button?.title = connectedUSBVolumes().isEmpty ? (batteryLevel.map { "Mic \(currentBatteryPower?.info.powerType == 1 ? "⚡" : "")\(batteryIsCached ? "~" : "")\($0)%" } ?? "Mic") : "Mic USB"
        statusItem.button?.toolTip = connectedUSBVolumes().first.map { "USB 已连接：" + $0.root.lastPathComponent + " · 有线文件传输" } ?? ("Mic Pro · " + chargingLabel)
    }
    func connectedUSBVolumes() -> [USBRecordingStore] {
        if Date().timeIntervalSince(usbVolumeCheckedAt) >= 2 {usbVolumeCheckedAt=Date();cachedUSBVolumes=USBRecordingStore.mounted()}
        return cachedUSBVolumes
    }

    func recordingTransferSnapshot() -> [String:Any]? {
        if let transfer = usbRecordingTransfer,transfer.isRunning { return transfer.snapshot }
        guard let controller = interactiveTest,controller.busy,controller.recordingsRequested,let id = controller.agentRequestID else { return nil }
        if let plan = controller.recordingDownloadPlan {
            return plan.progress.json().merging(["request_id":id,"transport":"bluetooth","can_cancel":controller.stage == "串口已打开"]){a,_ in a}
        }
        return ["request_id":id,"transport":"bluetooth","can_cancel":controller.stage == "串口已打开","phase":"读取文件索引","received_bytes":0,"total_bytes":0,"progress_fraction":0]
    }
    func cancelRecordingTransfer(_ target: String) -> Bool {
        if let transfer = usbRecordingTransfer,transfer.id == target,transfer.isRunning { transfer.cancel();return true }
        if let controller = interactiveTest,controller.agentRequestID == target,controller.busy,controller.recordingsRequested,controller.stage == "串口已打开" {
            controller.recordingCancelled=true;controller.recordingDownloadPlan?.cancel();controller.note("用户取消录音下载；只关闭控制通道，不发送END/删除指令");controller.close();return true
        }
        return false
    }
    func startRecordingRequest(id: String,fileID: UInt32? = nil,fragment: UInt16? = nil,transport: String = "auto",usbRoot: String? = nil,relative: String? = nil,maxBytes: Int = 512*1024*1024) {
        guard ["auto","bluetooth","usb"].contains(transport),UUID(uuidString:id) != nil else { agentReply(id,["ok":false,"error":"invalid_transport_or_id"]);return }
        guard !(transport == "bluetooth" && relative != nil), !(transport == "usb" && fileID != nil && relative == nil) else {
            agentReply(id,["ok":false,"error":"蓝牙下载需要file_id；USB下载需要relative_path。"]);return
        }
        let explicitRoot = usbRoot ?? UserDefaults.standard.string(forKey:"recordingUSBRoot")
        let store: USBRecordingStore?
        if let usbRoot=usbRoot { store=try? USBRecordingStore(root:URL(fileURLWithPath:usbRoot)) }
        else {store=explicitRoot.flatMap{try? USBRecordingStore(root:URL(fileURLWithPath:$0))} ?? connectedUSBVolumes().first}
        let useUSB = transport == "usb" || (transport == "auto" && store != nil && (fileID == nil || relative != nil))
        if useUSB {
            guard let store = store else { agentReply(id,["ok":false,"error":TransferError.invalidRoot.localizedDescription]);return }
            guard usbRecordingTransfer == nil,!usbInventoryBusy else { agentReply(id,["ok":false,"error":"文件操作进行中，请稍后再试。"]);return }
            if let relative = relative {
                let worker = USBRecordingTransfer(id:id,store:store,relative:relative,destination:URL(fileURLWithPath:projectRoot+"/recordings"))
                usbRecordingTransfer=worker
                DispatchQueue.global(qos:.utility).async { [weak self] in
                    let result=worker.run()
                    DispatchQueue.main.async {
                        guard let self=self else{return};self.lastRecordingTransferEndedAt=Date();self.usbRecordingTransfer=nil
                        self.agentReply(id,result)
                    }
                }
            } else {
                usbInventoryBusy=true
                DispatchQueue.global(qos:.utility).async { [weak self] in
                    let result: [String:Any]
                    do { let items=try store.inventory();result=["ok":true,"action":"recordings-list","transport":"usb","usb_root":store.root.path,"items":items,"total":items.count,"index_complete":true,"scope":"usb_recording_files","read_only":true] }
                    catch { result=["ok":false,"action":"recordings-list","error":error.localizedDescription] }
                    DispatchQueue.main.async { self?.usbInventoryBusy=false;self?.agentReply(id,result) }
                }
            }
            return
        }
        guard !bluetoothOperation,pulseWorkflow == nil,serialPulse == nil,pending.isEmpty,settingsPhase == nil,primaryControlAvailable,peripheral == nil else { agentReply(id,["ok":false,"error":"请连接音频蓝牙，或选择已连接的USB录音盘。"]);return }
        if interactiveTest == nil { interactiveTest=InteractiveSerialTest(probe:self) }
        interactiveTest?.startRecordings(id:id,fileID:fileID,fragment:fragment,maxBytes:maxBytes)
    }
}
