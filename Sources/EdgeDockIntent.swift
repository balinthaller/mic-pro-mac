import Foundation

/// Hover only presents UI. Device commands are never emitted by this state machine.
struct EdgeDockIntent {
    private(set) var revealed=false
    private var entered: Date?, left: Date?
    mutating func tick(inside: Bool, now: Date) -> Bool {
        if inside {
            left=nil
            if entered == nil {entered=now}
            if !revealed,now.timeIntervalSince(entered!) >= 0.14 {revealed=true}
        } else {
            entered=nil
            if left == nil {left=now}
            if revealed,now.timeIntervalSince(left!) >= 0.32 {revealed=false}
        }
        return revealed
    }
    mutating func reveal(){revealed=true;entered=nil;left=nil}
    mutating func reset(){self=EdgeDockIntent()}
}
