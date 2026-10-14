import Foundation

enum DockMicAction: Equatable {
    case showDetails,connect,busy,needsPairing
    static func resolve(connected: Bool,busy: Bool,paired: Bool) -> Self {
        if connected {return .showDetails}
        if busy {return .busy}
        return paired ? .connect : .needsPairing
    }
}
