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

    struct PathleakResult {
        let foundPath: String?
        let available: Bool
        let timedOut: Bool
        let maxInode: UInt64
        let scannedInodes: UInt64
        let segments: Int
        let candidates: Int
        let enumerationMilliseconds: Double
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
        var low: UInt64 = 1
        var high: UInt64 = limit.maxInode
        while low <= high {
            if Date() >= deadline {
                log("pathleak：达到本次定位时限，已扫描 \(scanned)/\(limit.maxInode) 个 inode")
                return PathleakResult(foundPath: nil, available: true, timedOut: true,
                                      maxInode: limit.maxInode, scannedInodes: scanned,
                                      segments: segments, candidates: candidates,
                                      enumerationMilliseconds: enumerationMilliseconds)
            }

            let fromHigh = segments % 2 == 0
            let start: UInt64
            let end: UInt64
            if fromHigh {
                end = high
                start = end >= segmentSize ? max(low, end - segmentSize + 1) : low
                high = start > 1 ? start - 1 : 0
            } else {
                start = low
                end = min(high, low + segmentSize - 1)
                low = end < UInt64.max ? end + 1 : UInt64.max
            }
            let started = DispatchTime.now()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                log("[pathleak] 段 \(segments + 1) 尚未开始：总时限已耗尽")
                return PathleakResult(foundPath: nil, available: true, timedOut: true,
                                      maxInode: limit.maxInode, scannedInodes: scanned,
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
                                      maxInode: limit.maxInode, scannedInodes: scanned,
                                      segments: segments, candidates: candidates,
                                      enumerationMilliseconds: enumerationMilliseconds + elapsed)
            }
            let leaked = resultBox.load() ?? []
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            enumerationMilliseconds += elapsed
            let counted = end - start + 1
            scanned = min(limit.maxInode, scanned + counted)
            segments += 1
            candidates += leaked.count
            log(String(format: "[pathleak] 段 %d 完成：inode %llu–%llu，本段 %d 个候选，累计 %d 个，耗时 %.0f ms",
                       segments, start, end, leaked.count, candidates, elapsed))

            if let found = inspect(leaked, segments) {
                return PathleakResult(foundPath: found, available: true, timedOut: false,
                                      maxInode: limit.maxInode, scannedInodes: scanned,
                                      segments: segments, candidates: candidates,
                                      enumerationMilliseconds: enumerationMilliseconds)
            }
        }

        return PathleakResult(foundPath: nil, available: true, timedOut: false,
                              maxInode: limit.maxInode, scannedInodes: scanned,
                              segments: segments, candidates: candidates,
                              enumerationMilliseconds: enumerationMilliseconds)
    }
}
