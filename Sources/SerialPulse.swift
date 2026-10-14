import Foundation
import IOBluetooth

final class SerialPulse {
    enum Stage { case opening, baseline, guardRead, changed, restored }
    let id: String
    let started = Date()
    var stage: Stage = .opening
    var original: UInt8?
    var proposed: UInt8?
    var writeAttempted = false
    var awaitingReadback = false
    var audioContinuous = true
    var inputContinuous = true
    var inputWasRunning = false
    var runningContinuous = true
    var timer: Timer?
    init(id: String) { self.id = id }
}

extension Probe {
    var serialHapticAvailable: Bool {
        guard !handoffSuppressed, let device = SystemBattery.device(), device.isConnected(),
              let services = device.services as? [IOBluetoothSDPServiceRecord] else { return false }
        return services.contains { $0.matchesUUID16(0x1101) }
    }
    func startSerialPulse(id: String) {
        guard !handoffSuppressed, let device = SystemBattery.device(), device.isConnected(),
              let services = device.services as? [IOBluetoothSDPServiceRecord],
              let service = services.first(where: { $0.matchesUUID16(0x1101) }) else {
            agentReply(id, ["ok": false, "error": "SPP 服务不可用；音频连接保留"]); return
        }
        var port: BluetoothRFCOMMChannelID = 0
        guard service.getRFCOMMChannelID(&port) == 0 else { agentReply(id, ["ok": false, "error": "SPP 端口不可用"]); return }
        let workflow = SerialPulse(id: id)
        workflow.inputWasRunning = PowerMonitor.usage()["mic_input_running"] as? Bool == true
        serialPulse = workflow; bluetoothOperation = true; serialStream = SerialPacketStream()
        log("SPP 震动开始：保留音频连接，读取并保护降噪原值。")
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self, weak workflow] _ in
            guard let self = self, let workflow = workflow, self.serialPulse === workflow else { return }
            workflow.audioContinuous = workflow.audioContinuous && device.isConnected()
            let usage = PowerMonitor.usage()
            workflow.inputContinuous = workflow.inputContinuous && usage["mic_input_present"] as? Bool == true
            if workflow.inputWasRunning { workflow.runningContinuous = workflow.runningContinuous && usage["mic_input_running"] as? Bool == true }
            if Date().timeIntervalSince(workflow.started) > 5 {
                self.finishSerialPulse(error: workflow.writeAttempted ? "串口设置恢复未确认；请检查降噪原值" : "串口只读查询超时，未修改设置")
            }
        }
        workflow.timer = timer; RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var channel: IOBluetoothRFCOMMChannel?
            let result = device.openRFCOMMChannelAsync(&channel, withChannelID: port, delegate: self)
            DispatchQueue.main.async {
                guard self.serialPulse === workflow else { _ = channel?.close(); return }
                self.serialProbeChannel = channel
                if result != 0 { self.finishSerialPulse(error: String(format: "SPP 打开失败：%08X", result)) }
            }
        }
    }
    func serialPulseOpened(_ channel: IOBluetoothRFCOMMChannel, status: IOReturn) {
        guard let workflow = serialPulse else { return }
        guard status == 0 else { finishSerialPulse(error: "SPP 连接未成功"); return }
        serialProbeChannel = channel; workflow.stage = .baseline
        sendSerialNoise()
    }
    func sendSerialNoise(_ value: UInt8? = nil) {
        guard let channel = serialProbeChannel, let workflow = serialPulse else { return }
        var bytes = Array(serialNoiseRequest(value))
        if value != nil { workflow.writeAttempted = true }
        let result = bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
        log("SPP \(value == nil ? "GET noise" : "SET noise=\(value!)")，返回码=\(result)")
        if result != 0 { finishSerialPulse(error: "SPP 写入失败，恢复状态未确认") }
    }
    func handleSerialPulse(_ packet: SerialPacket) {
        guard let workflow = serialPulse, let value = serialNoiseValue(packet) else { return }
        switch workflow.stage {
        case .opening: break
        case .baseline:
            workflow.original = value; workflow.stage = .guardRead
            log("SPP 降噪原值=\(value)，事务=\(workflow.id)")
            sendSerialNoise()
        case .guardRead:
            guard value == workflow.original else { finishSerialPulse(error: "降噪设置同时被其他程序修改，未触发震动"); return }
            let proposed: UInt8 = value == 1 ? 2 : 1
            workflow.proposed = proposed; workflow.stage = .changed
            sendSerialNoise(proposed)
        case .changed:
            guard value == workflow.proposed else { return }
            // Device's 0x05 notification acknowledges the exact value used by SET 0x82.
            // Restore immediately; never change mute, recording, gain or the audio connection.
            workflow.stage = .restored
            sendSerialNoise(workflow.original!)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self, weak workflow] in
                guard let self = self, let workflow = workflow, self.serialPulse === workflow else { return }
                workflow.awaitingReadback = true
                self.sendSerialNoise()
            }
        case .restored:
            // A notification alone is not a readback. Wait for our explicit GET below.
            if !workflow.awaitingReadback { return }
            guard value == workflow.original else { finishSerialPulse(error: "降噪原值读回不匹配"); return }
            finishSerialPulse(error: nil, restored: true)
        }
    }
    func finishSerialPulse(error: String?, restored: Bool = false) {
        guard let workflow = serialPulse else { return }
        workflow.timer?.invalidate()
        let audio = SystemBattery.device()?.isConnected() == true
        let ok = error == nil && restored && audio && workflow.audioContinuous && workflow.inputContinuous && workflow.runningContinuous
        agentReply(workflow.id, ["ok": ok, "transport": "spp", "settings_restored": restored,
            "audio_connected": audio, "audio_continuous": workflow.audioContinuous,
            "audio_data_continuity_verified": false, "audio_interruption_risk": "SPP 连接可能阻断语音输入，需要关闭串口并重新开启语音输入",
            "input_present_continuous": workflow.inputContinuous, "input_was_running": workflow.inputWasRunning,
            "input_running_continuous": workflow.inputWasRunning ? workflow.runningContinuous as Any : NSNull(),
            "elapsed_seconds": Date().timeIntervalSince(workflow.started),
            "error": error as Any? ?? (ok ? NSNull() : "音频连续性检查未通过")])
        serialPulse = nil; bluetoothOperation = false
        _ = serialProbeChannel?.close(); serialProbeChannel = nil
        log(ok ? "PASS：SPP 降噪恢复读回确认，音频连接和输入持续存在。" : "SPP 震动未全部确认：\(error ?? "音频连续性检查失败")")
        summaryLabel.stringValue = ok ? "设置恢复完成 · 语音可能需重新开启" : error ?? "音频连续性检查失败"
        refreshBatteryDisplay()
    }
}
