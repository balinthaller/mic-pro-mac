import Foundation

/// Guarded feedback transaction with full-group conflict checks and restoration.
final class AppControlPulsePlan {
    enum Kind { case noise, led }
    let kind: Kind
    let group: UInt16
    let ledHold: TimeInterval
    private(set) var resumeAt: Date?
    enum State: Equatable { case guardRead, change, verifyChange, restoreGuard, restore, verifyRestore, ready, failed }
    private(set) var state: State = .guardRead
    private(set) var error: String?
    private(set) var restored = false
    private(set) var wroteChange = false
    let identity: Data
    let original: Data
    let proposed: Data
    private var message: UInt16 = 0x80
    private var pending: (UInt16, UInt16)?
    private var changeACK = false
    private var restoreACK = false
    init(identity: Data, original: Data, kind: Kind = .noise, ledHold: TimeInterval = 0.4) throws {
        guard identity.count == 32, ledHold.isFinite, (0.2...3).contains(ledHold) else { throw ProtocolError.invalidSettings }
        self.identity = identity; self.original = original; self.kind = kind; self.ledHold = ledHold
        group = kind == .noise ? 0x1000 : 0x1012
        if kind == .noise { proposed = try noiseFeedbackSnapshot(original) }
        else { proposed = try moreToggleSnapshot(original, field: .led, enabled: original.count == 12 && original[10] == 0) }
    }
    func nextRequest(now: Date = Date()) -> Data? {
        if let resumeAt = resumeAt, state == .restoreGuard, now < resumeAt { return nil }
        guard pending == nil, state != .ready, state != .failed else { return nil }
        let writing = state == .change || state == .restore
        let command: UInt16 = writing ? 0x1015 : 0x1014
        let body: Data
        if writing {
            guard let encoded = try? (kind == .noise ? commonSettingsWriteBody(identity: identity, values: state == .change ? proposed : original) : moreSettingsWriteBody(identity: identity, values: state == .change ? proposed : original)) else { fail("写入格式校验失败"); return nil }
            body = encoded
            if state == .change { wroteChange = true }
        } else { body = Data([UInt8(group & 255), UInt8(group >> 8),0,0]) + identity }
        message &+= 1; pending = (command, message)
        let payload = Data([UInt8(message & 255),UInt8(message >> 8)]) + body
        return Data([0xFE,0xEF,1,UInt8(command & 255),UInt8(command >> 8),0,0,UInt8(payload.count),0]) + payload
    }
    func consume(_ frame: Frame, now: Date = Date()) {
        guard frame.sequence >> 14 == 0, let pending = pending, frame.command == pending.0, frame.payload.count >= 3,
              UInt16(frame.payload[0]) | UInt16(frame.payload[1]) << 8 == pending.1 else { return }
        self.pending = nil
        let body = Data(frame.payload.dropFirst(3))
        if state == .change || state == .restore {
            let acknowledged = frame.payload[2] == 0 && body.isEmpty
            if state == .change { changeACK = acknowledged; state = .verifyChange }
            else { restoreACK = acknowledged; state = .verifyRestore }
            return // Even a rejected/ambiguous write must be followed by a fresh read.
        }
        guard frame.payload[2] == 0, let values = try? settingsResponse(body, identity: identity, group: group) else { fail("完整设置读取无效，恢复未确认"); return }
        switch state {
        case .guardRead:
            guard values == original else { fail("设置已被其他操作修改，取消提示"); return }
            state = .change
        case .verifyChange:
            if values == original { restored = true; fail("设置未改变，未确认提示"); return }
            guard values == proposed else { fail("设置与预期不同，避免覆盖外部修改"); return }
            state = .restoreGuard
            if kind == .led { resumeAt = now.addingTimeInterval(ledHold) }
        case .restoreGuard:
            guard values == proposed else { fail("恢复前设置发生变化，停止覆盖"); return }
            state = .restore; resumeAt = nil
        case .verifyRestore:
            guard values == original else { fail("原始设置恢复未确认"); return }
            restored = true
            if changeACK && restoreACK { state = .ready }
            else { fail("原始设置已读回恢复，但写入应答不完整") }
        default: break
        }
    }
    func timeout() {
        guard pending != nil else { return }; pending = nil
        if state == .change { state = .verifyChange }
        else if state == .restore { state = .verifyRestore }
        else { fail("读取超时，未自动重试；恢复状态需检查") }
    }
    private func fail(_ value: String) { error = value; state = .failed }
}
