import Foundation
import KernelDirect

/// Phase one of 内核直刷 (#319, construction order §4): **verify only, never
/// flash.** The probe proves that this device, on this system, can run the
/// kernel chain and reach the wallpaper store — and writes no wallpaper byte.
///
/// The five steps, in the fixed order the order states (each one logs a line
/// that can be read back from a remote log upload):
///
/// 1. Re-check the version band and the chip table *inside the backend* — the
///    caller's word is not trusted (`KernelDirectPremise` also re-reads the
///    model itself).
/// 2. Run the kernel chain (`kexploit_opa334` → `sandbox_escape`) under one
///    hard 60-second ceiling. The upstream chain retries physical reads
///    without a limit; the ceiling is what keeps this run from spinning
///    forever, and a timeout is a failure.
/// 3. Sandbox self-check through the chain's own criterion
///    (`sandbox_access_is_active`).
/// 4. Write-read-delete self-check outside this app's sandbox
///    (`/private/var/mobile/Containers/Data/Application` — the same level the
///    store lives at). All three halves must pass.
/// 5. Locate the wallpaper store read-only, in the three-level order the
///    order names (known container snapshot → container-manager metadata →
///    store-directory scan), and record the path plus the structure version
///    (61 on the supported systems).
///
/// Success requires all five. A failure returns an error and leaves the device
/// untouched; the app stays alive because 3106's longjmp path is what runs
/// the chain. A failed or timed-out chain taints this process — the order
/// requires a relaunch before another attempt, and the chain is not safe to
/// run twice.
enum KernelDirectProbe {
    /// The whole chain, from its start to its return, gets this long.
    static let timeout: TimeInterval = 60

    struct Report {
        let passed: Bool
        /// One user-facing line when `passed` is false.
        let failure: String?
    }

    // MARK: - Entry

