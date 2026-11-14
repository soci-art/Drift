import Foundation

/// A destination for one already-formatted log line.
///
/// The engine used to log through `DriftEngine.shared.log`, which made every
/// helper that merely wanted to say something — the stage timer, the heartbeat,
/// the stall guard, the wire tailer — depend on the whole engine type.  A narrow
/// sink is what lets those helpers move out of it.
protocol LogSink: AnyObject, Sendable {
    func write(_ line: String)
}

/// `<Documents>/goldennugget.log` — append-only sink, rotated by dropping the older half.
///
/// The on-screen list alone is not enough: it only ever shows the tail and dies
/// with the process, so anything written there (the host-side delegate
/// decisions, the commit accounting, the stall verdict) would be unshareable.
/// A failed run has to be diagnosable from a file.
final class RotatingFileSink: LogSink, @unchecked Sendable {
    /// Byte cap; the sink is rotated by dropping the older half once exceeded.
    /// Raised 2 MB → 10 MB in collection #272 (Grace, 2026-11-13): the log
    /// now records every user operation and the app's running state on top
    /// of the flash engine's lines, and the old cap rotated real evidence
    /// away within days.
    static let defaultLimit: UInt64 = 10 * 1024 * 1024

    private let url: URL
    private let limit: UInt64
    private let lock = NSLock()

    /// Buffered writer state (cleanup round, 2026-11-13). The sink used
    /// to stat, open, seek, write and close the file **per line** — a
    /// flash logs hundreds of lines, each paying four syscalls and a
    /// directory lookup. Lines now gather in `buffer` and land in one
    /// write through a handle that stays open; a flush is forced by
    /// 4 KB of buffer or 100 ms of age, whichever comes first, so a
    /// crash can still only lose the last fraction of a second.
    private var handle: FileHandle?
    private var buffer = Data()
    private var bufferedSince = Date()
    /// The file's size as this sink last knew it; nil = stat on flush.
    private var knownSize: UInt64?

    init(url: URL, limit: UInt64 = RotatingFileSink.defaultLimit) {
        self.url = url
        self.limit = limit
    }

    func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        if buffer.isEmpty { bufferedSince = Date() }
        buffer.append(data)
        if buffer.count >= 4096 || Date().timeIntervalSince(bufferedSince) >= 0.1 {
            flushLocked()
        }
    }

    /// Write out whatever is buffered. Caller holds `lock`.
    private func flushLocked() {
        guard !buffer.isEmpty else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // A held handle would point at the unlinked old file; drop
            // it so the next flush reopens the path that exists.
            try? handle?.close()
            handle = nil
            try? buffer.write(to: url)
            knownSize = UInt64(buffer.count)
            buffer.removeAll()
            return
        }
        // Resync against the file on disk (#323): the cache clearer
        // truncates this file through its own handle while this sink
        // keeps writing through the one it holds. Without the check,
        // the next flush landed at the pre-truncation offset and left
        // a NUL hole where the cleared lines had been, and the lines
        // written after the clear sat behind kilobytes of zeros. One
        // stat per (already batched) flush keeps the handle and the
        // remembered size honest.
        let actualSize = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)
            .map { $0.uint64Value } ?? 0
        if knownSize == nil {
            knownSize = actualSize
        } else if knownSize != actualSize {
            try? handle?.close()
            handle = nil
            knownSize = actualSize
        }
        if let size = knownSize, size > limit, let existing = try? Data(contentsOf: url) {
            // Keep the newer half — a long run logs continuously and the tail is
            // the part that matters.
            try? handle?.close()
            handle = nil
            try? existing.suffix(Int(limit / 2)).write(to: url)
            knownSize = limit / 2
        }
        if handle == nil {
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        guard let handle else { buffer.removeAll(); return }
        try? handle.write(contentsOf: buffer)
        knownSize = (knownSize ?? 0) + UInt64(buffer.count)
        buffer.removeAll()
    }

    /// Push the buffered lines out now — readers of the file (the
    /// diagnostics bundle, the share labels) flush first so they never
    /// miss the tail still sitting in the buffer.
    func flush() {
        lock.lock()
        flushLocked()
        lock.unlock()
    }

    /// Current size on disk, for the share-sheet labels.
    func size() -> UInt64 {
        flush()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}

/// Keeps the whole run in memory for the UI list and the diagnostics tail.
///
/// Unbounded on purpose: the engine is the producer and a run is bounded by
/// human patience, while the VIEW keeps its own 600-line window for rendering.
/// Capping here instead would silently truncate the diagnostics tail.
final class MemoryLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var snapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return lines.count
    }

    func tail(_ n: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.suffix(n).joined(separator: "\n")
    }

    func reset() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }

    func write(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }
}

