import Foundation

// Diagnostic state only. No device commands, pairing claims or ownership mutation.
struct HandoffObservation {
    struct Snapshot: Equatable {
        let classicConnected: Bool
        let appBLEState: String
        let connectionsSuppressed: Bool
    }
    struct Event {
        enum Kind: Equatable { case started, changed, ended(String) }
        let generation: Int
        let kind: Kind
        let elapsed: TimeInterval
        let snapshot: Snapshot
    }
    private(set) var generation = 0
    private(set) var active = false
    private var started: TimeInterval = 0
    private var last: Snapshot?
    let duration: TimeInterval = 180

    mutating func begin(at now: TimeInterval, snapshot: Snapshot) -> [Event] {
        var events = finish(at: now, snapshot: snapshot, reason: "replaced")
        generation += 1; active = true; started = now; last = snapshot
        events.append(Event(generation: generation, kind: .started, elapsed: 0, snapshot: snapshot))
        return events
    }
    mutating func observe(at now: TimeInterval, snapshot: Snapshot, generation expected: Int) -> [Event] {
        guard active, expected == generation else { return [] }
        let elapsed = max(0, now - started)
        if elapsed >= duration { return finish(at: now, snapshot: snapshot, reason: "timeout") }
        guard snapshot != last else { return [] }
        last = snapshot
        return [Event(generation: generation, kind: .changed, elapsed: elapsed, snapshot: snapshot)]
    }
    mutating func finish(at now: TimeInterval, snapshot: Snapshot, reason: String) -> [Event] {
        guard active else { return [] }
        active = false; last = snapshot
        return [Event(generation: generation, kind: .ended(reason), elapsed: max(0, now - started), snapshot: snapshot)]
    }
}
