import Foundation

/// Shared inode/pathleak discovery used by both 本机直刷 and 内核直刷.
///
/// The two write backends validate a candidate differently:
/// - 本机直刷 consumes a sandbox extension, then checks the store.
/// - 内核直刷 checks the store through the already-established kernel R/W path.
///
/// Candidate enumeration and its early-stop/deadline behavior stay identical.
enum PosterBoardContainerLocator {
    static let applicationsRoot = "/private/var/mobile/Containers/Data/Application"
    private static let segmentSize: UInt64 = 200_000

    private static let progressKey = "drift.posterboard.pathleak.progress.v1"
    private static let progressSchema = 2

    /// A cold scan can outlive one locate attempt (timeout, app relaunch,
    /// prewarm). High/low alternation needs two frontiers, an explicit next
    /// direction, and (when the probe's upper bound grows) a separate
    /// high-side tail that is scanned before the old frontiers.
    private struct PathleakProgress: Codable {
        var schema: Int
        var maxInode: UInt64
        var low: UInt64
        var high: UInt64
        var scanned: UInt64
        var segments: Int
        var candidates: Int
        var phaseHigh: Bool
        var tailLow: UInt64?
        var tailHigh: UInt64?
    }

    private static func loadProgress(maxInode: UInt64,
                                     log: (String) -> Void) -> PathleakProgress? {
        guard let data = UserDefaults.standard.data(forKey: progressKey) else { return nil }
        guard var progress = try? JSONDecoder().decode(PathleakProgress.self, from: data) else {
            clearProgress()
            log("[pathleak] 进度损坏，旧进度清零，从头扫")
            return nil
        }
        guard progress.schema == progressSchema else {
            clearProgress()
            log("[pathleak] 扫描算法版本变化（旧 \(progress.schema)，新 \(progressSchema)），旧进度清零")
            return nil
        }
        // Validate against the bound the progress was written for, before
        // replacing it with the new (possibly larger) probe bound.
        guard progress.low >= 1,
              progress.low <= progress.high,
              progress.high <= progress.maxInode,
              progress.scanned <= progress.maxInode,
              progress.segments >= 0,
              progress.candidates >= 0 else {
            clearProgress()
            log("[pathleak] 进度范围不合法，旧进度清零，从头扫")
            return nil
        }
        if maxInode < progress.maxInode {
            clearProgress()
            log("[pathleak] maxInode 变小（旧 \(progress.maxInode)，新 \(maxInode)），旧进度清零，从头扫")
            return nil
        }
        if maxInode > progress.maxInode {
            if progress.tailLow != nil || progress.tailHigh != nil {
                // Growing while a tail is still unfinished would need a
                // second disjoint tail; restart instead of double-counting.
                clearProgress()
                log("[pathleak] maxInode 变大且旧尾部未扫完，旧进度清零，从头扫")
                return nil
            }
            let oldMax = progress.maxInode
            progress.maxInode = maxInode
            progress.tailLow = oldMax + 1
            progress.tailHigh = maxInode
            log("[pathleak] maxInode 变大（旧 \(oldMax)，新 \(maxInode)），先补扫新增高段，再续旧进度")
        }
        if progress.tailLow == nil || progress.tailHigh == nil {
            guard progress.tailLow == nil && progress.tailHigh == nil else {
                clearProgress()
                log("[pathleak] 尾部进度不完整，旧进度清零，从头扫")
                return nil
            }
        } else if let low = progress.tailLow, let high = progress.tailHigh {
            guard low >= 1, low <= high, high <= progress.maxInode,
                  low > progress.high else {
                clearProgress()
                log("[pathleak] 尾部进度范围不合法，旧进度清零，从头扫")
                return nil
            }
        }
        return progress
    }

    private static func saveProgress(maxInode: UInt64, low: UInt64, high: UInt64,
                                     scanned: UInt64, segments: Int, candidates: Int,
                                     phaseHigh: Bool, tailLow: UInt64?, tailHigh: UInt64?) {
        let progress = PathleakProgress(schema: progressSchema, maxInode: maxInode,
                                        low: low, high: high, scanned: scanned,
                                        segments: segments, candidates: candidates,
                                        phaseHigh: phaseHigh, tailLow: tailLow, tailHigh: tailHigh)
        guard let data = try? JSONEncoder().encode(progress) else { return }
        UserDefaults.standard.set(data, forKey: progressKey)
    }