/// Process-wide log fan-out: one `log()` call, N sinks, in order.
///
/// The sinks are installed by this type itself rather than by an owner, because
/// logging is the one dependency every other layer has — a helper that logs
/// before the engine exists must still land in `goldennugget.log`.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    let memory = MemoryLogSink()
    let file = RotatingFileSink(url: AppPaths.appLog)

    private let lock = NSLock()
    private var extraSinks: [LogSink] = []
    /// Only ever invoked on the main queue, which is what makes storing a
    /// non-`@Sendable` closure sound here — the class is `@unchecked Sendable`
    /// and the handler never crosses a thread boundary.
    private var uiHandler: ((String) -> Void)?

    private init() {}

    /// Route log lines to the UI list.  Set by the view; delivered on the main
    /// queue because the list is the only main-thread consumer.
    func setUIHandler(_ handler: ((String) -> Void)?) {
        lock.lock()
        uiHandler = handler
        lock.unlock()
    }

    /// Additional sinks (tests, a future in-app exporter).
    func add(_ sink: LogSink) {
        lock.lock()
        extraSinks.append(sink)
        lock.unlock()
    }

    /// Lines waiting for the UI handler, and whether a delivery is
    /// already scheduled (cleanup round, 2026-11-13). The handler used
    /// to get one main-queue hop **per line**; a burst now costs one
    /// hop per 50 ms batch, lines still in order, none dropped.
    private var uiPending: [String] = []
    private var uiDeliveryScheduled = false

    /// Flush the file sink — for readers about to open the log file.
    func flushFile() { file.flush() }

    func log(_ line: String) {
        // Console first: if a sink below throws or a lock is held by a wedged
        // thread, the line still reaches the device console.
        print(line)
        lock.lock()
        memory.write(line)
        file.write(line)
        for sink in extraSinks { sink.write(line) }
        guard uiHandler != nil else { lock.unlock(); return }
        uiPending.append(line)
        let needsSchedule = !uiDeliveryScheduled
        uiDeliveryScheduled = true
        lock.unlock()
        guard needsSchedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let batch = self.uiPending
            self.uiPending.removeAll()
            self.uiDeliveryScheduled = false
            let current = self.uiHandler
            self.lock.unlock()
            guard let current else { return }
            for pendingLine in batch { current(pendingLine) }
        }
    }
}

extension AppLog {
    /// Convenience for the many call sites that only want to emit a line.
    static func write(_ line: String) { shared.log(line) }
}

/// Collection #272 (Grace, 2026-11-13): the log is the whole app's
/// memory, not just the flash engine's. Her rule, verbatim in spirit:
/// collect everything that could later explain a stall or a fault —
/// every user operation, the running state around it, and all three
/// levels (information / warning / error), with timing marks on the
/// operations that can be slow so the slow step is visible by name.
/// These helpers are the one vocabulary for that: `op` for something
/// the user did, the levelled trio for state, `timing` for elapsed
/// marks. Lines land in the same file and memory sinks as everything
/// else, so the Settings log upload carries them all, and a record's
/// export carries its own run's segment (the slice is cut from the
/// same stream when the record is written).
extension AppLog {
    /// A user operation: importing, deleting, repairing, switching a
    /// setting, opening a page — the deliberate actions.
    static func op(_ message: String) { shared.log("[操作] \(message)") }

    /// Running state worth knowing when reading a failure later.
    static func info(_ message: String) { shared.log("[信息] \(message)") }

    /// Something degraded but survivable (a fetch that fell back, a
    /// premise that is missing).
    static func warn(_ message: String) { shared.log("[警告] \(message)") }

    /// An operation failed. Named `failure` because `Error` is taken
    /// by the standard library and `error` reads as a value.
    static func failure(_ message: String) { shared.log("[错误] \(message)") }

    /// An elapsed-time mark for a step that can be slow, so a stall
    /// report names the step instead of just being long.
    static func timing(_ label: String, since start: Date) {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        shared.log("[耗时] \(label)：\(ms) ms")
    }
}

