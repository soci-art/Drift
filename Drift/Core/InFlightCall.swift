import Foundation

/// Separates a user-visible run from its blocking device calls. Cancelling a
/// wait cannot stop Rust; the call keeps running as a zombie. What changed
/// (feedback #21): a zombie no longer bricks the app until restart. Runs are
/// token-owned, and once every call still in flight belongs to an abandoned
/// run, a new run may take over alongside the zombies — loudly logged, never
/// silent — instead of demanding an app restart that Grace's recordings
/// proved was the only way out.
final class InFlightCall: @unchecked Sendable {
    static let shared = InFlightCall()

    /// Ownership of one user-visible run. `endRun` only clears the run whose
    /// token matches, so a walked-away run unwinding late cannot tear down
    /// the run that took over from it.
    struct RunToken: Equatable {
        let id: UInt64
    }

    private let lock = NSLock()
    /// Blocking calls executing right now, across all generations.
    private var depth = 0
    /// Of `depth`, how many belong to abandoned runs (zombies). Returns are
    /// attributed to the live generation first — a zombie is by definition
    /// the call that returns last — so when no run is live, `depth ==
    /// abandonedDepth` means everything still out is a zombie and a new run
    /// may begin.
    private var abandonedDepth = 0
    private var activeToken: RunToken?
    private var nextTokenID: UInt64 = 0
    /// The active run itself was walked away from (its calls are zombies,
    /// its Swift side may not have finished unwinding yet).
    private var activeRunAbandoned = false
    private var abandonedLabel: String?

    enum Failure: Error, LocalizedError {
        case busy
        var errorDescription: String? {
            "上一个设备操作还在运行。请等它完成后再试。"
        }
    }

    private init() {}

    /// Reserve the entire run, including preparation before its first FFI
    /// call. Granted when nothing live owns the device: either no run is
    /// active and every call still in flight is a zombie, or the active run
    /// was itself abandoned and has not finished unwinding.
    func beginRun() throws -> RunToken {
        lock.lock()
        defer { lock.unlock() }
        if let active = activeToken {
            guard activeRunAbandoned else { throw Failure.busy }
            // Takeover of an abandoned run whose wrapper is still unwinding.
            // Its late endRun carries the old token and will be ignored.
            let token = makeTokenLocked()
            activeToken = token
            activeRunAbandoned = false
            AppLog.write("⚠️ 设备操作锁接管：上一轮运行已被放弃但尚未完全退场，"
                + "新运行直接接管（不再要求重启应用）。仍在途的已放弃调用 \(depth) 个。")
            return token
        }
        guard depth == abandonedDepth else { throw Failure.busy }
        let token = makeTokenLocked()
        activeToken = token
        activeRunAbandoned = false
        if depth > 0 {
            AppLog.write("⚠️ 设备操作锁接管：\(depth) 个已放弃的设备调用仍在运行，"
                + "新运行与之并存启动（不再要求重启应用）。")
        }
        return token
    }

    /// Release a run. Only the owning token clears the slot; a stale token
    /// (an abandoned run unwinding after a takeover) is ignored.
    func endRun(_ token: RunToken) {
        lock.lock()
        if activeToken == token {
            activeToken = nil
            activeRunAbandoned = false
        } else if activeToken != nil {
            AppLog.write("设备操作锁：忽略一轮已退场运行的迟到 endRun（当前运行不受影响）。")
        }
        lock.unlock()
    }

    private func makeTokenLocked() -> RunToken {
        nextTokenID += 1
        return RunToken(id: nextTokenID)
    }

    /// A call is about to start running.
    func enter() {
        lock.lock()
        depth += 1
        lock.unlock()
    }

    /// The call really returned (success or failure).
    func leave() {
        lock.lock()
        if depth - abandonedDepth > 0 {
            // A live-generation call returned; zombies are still out.
            depth -= 1
        } else {
            depth = max(0, depth - 1)
            abandonedDepth = max(0, abandonedDepth - 1)
        }
        if depth == 0 {
            // Fully drained — the runtime is clean again and a retry is safe.
            abandonedDepth = 0
            abandonedLabel = nil
        }
        lock.unlock()
    }

    /// The guard walked away from the active run: every call now in flight
    /// becomes zombie generation, and the run itself is marked abandoned so
    /// a successor may take over without an app restart.
    func noteAbandoned(label: String) {
        lock.lock()
        abandonedLabel = label
        abandonedDepth = depth
        if activeToken != nil {
            activeRunAbandoned = true
        }
        lock.unlock()
    }

    /// True while a Rust call is still executing, abandoned or not.
    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return depth > 0
    }

    /// Whether a user-visible run owns the device right now — the token
    /// `beginRun` minted. Work that must not start mid-run (the background
    /// media copy) reads this instead of trying to begin a run of its own.
    var isRunActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeToken != nil
    }

    /// Whether a live (not walked-away-from) run owns the device. A run
    /// whose calls were abandoned no longer blocks a successor at the
    /// session layer either — `beginRun` makes the final call.
    var hasLiveRun: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeToken != nil && !activeRunAbandoned
    }

    var abandonedDescription: String {
        lock.lock()
        defer { lock.unlock() }
        return abandonedLabel ?? "the device operation"
    }

}