    /// Called when any source finds the container (cached, known, CSStore,
    /// root) so a later scan starts from zero rather than resuming a stale
    /// attempt.
    static func clearProgress() {
        UserDefaults.standard.removeObject(forKey: progressKey)
    }

    struct PathleakResult {
        let foundPath: String?
        let available: Bool
        let timedOut: Bool
        let maxInode: UInt64
        let scannedInodes: UInt64
        let segments: Int
        let candidates: Int
        let enumerationMilliseconds: Double

        var coverage: Double {
            guard maxInode > 0 else { return 0 }
            return min(1.0, Double(scannedInodes) / Double(maxInode))
        }
    }

    private final class SegmentResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String]?

        func store(_ newValue: [String]) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func load() -> [String]? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Enumerate the applications root in contiguous inode ranges. The caller
    /// inspects each segment and returns a path as soon as it identifies the
    /// PosterBoard container. The temporary inode-bound file is always removed.
    static func scanPathleak(
        deadline: Date,
        log: (String) -> Void,
        inspect: ([String], Int) -> String?
    ) -> PathleakResult {
        let limitStarted = DispatchTime.now()
        log("[pathleak] inode 上限探测开始")
        guard let limit = WorseQueryEscape.pathleakScanLimit() else {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - limitStarted.uptimeNanoseconds) / 1_000_000
            log(String(format: "[pathleak] inode 上限探测失败（%.0f ms）：无法建立临时文件", elapsed))
            return PathleakResult(foundPath: nil, available: false, timedOut: false,
                                  maxInode: 0, scannedInodes: 0, segments: 0,
                                  candidates: 0, enumerationMilliseconds: 0)
        }
        defer { limit.cleanup() }
        let limitElapsed = Double(DispatchTime.now().uptimeNanoseconds - limitStarted.uptimeNanoseconds) / 1_000_000
        log(String(format: "[pathleak] inode 上限探测完成：maxInode=%llu（%.0f ms）", limit.maxInode, limitElapsed))

        var scanned: UInt64 = 0
        var segments = 0
        var candidates = 0
        var enumerationMilliseconds: Double = 0

        // Walk both ends of the inode space, alternating a high segment and a
        // low one. App data containers are created over the life of the
        // device, so the target can be anywhere: on a 26.5 field log the
        // 60-second ascending scan stopped at 22.4M of a 29.7M maximum
        // without ever reaching it. New containers sit at the high end; old
        // system ones at the low end. Alternating covers both without
        // guessing which one this device is.
        var scanMax = limit.maxInode
        var low: UInt64 = 1
        var high: UInt64 = scanMax
        var phaseHigh = true
        var tailLow: UInt64?
        var tailHigh: UInt64?
        if let progress = loadProgress(maxInode: scanMax, log: log) {
            scanMax = progress.maxInode
            low = progress.low
            high = progress.high
            scanned = progress.scanned
            segments = progress.segments
            candidates = progress.candidates
            phaseHigh = progress.phaseHigh
            tailLow = progress.tailLow
            tailHigh = progress.tailHigh
            let percent = scanMax > 0
                ? Double(scanned) / Double(scanMax) * 100 : 0
            log(String(format: "[pathleak] 续扫：low=%llu high=%llu，已扫 %llu/%llu（%.1f%%），段 %d，候选 %d，下一段%@",
                       low, high, scanned, scanMax, percent, segments, candidates,
                       tailLow != nil ? "补扫新增高段" : (phaseHigh ? "高段" : "低段")))
        } else {
            log(String(format: "[pathleak] 新扫：maxInode=%llu，从高低两端开始", scanMax))
        }
        while low <= high || (tailLow != nil && tailHigh != nil) {
            if Date() >= deadline {
                log("pathleak：达到本次定位时限，已扫描 \(scanned)/\(scanMax) 个 inode")
                return PathleakResult(foundPath: nil, available: true, timedOut: true,
                                      maxInode: scanMax, scannedInodes: scanned,
                                      segments: segments, candidates: candidates,
                                      enumerationMilliseconds: enumerationMilliseconds)
            }

            let fromHigh: Bool
            let start: UInt64
            let end: UInt64
            if let floor = tailLow, let tailEnd = tailHigh {
                // Scan the range added by a larger probe upper bound first;
                // it sits entirely above the old frontier, so it cannot
                // double-count the normal high/low ranges.
                fromHigh = true
                end = tailEnd
                start = end >= segmentSize ? max(floor, end - segmentSize + 1) : floor
                if start > 1 {
                    let next = start - 1
                    if next >= floor {
                        tailHigh = next
                    } else {
                        tailLow = nil
                        tailHigh = nil
                    }
                } else {
                    tailLow = nil
                    tailHigh = nil
                }
            } else if phaseHigh {
                end = high
                start = end >= segmentSize ? max(low, end - segmentSize + 1) : low
                high = start > 1 ? start - 1 : 0
                phaseHigh = false
            } else {
                start = low
                end = min(high, low + segmentSize - 1)
                low = end < UInt64.max ? end + 1 : UInt64.max
                phaseHigh = true
            }
            let started = DispatchTime.now()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                log("[pathleak] 段 \(segments + 1) 尚未开始：总时限已耗尽")
                return PathleakResult(foundPath: nil, available: true, timedOut: true,
                                      maxInode: scanMax, scannedInodes: scanned,
                                      segments: segments, candidates: candidates,
                                      enumerationMilliseconds: enumerationMilliseconds)
            }
            log(String(format: "[pathleak] 段 %d 开始：inode %llu–%llu（%@），剩余 %.1f 秒",
                       segments + 1, start, end, fromHigh ? "高段" : "低段", remaining))

            let resultBox = SegmentResultBox()
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                let value = WorseQueryEscape.leakedChildren(in: applicationsRoot,
                                                             from: start, to: end)
                resultBox.store(value)
                finished.signal()
            }
            if finished.wait(timeout: .now() + remaining) == .timedOut {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                log(String(format: "[pathleak] 段 %d 超时：inode %llu–%llu，等待 %.0f ms；底层枚举线程无法强制终止，本轮停止继续扫描",
                           segments + 1, start, end, elapsed))
                return PathleakResult(foundPath: nil, available: true, timedOut: true,
                                      maxInode: scanMax, scannedInodes: scanned,
                                      segments: segments, candidates: candidates,
                                      enumerationMilliseconds: enumerationMilliseconds + elapsed)
            }
            let leaked = resultBox.load() ?? []
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            enumerationMilliseconds += elapsed
            let counted = end - start + 1
            scanned = min(scanMax, scanned + counted)
            segments += 1
            candidates += leaked.count
            log(String(format: "[pathleak] 段 %d 完成：inode %llu–%llu，本段 %d 个候选，累计 %d 个，耗时 %.0f ms",
                       segments, start, end, leaked.count, candidates, elapsed))

            if let found = inspect(leaked, segments) {
                clearProgress()
                log("[pathleak] 已找到容器，扫描进度清零")
                return PathleakResult(foundPath: found, available: true, timedOut: false,
                                      maxInode: scanMax, scannedInodes: scanned,
                                      segments: segments, candidates: candidates,
                                      enumerationMilliseconds: enumerationMilliseconds)
            }
            if low <= high || (tailLow != nil && tailHigh != nil) {
                saveProgress(maxInode: scanMax, low: low, high: high,
                             scanned: scanned, segments: segments, candidates: candidates,
                             phaseHigh: phaseHigh, tailLow: tailLow, tailHigh: tailHigh)
            }
        }

        // Reaching here means the whole inode space was covered. The next
        // attempt must start from zero so a container that appears later can
        // be found; the progress checkpoint is not a permanent "done" marker.
        clearProgress()
        log(String(format: "[pathleak] 全量扫完：%llu/%llu 个 inode，段 %d，候选 %d；进度清零，下次从头扫",
                   scanned, scanMax, segments, candidates))
        return PathleakResult(foundPath: nil, available: true, timedOut: false,
                              maxInode: scanMax, scannedInodes: scanned,
                              segments: segments, candidates: candidates,
                              enumerationMilliseconds: enumerationMilliseconds)
    }
}