    /// Runs off the main thread — the kernel chain is heavy and may freeze the
    /// screen for a moment. `log` is called from that background thread.
    static func run(log: @escaping @Sendable (String) -> Void) async -> Report {
        let version = WorseQueryEscape.processVersion
        let model = KernelDirectPremise.modelIdentifier
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: execute(version: version,
                                                       model: model,
                                                       log: log))
            }
        }
    }

    // MARK: - The five steps

    private static func execute(version: String,
                                model: String,
                                log: (String) -> Void) -> Report {
        // 1. The band and the table, re-checked here: a stale card, a
        //    restored pick or a future caller cannot wave the chain through.
        log("[内核探针] 1/5 后端复查：iOS \(version)，机型 \(model)")
        let premise = KernelDirectPremise.evaluate(version: version)
        guard premise.ready else {
            let why = premise.reason.isEmpty ? "版本或机型不在支持范围" : premise.reason
            log("[内核探针] 1/5 拒绝：\(why)")
            return Report(passed: false, failure: "内核探针没有运行：\(why)。")
        }
        log("[内核探针] 1/5 通过：版本带与机型都在支持范围内")

        chainLock.lock()
        let tainted = chainFailedInThisProcess
        chainLock.unlock()
        if tainted {
            log("[内核探针] 2/5 拒绝：本进程上一次内核链已经失败或超时，重启 App 后才能再跑")
            return Report(passed: false,
                          failure: "上一次内核链在这个进程里已经失败或超时了，重启 App 后才能再试。")
        }

        let started = Date()
        let deadline = started.addingTimeInterval(timeout)

        // 2. The chain itself, under the ceiling. If the sandbox is already
        //    escaped in this process (the probe was run before), the chain is
        //    not run a second time — re-running kernel r/w in one process is
        //    not something the upstream code supports.
        if sandbox_access_is_active() == 1 {
            log("[内核探针] 2/5 本进程的脱沙盒已生效，跳过内核链（同一进程不重跑链）")
        } else {
            log("[内核探针] 2/5 启动内核链（上限 \(Int(timeout)) 秒）…")
            let code = runChainWithDeadline(deadline: deadline)
            let elapsed = Date().timeIntervalSince(started)
            if code == codeTimedOut {
                chainLock.lock(); chainFailedInThisProcess = true; chainLock.unlock()
                log(String(format: "[内核探针] 2/5 失败：超过 %.0f 秒没有返回，按失败处理", elapsed))
                return Report(passed: false,
                              failure: String(format: "内核链超过 %d 秒没有返回，按失败处理。", Int(timeout)))
            }
            guard code == 0 else {
                chainLock.lock(); chainFailedInThisProcess = true; chainLock.unlock()
                log(String(format: "[内核探针] 2/5 失败：内核链返回 %d（耗时 %.1f 秒）", code, elapsed))
                return Report(passed: false, failure: "内核链失败（返回 \(code)）。")
            }
            log(String(format: "[内核探针] 2/5 通过：内核链返回 0（耗时 %.1f 秒）", elapsed))
        }

        // 3. The chain's own self-check: process-level read/write must be
        //    active, not merely "the functions returned 0".
        log("[内核探针] 3/5 脱沙盒自检")
        if pastDeadline(deadline) {
            return timeoutReport(log: log, step: "3/5")
        }
        guard sandbox_access_is_active() == 1 else {
            log("[内核探针] 3/5 失败：进程级读写没有生效")
            return Report(passed: false, failure: "脱沙盒自检没有通过：进程级读写没有生效。")
        }
        log("[内核探针] 3/5 通过：进程级读写已生效")

        // 4. Write, read back byte for byte, delete, confirm gone. This is a
        //    temporary file at the sandbox-external container level — never
        //    the wallpaper store, never a wallpaper.
        log("[内核探针] 4/5 写-读-删自检")
        if pastDeadline(deadline) {
            return timeoutReport(log: log, step: "4/5")
        }
        let probeDirectory = "/private/var/mobile/Containers/Data/Application"
        let probe = writeReadDelete(in: probeDirectory)
        if let failure = probe.failure {
            log("[内核探针] 4/5 失败：\(failure)")
            return Report(passed: false, failure: "写-读-删自检没有通过：\(failure)。")
        }
        log("[内核探针] 4/5 通过：\(probe.path ?? "临时文件") 写入、读回一致、已删除")

        // 5. Locate the store, read-only, and record what was found.
        log("[内核探针] 5/5 定位壁纸商店（只读）")
        if pastDeadline(deadline) {
            return timeoutReport(log: log, step: "5/5")
        }
        guard let located = locateStore(deadline: deadline, log: log) else {
            log("[内核探针] 5/5 失败：三种找法都没有找到商店")
            return Report(passed: false, failure: "没有找到壁纸商店。")
        }
        let versions = located.structureVersions.map(String.init).joined(separator: "、")
        log("[内核探针] 5/5 通过：商店 \(located.store)，结构版本 \(versions.isEmpty ? "（无代际目录）" : versions)")
        log("[内核探针] 全部通过：本次零写入，没有改动任何壁纸")

        return Report(passed: true, failure: nil)
    }

    private static func timeoutReport(log: (String) -> Void, step: String) -> Report {
        chainLock.lock(); chainFailedInThisProcess = true; chainLock.unlock()
        log("[内核探针] \(step) 失败：超过总时限 \(Int(timeout)) 秒")
        return Report(passed: false, failure: "超过总时限 \(Int(timeout)) 秒，按失败处理。")
    }

    private static func pastDeadline(_ deadline: Date) -> Bool {
        Date() >= deadline
    }

    // MARK: - The chain

    private static let codeTimedOut: Int32 = -999

    private static let chainLock = NSLock()
    /// A failed or timed-out chain is not run again in this process: the
    /// order requires a relaunch, and the chain is not re-entrant.
    private static var chainFailedInThisProcess = false

    private final class CodeBox: @unchecked Sendable {
        var value: Int32 = -1
    }

    /// Runs `kexploit_opa334` + `sandbox_escape` on a dedicated thread and
    /// waits at most until `deadline`. A timed-out thread cannot be killed;
    /// the caller treats the timeout as a failure and taints the process.
    private static func runChainWithDeadline(deadline: Date) -> Int32 {
        let box = CodeBox()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let ret = kexploit_opa334()
            if ret == 0 {
                let proc = proc_self()
                box.value = proc == 0 ? -2 : sandbox_escape(proc)
            } else {
                box.value = ret
            }
            finished.signal()
        }
        let remaining = max(0, deadline.timeIntervalSinceNow)
        if finished.wait(timeout: .now() + remaining) == .timedOut {
            return codeTimedOut
        }
        return box.value
    }

    // MARK: - Write-read-delete

    private struct WriteReadDeleteResult {
        let path: String?
        let failure: String?
    }

    private static func writeReadDelete(in directory: String) -> WriteReadDeleteResult {
        let name = ".drift-kernel-probe-\(getpid())-\(UUID().uuidString)"
        let path = (directory as NSString).appendingPathComponent(name)
        let expected: UInt8 = 0x31

        let fd = path.withCString { open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600) }
        guard fd >= 0 else {
            return WriteReadDeleteResult(path: nil,
                                         failure: "在 \(directory) 里建不了临时文件（errno \(errno)）")
        }
        var wrote = false
        var readBack = false
        var deleted = false
        defer {
            if !deleted { _ = path.withCString { unlink($0) } }
        }

        var byte = expected
        let written = withUnsafeBytes(of: &byte) { write(fd, $0.baseAddress, 1) }
        if written == 1, lseek(fd, 0, SEEK_SET) == 0 {
            var got: UInt8 = 0
            let readCount = withUnsafeMutableBytes(of: &got) { read(fd, $0.baseAddress, 1) }
            readBack = readCount == 1 && got == expected
            wrote = true
        }
        close(fd)
        deleted = path.withCString { unlink($0) } == 0

        guard wrote else {
            return WriteReadDeleteResult(path: nil, failure: "临时文件写入失败（errno \(errno)）")
        }
        guard readBack else {
            return WriteReadDeleteResult(path: nil, failure: "临时文件读回的内容和写入的不一致")
        }
        guard deleted else {
            return WriteReadDeleteResult(path: nil, failure: "临时文件删除失败（errno \(errno)）")
        }
        guard !FileManager.default.fileExists(atPath: path) else {
            return WriteReadDeleteResult(path: nil, failure: "临时文件删除后仍然存在")
        }
        return WriteReadDeleteResult(path: path, failure: nil)
    }

    // MARK: - Store location (read-only)

    private struct LocatedStore {
        let container: String
        let store: String
        let structureVersions: [Int]
    }

    private static let applicationsRoot = "/private/var/mobile/Containers/Data/Application"
    private static let posterBoardBundleID = "com.apple.PosterBoard"

    /// The three-level find the order names. Every level only tests for the
    /// store directory; nothing is created, written or removed.
    private static func locateStore(deadline: Date,
                                    log: (String) -> Void) -> LocatedStore? {
        let manager = FileManager.default

        // Level 1 — the application snapshot: container paths this install
        // already knows (the tunnel's cached container, the local channel's
        // cache). One or two probes instead of a scan.
        var known: [String] = []
        for candidate in [PosterBoardAirlift.cachedContainer,
                          PosterBoardLocal.cachedContainer] where !candidate.isEmpty {
            let trimmed = candidate.hasSuffix("/") ? String(candidate.dropLast()) : candidate
            if !known.contains(trimmed) { known.append(trimmed) }
        }
        if !known.isEmpty {
            log("[内核探针] 5/5 找法一（应用快照）：\(known.count) 个已知容器路径")
            for container in known {
                if let store = storeIn(container: container) {
                    log("[内核探针] 5/5 找法一命中：\(container)")
                    return LocatedStore(container: container,
                                        store: store,
                                        structureVersions: structureVersions(in: store))
                }
            }
            log("[内核探针] 5/5 找法一没有命中")
        } else {
            log("[内核探针] 5/5 找法一（应用快照）：没有缓存路径")
        }

        guard let entries = try? manager.contentsOfDirectory(atPath: applicationsRoot) else {
            log("[内核探针] 5/5 列不出 \(applicationsRoot)")
            return nil
        }
        log("[内核探针] 5/5 应用数据容器 \(entries.count) 个，开始找法二、找法三")

        // Level 2 — the container-manager query: read each container's own
        // metadata and match PosterBoard's bundle identifier.
        for (index, entry) in entries.enumerated() {
            if pastDeadline(deadline) { break }
            if index % 200 == 0 && index > 0 {
                log("[内核探针] 5/5 已查 \(index)/\(entries.count) 个容器")
            }
            let container = (applicationsRoot as NSString).appendingPathComponent(entry)
            guard containerHasPosterBoardIdentity(container) else { continue }
            if let store = storeIn(container: container) {
                log("[内核探针] 5/5 找法二命中（容器管理查询）：\(container)")
                return LocatedStore(container: container,
                                    store: store,
                                    structureVersions: structureVersions(in: store))
            }
        }
        log("[内核探针] 5/5 找法二没有命中")

        // Level 3 — the metadata scan fallback: look for the store directory
        // itself in every container.
        for entry in entries {
            if pastDeadline(deadline) { break }
            let container = (applicationsRoot as NSString).appendingPathComponent(entry)
            if let store = storeIn(container: container) {
                log("[内核探针] 5/5 找法三命中（商店目录扫描）：\(container)")
                return LocatedStore(container: container,
                                    store: store,
                                    structureVersions: structureVersions(in: store))
            }
        }
        log("[内核探针] 5/5 找法三没有命中")
        return nil
    }

    private static func containerHasPosterBoardIdentity(_ container: String) -> Bool {
        let metadata = (container as NSString)
            .appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        guard let plist = NSDictionary(contentsOfFile: metadata),
              let identifier = plist["MCMMetadataIdentifier"] as? String else {
            return false
        }
        return identifier.trimmingCharacters(in: .whitespacesAndNewlines) == posterBoardBundleID
    }

    private static func storeIn(container: String) -> String? {
        let store = container + PosterBoard.storeRoot
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: store, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return store
    }

    private static func structureVersions(in store: String) -> [Int] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: store)) ?? []
        return entries.compactMap { Int($0) }.sorted(by: >)
    }
}
