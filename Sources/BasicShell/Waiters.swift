import Foundation

/// Tasks waiting for something to happen, woken by the happening itself: no
/// looking again and again, and no guess at how long it takes. `atMost` is
/// the watchdog for the event that never comes, not a wait: when the event
/// comes first, nothing is waited for.
final class Waiters {
    private var parked: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait(atMost seconds: Double) async {
        let id = UUID()
        await withCheckedContinuation { continuation in
            parked[id] = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) { [weak self] in
                MainActor.assumeIsolated { self?.parked.removeValue(forKey: id)?.resume() }
            }
        }
    }

    /// Everything waiting goes on.
    func wake() {
        let all = parked
        parked = [:]
        for continuation in all.values { continuation.resume() }
    }
}
