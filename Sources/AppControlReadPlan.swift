import Foundation

/// Offline-testable read-only sequence for the primary settings transport.
/// This object does not connect, write settings, or retry any request automatically.
final class AppControlReadPlan {
    enum State: Equatable { case identity, authorization, awaitingConfirmation, common, more, battery, ready, failed }
    private(set) var state: State = .identity
    private(set) var identity: Data?
    private(set) var wallpaperInventory: Data?
    private(set) var common: Data?
    private(set) var more: Data?
    private(set) var error: String?
    private(set) var batteryInfo: BatteryInfo?
    private(set) var batteryReadAt: Date?
    private(set) var batteryError: String?
    let includeBattery: Bool
    private var message: UInt16 = 0x60
    private var pending: (UInt16, UInt16)?
    let serialSuffix: String
    init(serialSuffix: String = DeviceConfig.serialSuffix, includeBattery: Bool = false) { self.serialSuffix = serialSuffix; self.includeBattery = includeBattery }

    func nextRequest() -> Data? {
        guard pending == nil else { return nil }
        let command: UInt16
        let body: Data
        switch state {
        case .identity: command = 0x1009; body = Data()
        case .battery: command = 0x1005; body = Data()
        case .authorization:
            guard let identity = identity else { return nil }
            command = 0x100D; body = identity
        case .common, .more:
            guard let identity = identity else { return nil }
            command = 0x1014
            body = Data(state == .common ? [0,0x10,0,0] : [0x12,0x10,0,0]) + identity
        default: return nil
        }
        message &+= 1; pending = (command, message)
        let payload = Data([UInt8(message & 255),UInt8(message >> 8)]) + body
        return Data([0xFE,0xEF,1,UInt8(command & 255),UInt8(command >> 8),0,0,UInt8(payload.count),0]) + payload
    }
    func consume(_ frame: Frame) {
        guard frame.sequence >> 14 == 0, let pending = pending, frame.command == pending.0, frame.payload.count >= 3,
              UInt16(frame.payload[0]) | UInt16(frame.payload[1]) << 8 == pending.1 else { return }
        self.pending = nil
        guard frame.payload[2] == 0 else {
            if state == .battery { batteryError = "电池查询被拒绝"; state = .ready }
            else { fail("设备拒绝只读请求") }; return
        }
        let body = Data(frame.payload.dropFirst(3))
        switch state {
        case .identity:
            guard body.count >= 34, body[0] == 1 else { fail("身份回复格式无效"); return }
            let raw = Data(body[1..<33])
            let serial = String(decoding: raw.dropFirst(16).prefix(while: { $0 != 0 }), as: UTF8.self)
            guard serial.hasSuffix(serialSuffix) else { fail("设备身份不匹配"); return }
            identity = raw; wallpaperInventory = body; state = .authorization
        case .authorization:
            guard body.count == 33, body.prefix(32) == identity else { fail("授权回复身份不匹配"); return }
            if body[32] == 0 { state = .common }
            else if body[32] == 1 { state = .awaitingConfirmation }
            else { fail("未知授权状态") }
        case .common, .more:
            guard let identity = identity, let values = try? settingsResponse(body, identity: identity, group: state == .common ? 0x1000 : 0x1012) else {
                fail("参数回复格式或身份不匹配"); return
            }
            if state == .common { common = values; state = .more }
            else { more = values; state = includeBattery ? .battery : .ready }
        case .battery:
            batteryInfo = identity.flatMap { BatteryInfo.decode(body,identity:$0) }
            if batteryInfo == nil { batteryError = "电池回复格式无效" }
            else { batteryReadAt = Date() }
            state = .ready
        default: break
        }
    }
    // Only request a fresh authorization query after the user actually confirms.
    func confirmationProvided() { if state == .awaitingConfirmation { state = .authorization } }
    func timeout() {
        guard pending != nil else { return }; pending = nil
        if state == .battery { batteryError = "电池读取超时"; state = .ready }
        else { fail("只读请求超时；未自动重试") }
    }
    private func fail(_ value: String) { error = value; state = .failed }
}
