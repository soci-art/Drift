import Foundation
import SwiftUI

/// The run log, as an observable store rather than as page state.
///
/// It used to be `@State private var logs: [String]` **on `GoldenNuggetView`**,
/// with `AppLog`'s UI handler appending to it once per line.  One log line
/// therefore invalidated the whole page: `body` re-evaluated, and with it every
/// computed value inside it — including `mediaDetail`, which read *and JSON-
/// decoded* the media manifest from disk, and `enabledDaemonCount`, which filters
/// `DaemonGroups.all` through `TweakCatalog.byID`.  A run logs hundreds of lines
/// (progress steps, wire census, delegate decisions, retries), so the page
/// re-rendered hundreds of times and touched the disk on each one.  That, not the
/// log drawing itself, is what made a run feel heavy — `TweaksView` had the same
/// shape with its own `tail`.
///
/// The split moves the invalidation to the one place that draws it: a
/// line now re-evaluates only the observer of this store (today the
/// Settings log section; the on-page log card was retired in #289) and
/// nothing else, because no other view reads this store. Record
/// exports slice their run's lines from here too.
///
/// **Appends are coalesced, not queued per line.**  `append` may be called from
/// any thread (the engine's callback arrives on the main queue today, but the
/// store does not depend on that); the first append schedules **one** main-queue
/// flush and every append until that flush lands is merged into it.  A burst —
/// a backup's delegate chatter, a stalled-transfer dump — costs one main-thread
/// hop instead of one per line, and nothing is dropped.
final class RunLog: ObservableObject {
    static let shared = RunLog()

    /// What the card renders: the last `windowSize` lines, main thread only.
    @Published private(set) var lines: [String] = []

    /// The identity of `lines[0]`, so the log view can key its rows by something
    /// stable.  Keying by array offset (the obvious thing) makes every row's
    /// identity shift by one each time the window slides, and SwiftUI then
    /// re-creates all 600 rows instead of reusing them — once per appended line,
    /// which is exactly the tail end of a long run.
    @Published private(set) var firstLineId = 0

    /// Lines waiting for the next flush.  Deliberately *not* `@Published`: a
    /// write to it must not invalidate a view.  Guarded by `lock`.
    private var pending: [String] = []
    /// Whether a flush is already scheduled, so a burst schedules exactly one.
    private var flushScheduled = false
    private let lock = NSLock()

    /// The same window the old `if logs.count > 600 { removeFirst }` kept.
    private let windowSize = 600

    // MARK: - Record snapshots

    /// Head/tail retention for history-record log slices. The UI window
    /// above keeps only the last 600 lines, which silently drops a long
    /// run's beginning — probe steps included — from its record slice.
    /// Records therefore snapshot from this buffer instead: the first
    /// `recordHeadSize` lines verbatim, the last `recordTailSize`, and one
    /// omission marker between them when the middle had to be dropped.
    /// Mutated only in `flush` and `clear`, both main-thread.
    private let recordHeadSize = 300
    private let recordTailSize = 300
    private var recordHead: [String] = []
    private var recordTail: [String] = []
    private var recordTotal = 0

    private init() {}

    /// The run's lines for a history record: head + tail, never tail-only.
    func recordSnapshot() -> String {
        if recordTotal <= recordHeadSize {
            return recordHead.joined(separator: "\n")
        }
        if recordTotal <= recordHeadSize + recordTailSize {
            let overlap = recordHeadSize + recordTailSize - recordTotal
            return (recordHead + Array(recordTail.dropFirst(overlap)))
                .joined(separator: "\n")
        }
        let omitted = recordTotal - recordHeadSize - recordTailSize
        return (recordHead + ["……（中间省略 \(omitted) 行）……"] + recordTail)
            .joined(separator: "\n")
    }

    private func noteForRecord(_ batch: [String]) {
        recordTotal += batch.count
        for line in batch {
            if recordHead.count < recordHeadSize { recordHead.append(line) }
            recordTail.append(line)
            if recordTail.count > recordTailSize { recordTail.removeFirst() }
        }
    }

    /// Append a line.  Safe from any thread; never invalidates a view directly.
    func append(_ line: String) {
        lock.lock()
        pending.append(line)
        let needsFlush = !flushScheduled
        flushScheduled = needsFlush
        lock.unlock()
        guard needsFlush else { return }
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    /// Drop everything, for the start of a run.  Main thread.
    func clear() {
        lock.lock()
        pending.removeAll()
        flushScheduled = false
        lock.unlock()
        recordHead.removeAll()
        recordTail.removeAll()
        recordTotal = 0
        if !lines.isEmpty { lines.removeAll() }
    }

    /// Publish everything buffered so far, trimmed to the window.  Main thread.
    private func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll()
        flushScheduled = false
        lock.unlock()
        guard !batch.isEmpty else { return }
        noteForRecord(batch)
        lines.append(contentsOf: batch)
        if lines.count > windowSize {
            let dropped = lines.count - windowSize
            lines.removeFirst(dropped)
            firstLineId += dropped
        }
    }
}

