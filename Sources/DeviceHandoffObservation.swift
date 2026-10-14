import Foundation
import ObjectiveC

private var handoffObserverKey: UInt8 = 0
private final class HandoffObserverRuntime: NSObject {
    var model = HandoffObservation()
    var timer: Timer?
    deinit { timer?.invalidate() }
}

extension Probe {
    private var handoffObserver: HandoffObserverRuntime {
        if let value = objc_getAssociatedObject(self, &handoffObserverKey) as? HandoffObserverRuntime { return value }
        let value = HandoffObserverRuntime()
        objc_setAssociatedObject(self, &handoffObserverKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return value
    }
    private var handoffObservationSnapshot: HandoffObservation.Snapshot {
        HandoffObservation.Snapshot(classicConnected: SystemBattery.device()?.isConnected() == true,
                                    appBLEState: peripheral.map { String($0.state.rawValue) } ?? "none",
                                    connectionsSuppressed: handoffSuppressed)
    }
    private func logHandoffObservation(_ events: [HandoffObservation.Event]) {
        for event in events {
            let phase: String
            switch event.kind {
            case .started: phase = "started"
            case .changed: phase = "changed"
            case .ended(let reason): phase = "ended:" + reason
            }
            log(String(format: "交接只读观察 generation=%d %@ +%.1fs classic=%@ app_ble=%@ suppressed=%@ phone=unknown",
                       event.generation, phase, event.elapsed, String(event.snapshot.classicConnected),
                       event.snapshot.appBLEState, String(event.snapshot.connectionsSuppressed)))
        }
    }
    func startHandoffObservation() {
        let observer = handoffObserver
        observer.timer?.invalidate(); observer.timer = nil
        logHandoffObservation(observer.model.begin(at: ProcessInfo.processInfo.systemUptime, snapshot: handoffObservationSnapshot))
        let generation = observer.model.generation
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self, weak observer] timer in
            guard let self = self, let observer = observer else { timer.invalidate(); return }
            self.logHandoffObservation(observer.model.observe(at: ProcessInfo.processInfo.systemUptime,
                                                             snapshot: self.handoffObservationSnapshot, generation: generation))
            if !observer.model.active { timer.invalidate(); observer.timer = nil }
        }
        observer.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stopHandoffObservation(source: String) {
        let observer = handoffObserver
        logHandoffObservation(observer.model.finish(at: ProcessInfo.processInfo.systemUptime,
                                                    snapshot: handoffObservationSnapshot, reason: "return-to-mac:" + source))
        observer.timer?.invalidate(); observer.timer = nil
    }
}
