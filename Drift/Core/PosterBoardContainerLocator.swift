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

    /// Enumerate the applications root in contiguous inode ranges. The caller
    /// inspects each segment and returns a path as soon as it identifies the
    /// PosterBoard container. The temporary inode-bound file is always removed.
    static func scanPathleak(
        deadline: Date,
        log: (String) -> Void,
        inspect: ([String], Int) -> String?
    ) -> PathleakResult {
        guard let limit = WorseQueryEscape.pathleakScanLimit() else {
            log("pathleak：无法建立 inode 上限临时文件")
            return PathleakResult(foundPath: nil, available: false, timedOut: false,
                                  maxInode: 0, scannedInodes: 0, segments: 0,
                                  candidates: 0, enumerationMilliseconds: 0)
        }
        defer { limit.cleanup() }

        var scanned: UInt64 = 0
        var segments = 0
        var candidates = 0
        var enumerationMilliseconds: Double = 0

        while scanned < limit.maxInode {
            if Date() >= deadline {
                log("pathleak：达到本次定位时限，已扫描 \(scanned)/\(limit.maxInode) 个 inode")
                return PathleakResult(foundPath: nil, available: true, timedOut: true,
                                      maxInode: limit.maxInode, scannedInodes: scanned,
                                      segments: segments, candidates: candidates,
                                      enumerationMilliseconds: enumerationMilliseconds)
            }

            let start = scanned + 1
            let end = scanned + min(segmentSize, limit.maxInode - scanned)
            let started = DispatchTime.now()
            let leaked = WorseQueryEscape.leakedChildren(in: applicationsRoot,
                                                         from: start, to: end)
            enumerationMilliseconds += Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            scanned = end
            segments += 1
            candidates += leaked.count
            log("pathleak 段 \(segments)：inode \(start)–\(end)，本段 \(leaked.count) 个候选，累计 \(candidates) 个")

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
