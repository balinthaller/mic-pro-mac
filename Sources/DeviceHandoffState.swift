import Foundation

struct DeviceHandoffState {
    enum Phase: String { case mac, releasing, released, unconfirmed }
    private(set) var phase: Phase
    private(set) var suppressAppConnections: Bool
    init(suppressed: Bool = false) {
        suppressAppConnections = suppressed
        phase = suppressed ? .unconfirmed : .mac
    }
    mutating func beginRelease(busy: Bool) -> Bool {
        guard !busy else { return false }
        suppressAppConnections = true; phase = .releasing; return true
    }
    mutating func observeRelease(classicConnected: Bool, controlConnected: Bool, timedOut: Bool) -> Bool {
        guard phase == .releasing else { return false }
        if !classicConnected && !controlConnected { phase = .released; return true }
        if timedOut { phase = .unconfirmed; return true }
        return false
    }
    mutating func returnToMac(busy: Bool) -> Bool {
        guard !busy else { return false }
        suppressAppConnections = false; phase = .mac; return true
    }
}
