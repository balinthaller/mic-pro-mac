import Foundation

/// One-shot mode transaction. Transport and UI are implemented separately; no automatic retry.
/// readyToDisconnect is a protected protocol checkpoint, NOT proof of actual mode.
final class PortableMeetingModePlan {
    enum State: Equatable {
        case readingBaseline, baselineAttributes, baselineReady, requestingMode, settling
        case gateCommon, gateMore, gateAttributes
        case afterCommon, afterMore, afterAttributes, readyToDisconnect, failed
    }
    private(set) var state: State = .readingBaseline
    private(set) var error: String?
    private(set) var baselineCommon: Data?
    private(set) var baselineMore: Data?
    private(set) var baselineAttributes: Data?
    private(set) var gateCommon: Data?
    private(set) var gateMore: Data?
    private(set) var gateAttributes: Data?
    private(set) var afterCommon: Data?
    private(set) var afterMore: Data?
    private(set) var afterAttributes: Data?
    private(set) var modeRequestWritten = false
    private(set) var modeReplyReceived = false
    private(set) var modeMetadata: Data?
    private(set) var responses = 0
    var identity: Data? { readPlan.identity }
    var awaitingConfirmation: Bool { readPlan.state == .awaitingConfirmation }
    var modeWritten: Bool { modeRequestWritten }
    private let readPlan: AppControlReadPlan
    private var message: UInt16 = 0x500
    private var pending: (command: UInt16, message: UInt16)?
    private var modeReplyTime: TimeInterval?
    init(serialSuffix: String = DeviceConfig.serialSuffix) { readPlan = AppControlReadPlan(serialSuffix: serialSuffix) }

    func confirmationProvided() { readPlan.confirmationProvided() }
    /// Caller must hold the device transaction lock and have an explicit user mode-switch request.
    @discardableResult func authorizeModeRequest() -> Bool {
        guard state == .baselineReady, !modeRequestWritten else { return false }
        state = .gateCommon; return true
    }
    /// Caller invokes only on the original still-open channel after the settle interval.
    @discardableResult func settle(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard state == .settling, let time = modeReplyTime, now - time >= 0.75 else { return false }
        state = .afterCommon; return true
    }
    @discardableResult func advanceAfterSettle() -> Bool { settle() }
    func nextRequest() -> Data? {
        if state == .readingBaseline { return readPlan.nextRequest() }
        guard pending == nil, let identity = identity else { return nil }
        let command: UInt16; let body: Data
        switch state {
        case .baselineAttributes, .gateAttributes, .afterAttributes: command = 0x1014; body = Data([0x17,0x10,0,0]) + identity
        case .gateCommon, .afterCommon: command = 0x1014; body = Data([0,0x10,0,0]) + identity
        case .gateMore, .afterMore: command = 0x1014; body = Data([0x12,0x10,0,0]) + identity
        case .requestingMode:
            guard !modeRequestWritten else { return nil }
            command = 0x1020; body = Data(); modeRequestWritten = true
        default: return nil
        }
        message &+= 1; pending = (command, message)
        let payload = Data([UInt8(message & 255), UInt8(message >> 8)]) + body
        return Data([0xFE,0xEF,1,UInt8(command & 255),UInt8(command >> 8),0,0,UInt8(payload.count),0]) + payload
    }
    func consume(_ frame: Frame, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if state == .readingBaseline {
            let previous = readPlan.state
            readPlan.consume(frame)
            if readPlan.state != previous { responses += 1 }
            if readPlan.state == .failed { fail(readPlan.error ?? "Baseline read failed") }
            if readPlan.state == .ready {
                baselineCommon = readPlan.common; baselineMore = readPlan.more
                guard baselineCommon?[0] == 0 else { fail("正在内录，请先停止内录"); return }
                guard baselineMore?[2] == 0, baselineMore?[7] == 0, baselineMore?[8] == 0 else { fail("循环/自动录音或童锁已开启，请先在设备上关闭"); return }
                state = .baselineAttributes
            }
            return
        }
        guard frame.sequence >> 14 == 0, let request = pending,
              frame.command == request.command, frame.payload.count >= 3,
              UInt16(frame.payload[0]) | UInt16(frame.payload[1]) << 8 == request.message else { return }
        pending = nil
        responses += 1
        guard frame.payload[2] == 0, let identity = identity else { fail("设备拒绝模式请求"); return }
        let body = Data(frame.payload.dropFirst(3))
        switch state {
        case .baselineAttributes, .gateAttributes, .afterAttributes:
            guard body.count == 55, body.prefix(32) == identity,
                  body[32] == 0x17, body[33] == 0x10, body.suffix(3) == Data([0,0,0]) else {
                fail("录音属性格式或设备身份不匹配"); return
            }
            let values = Data(body[34..<52])
            guard values[2] == 0, values[3] == 0, values[5] == 0, values[6] == 0 else {
                fail("内录/暂停/循环/自动清理设置不满足安全切换条件"); return
            }
            if state == .baselineAttributes { baselineAttributes = values; state = .baselineReady }
            else {
                let isGate = state == .gateAttributes
                if isGate { gateAttributes = values } else { afterAttributes = values }
                guard let before = baselineAttributes,
                      [2,3,4].allSatisfy({ before[$0] == values[$0] }) else {
                    fail("保护设置发生变化，已停止切换"); return
                }
                state = isGate ? .requestingMode : .readyToDisconnect
            }
        case .requestingMode:
            guard body.count == 49, body[48] == 0,
                  body.prefix(16) == identity.prefix(16), body[32..<48] == identity[16..<32] else {
                fail("模式应答格式或设备身份不匹配，状态待确认"); return
            }
            modeMetadata = body; modeReplyReceived = true; modeReplyTime = now; state = .settling
        case .gateCommon, .gateMore, .afterCommon, .afterMore:
            let isCommon = state == .gateCommon || state == .afterCommon
            let isGate = state == .gateCommon || state == .gateMore
            let group: UInt16 = isCommon ? 0x1000 : 0x1012
            guard let values = try? settingsResponse(body, identity: identity, group: group) else {
                fail("设置读回格式或身份不匹配，状态待确认"); return
            }
            if isCommon {
                if isGate { gateCommon = values } else { afterCommon = values }
                guard values[0] == 0 else { fail("设备已开始内录，已停止切换"); return }
                state = isGate ? .gateMore : .afterMore
            } else {
                if isGate { gateMore = values } else { afterMore = values }
                guard values[2] == 0, values[7] == 0, values[8] == 0, let before = baselineMore,
                      [8,9,10].allSatisfy({ before[$0] == values[$0] }) else {
                    fail("保护设置发生变化，或循环/自动录音/童锁已开启"); return
                }
                state = isGate ? .gateAttributes : .afterAttributes
            }
        default: break
        }
    }
    func timeout() {
        if state == .readingBaseline {
            readPlan.timeout()
            if readPlan.state == .failed { fail(readPlan.error ?? "Baseline timeout") }
        } else if pending != nil { pending = nil; fail("请求超时，未自动重试") }
    }
    private func fail(_ message: String) { error = message; state = .failed; pending = nil }
}