/// Old releases wrote complete pairing dictionaries into diagnostic files.
/// Remove only logs containing those secret field dumps before enabling the
/// append-only Rust sink, so an update cannot keep exporting previously leaked
/// credentials. Pairing records themselves are never touched.
///
/// **Nothing here throws, and nothing here may refuse.** The caller answered a
/// thrown error by leaving the Rust sink off for the rest of the session, so one
/// unreadable file was enough to silence the only protocol-level evidence this
/// app has — and it did exactly that. An 18.7 GB `minimuxer.log` could not be
/// loaded into memory, `enableRustFileLogging()` returned -1 on every launch
/// after it, and the 18.7 GB it occupied stayed on the volume the backup is
/// written to. That volume then had 74 GB free where the device wanted more, so
/// every backup returned "0 of 0 offered" with no Rust log to say why.
///
/// These files are diagnostic output the app owns and can afford to lose. When
/// one cannot be inspected, deleting it answers the secrets question *and* the
/// space question at once; keeping it does neither.
enum PairingLogPrivacy {
    /// Above this, a diagnostic file is a liability rather than evidence.
    ///
    /// The Rust sink caps itself at 64 MB per generation and keeps one
    /// generation (`minimuxer.log.1`), so a healthy pair is at most 128 MB and
    /// survives this pass untouched — the previous run's tail is still there to
    /// read after a relaunch. Anything above it came from a build without that
    /// cap; the file this exists for was 18.7 GB.
    static let maxBytes: UInt64 = 128 << 20

    /// What was removed or replaced, so the engine can say so in one line.
    struct Reclaim: Sendable, Equatable {
        var files: [String] = []
        var bytes: UInt64 = 0

        var isEmpty: Bool { files.isEmpty }

        var summary: String {
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return "\(files.joined(separator: ", ")) (\(size))"
        }
    }

    /// Field names that only ever appeared in the credential dumps of older
    /// builds. Quoted on purpose: today's builds log the same key *names* as a
    /// bare list ("keys: alt_irk, identifier, …") and that line must not wipe
    /// the log on every launch.
    private static let secretFields = ["\"private_key\"", "\"alt_irk\""]
        .map { Data($0.utf8) }

    private enum Verdict {
        case clean
        case secretDump
        case unreadable
    }

    /// Sanitise each file, deleting what cannot be inspected or is oversized.
    ///
    /// - Parameter limit: files above this are removed without being read. The
    ///   scan is the expensive part and a huge file is not evidence any more,
    ///   so the size check has to come first — that ordering is the whole fix.
    @discardableResult
    static func removeLegacyDumps(at urls: [URL], limit: UInt64 = maxBytes) -> Reclaim {
        let fm = FileManager.default
        var reclaim = Reclaim()

        for url in urls {
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
                  size.uint64Value > 0 else { continue }

            if size.uint64Value > limit {
                if (try? fm.removeItem(at: url)) != nil {
                    reclaim.files.append(url.lastPathComponent)
                    reclaim.bytes += size.uint64Value
                }
                continue
            }

            switch scan(url) {
            case .clean:
                continue
            case .secretDump:
                // Replaced rather than deleted: the app log keeps appending, and
                // the notice is what a reader of that file needs to know.
                let notice = Data("Old diagnostic log removed because it contained pairing secrets.\n".utf8)
                if (try? notice.write(to: url, options: .atomic)) != nil {
                    reclaim.files.append(url.lastPathComponent)
                    reclaim.bytes += size.uint64Value - UInt64(min(notice.count, Int(size.uint64Value)))
                }
            case .unreadable:
                // Nothing here is worth keeping, and the bytes are exactly why it
                // could not be inspected — so they go, rather than disabling the
                // sink that would have explained the next failure.
                if (try? fm.removeItem(at: url)) != nil {
                    reclaim.files.append(url.lastPathComponent)
                    reclaim.bytes += size.uint64Value
                }
            }
        }
        return reclaim
    }

    /// Stream the file in 1 MB chunks, carrying the overlap a pattern could
    /// straddle. Memory stays bounded no matter how long the file is, which is
    /// the property `Data(contentsOf:)` did not have.
    ///
    /// The search is `Data.range(of:)`, not a byte-by-byte walk, and that is a
    /// launch-survival fix rather than a tidying: this pass runs from the first
    /// view body, on the main thread, before the shell is allowed to appear. A
    /// naive walk costs ~1 µs per byte in a Debug build — the 2026-10-29 build
    /// died on every launch with a scene-create watchdog kill after 19.96 s,
    /// its main thread inside `Array.contains(sequence:)` over a 54 MB
    /// `minimuxer.log` (58 s measured at -Onone by
    /// `scripts/check-log-privacy-scan.py`). The Rust sink is capped at 64 MB
    /// per generation with one generation kept, so this has to stay fast at
    /// 128 MB; Foundation's search does that in a fraction of a second.
    private static func scan(_ url: URL) -> Verdict {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? handle.close() }

        let overlap = (secretFields.map(\.count).max() ?? 1) - 1
        var carry = Data()
        while true {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: 1 << 20), !read.isEmpty else {
                    return .clean
                }
                chunk = read
            } catch {
                return .unreadable
            }
            var buffer = carry
            buffer.append(chunk)
            if secretFields.contains(where: { buffer.range(of: $0) != nil }) {
                return .secretDump
            }
            carry = buffer.suffix(overlap)
        }
    }
}
