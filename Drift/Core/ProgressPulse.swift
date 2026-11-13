import Foundation

// Progress observation: how a long operation tells the operator it is alive.
//
// StageTimer exists because the alternative — logging every callback — is
// unreadable, and because "it takes forever" / "it looks hung" are the two
// reports that are impossible to act on without numbers.  It logs through
// `AppLog` rather than the engine so it can be used from anywhere.
// (Heartbeat / PercentThrottle / BackupTrace were removed in the 2026-11
// cleanup: nothing referenced them any more.)

/// Wall-clock cost of one stage, reported in the app log.
///
/// Added because "it takes forever" is unactionable: the run has several
/// multi-second-or-multi-minute stages (tunnel probe, minimuxer readiness, each
/// backup attempt, the restore itself) and without per-stage numbers there is no
/// way to tell a slow transfer from a stage that is merely sleeping.
///
/// `done()` is idempotent-ish by convention: call it exactly once per stage.
struct StageTimer {
    private let label: String
    private let start = Date()

    init(_ label: String) { self.label = label }

    func done(_ extra: String = "") {
        let secs = Date().timeIntervalSince(start)
        AppLog.write("⏱ \(label): \(String(format: "%.1f", secs))s"
            + (extra.isEmpty ? "" : " — \(extra)"))
    }
}


/// Coalesces a fast progress stream before it reaches `@Published`
/// state (cleanup round, 2026-11-13).
///
/// The engine's progress callback fires per descriptor and the
/// download delegate per network chunk; each used to hop to the main
/// actor and set a published value, and the session is observed by
/// every tab — hundreds of full-tree invalidations for a number the
/// eye reads at most ten times a second. Offers land here instead:
/// the first value after a quiet interval publishes at once, repeats
/// of the last value are dropped, and anything in between is held
/// and flushed once the interval lapses, newest first — the final
/// value always arrives, just never more often than `interval`.
@MainActor
final class ProgressCoalescer<Value: Equatable> {
    private let interval: TimeInterval
    private let publish: (Value) -> Void
    private var lastPublished: Value?
    private var lastPublishTime = Date.distantPast
    private var pending: Value?
    private var flushTask: Task<Void, Never>?

    init(interval: TimeInterval = 0.1, publish: @escaping (Value) -> Void) {
        self.interval = interval
        self.publish = publish
    }

    func offer(_ value: Value) {
        if value == lastPublished { pending = nil; return }
        let now = Date()
        if now.timeIntervalSince(lastPublishTime) >= interval {
            emit(value)
            return
        }
        pending = value
        guard flushTask == nil else { return }
        let delay = interval - now.timeIntervalSince(lastPublishTime)
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard let self else { return }
            self.flushTask = nil
            if let held = self.pending {
                self.pending = nil
                self.emit(held)
            }
        }
    }

    private func emit(_ value: Value) {
        lastPublished = value
        lastPublishTime = Date()
        publish(value)
    }
}
