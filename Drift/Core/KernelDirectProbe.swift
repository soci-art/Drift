import Foundation
import KernelDirect

/// The kernel preflight for 内核直刷. It establishes the 3106 kernel R/W
/// backend, locates PosterBoard's real container, and proves create/write/read
/// /delete access inside the actual wallpaper store. It never writes a
/// wallpaper descriptor; that is the next stage in KernelDirectWriter.
///
/// The probe re-checks the device premise, runs the chain under one hard
/// 60-second ceiling, then tests the target store itself. sandbox_escape is
/// attempted for compatibility, but its return value is not the write gate.
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
        let containerPath: String?
        let storePath: String?
        let structureVersions: [Int]

        init(passed: Bool, failure: String?,
             containerPath: String? = nil, storePath: String? = nil,
             structureVersions: [Int] = []) {
            self.passed = passed
            self.failure = failure
            self.containerPath = containerPath
            self.storePath = storePath
            self.structureVersions = structureVersions
        }
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
                                log: @escaping (String) -> Void) -> Report {
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
        let alreadyEstablished = chainSucceededInThisProcess
        chainLock.unlock()
        if tainted {
            log("[内核探针] 2/5 拒绝：本进程上一次内核链已经失败或超时，重启 App 后才能再跑")
            return Report(passed: false,
                          failure: "上一次内核链在这个进程里已经失败或超时了，重启 App 后才能再试。")
        }

        let started = Date()
        let deadline = started.addingTimeInterval(timeout)

        // Match 3106's iOS 17/18 kernel backend: successful kernel R/W is
        // enough to proceed. sandbox_escape is attempted, but its return
        // value is not treated as the container-access verdict.
        if alreadyEstablished {
            log("[内核探针] 2/5 本进程内核读写已建立，跳过重复 exploit")
        } else {
            log("[内核探针] 2/5 启动内核链（上限 \(Int(timeout)) 秒）…")
            fflush(stdout)
            let code = runChainWithDeadline(deadline: deadline,
                                            log: { log($0) })
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
            chainLock.lock(); chainSucceededInThisProcess = true; chainLock.unlock()
            log(String(format: "[内核探针] 2/5 通过：内核读写已建立（耗时 %.1f 秒）", elapsed))
        }

        log("[内核探针] 3/5 内核读写状态确认：sandbox_escape 不作硬门槛")
        if pastDeadline(deadline) {
            return timeoutReport(log: log, step: "3/5")
        }
        log("[内核探针] 3/5 通过：开始检查真实目标容器")

        log("[内核探针] 4/5 定位 PosterBoard 容器")
        if pastDeadline(deadline) {
            return timeoutReport(log: log, step: "4/5")
        }
        let locatedResult = locateStore(deadline: deadline, log: log)
        if locatedResult.timedOut {
            return timeoutReport(log: log, step: "4/5")
        }
        guard let located = locatedResult.store else {
            log("[内核探针] 4/5 失败：三种找法都没有找到商店")
            return Report(passed: false, failure: "没有找到 PosterBoard 容器。")
        }
        let versions = located.structureVersions.map(String.init).joined(separator: "、")
        log("[内核探针] 4/5 通过：容器 \(located.container)，商店 \(located.store)，结构版本 \(versions.isEmpty ? "（无代际目录）" : versions)")

        log("[内核探针] 5/5 PosterBoard 容器写-读-删自检")
        if pastDeadline(deadline) {
            return timeoutReport(log: log, step: "5/5")
        }
        let probe = writeReadDelete(in: located.store)
        if let failure = probe.failure {
            log("[内核探针] 5/5 失败：\(failure)")
            return Report(passed: false, failure: "PosterBoard 容器写-读-删自检没有通过：\(failure)。")
        }
        log("[内核探针] 5/5 通过：\(probe.path ?? "临时文件") 写入、读回一致、已删除")
        log("[内核探针] 全部通过：PosterBoard 容器可读写，未改动任何壁纸")

        return Report(passed: true, failure: nil,
                      containerPath: located.container,
                      storePath: located.store,
                      structureVersions: located.structureVersions)
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
    /// A successful kernel R/W chain is never re-entered in this process.
    private static var chainSucceededInThisProcess = false

    private final class CodeBox: @unchecked Sendable {
        var value: Int32 = -1
    }

    /// Runs `kexploit_opa334` + `sandbox_escape` on a dedicated thread and
    /// waits at most until `deadline`. A timed-out thread cannot be killed;
    /// the caller treats the timeout as a failure and taints the process.
    ///
    /// The chain's own `printf` output is captured into the app log: almost
    /// every early failure (an IOSurface that would not be created, a
    /// `mach_vm_map` that was refused) is written there and nowhere else, so
    /// without this a device log only shows "returned -1".
    private static func runChainWithDeadline(deadline: Date,
                                             log: @escaping (String) -> Void) -> Int32 {
        let savedStdout = startStdoutCapture(log: log)
        defer {
            if let savedStdout { stopStdoutCapture(saved: savedStdout) }
        }

        let box = CodeBox()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let ret = kexploit_opa334()
            if ret == 0 {
                let proc = proc_self()
                if proc == 0 {
                    box.value = -2
                } else {
                    let escapeResult = sandbox_escape(proc)
                    printf("[3106兼容] sandbox_escape 返回 %d；内核读写链已成功，继续验证目标容器\\n", escapeResult)
                    box.value = 0
                }
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

    // MARK: - Chain output capture

    /// Point fd 1 at a pipe and log every line the chain writes, on a reader
    /// thread so a full pipe can never stall the exploit. Returns the saved
    /// stdout descriptor, or nil when the pipe could not be set up (the
    /// chain then runs with its output going wherever it went before).
    private static func startStdoutCapture(log: @escaping (String) -> Void) -> Int32? {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        setvbuf(stdout, nil, _IONBF, 0)
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else {
            close(fds[0]); close(fds[1])
            return nil
        }
        dup2(fds[1], STDOUT_FILENO)
        close(fds[1])
        let readFd = fds[0]
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var pending = ""
            func flushPending() {
                while let idx = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<idx])
                    pending = String(pending[pending.index(after: idx)...])
                    if !line.isEmpty { log("[内核链] \(line)") }
                }
            }
            while true {
                let count = read(readFd, &buffer, buffer.count)
                if count <= 0 { break }
                pending += String(decoding: buffer[0..<count], as: UTF8.self)
                flushPending()
            }
            if !pending.isEmpty { log("[内核链] \(pending)") }
            close(readFd)
        }
        return saved
    }

    /// Put fd 1 back. The chain may still be running after a timeout; the
    /// pipe's read end is therefore left to its reader, which sees EOF as
    /// soon as fd 1 stops pointing at the pipe.
    private static func stopStdoutCapture(saved: Int32) {
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
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
        // Capture errno now: close()/unlink() below would replace it, and a
        // failure report carrying their errno instead of the write's misleads
        // whoever reads the log later.
        let writeErrno = errno
        if written == 1, lseek(fd, 0, SEEK_SET) == 0 {
            var got: UInt8 = 0
            let readCount = withUnsafeMutableBytes(of: &got) { read(fd, $0.baseAddress, 1) }
            readBack = readCount == 1 && got == expected
            wrote = true
        }
        close(fd)
        deleted = path.withCString { unlink($0) } == 0

        guard wrote else {
            return WriteReadDeleteResult(path: nil, failure: "临时文件写入失败（errno \(writeErrno)）")
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

    struct LocatedStore {
        let container: String
        let store: String
        let structureVersions: [Int]
    }

    private static let applicationsRoot = "/private/var/mobile/Containers/Data/Application"
    private static let posterBoardBundleID = "com.apple.PosterBoard"

    /// Three-level container discovery. The later probe stage performs a
    /// create/write/read/delete test in the returned store. `timedOut`
    /// distinguishes a deadline from a completed negative scan.
    private static func locateStore(deadline: Date,
                                    log: (String) -> Void) -> (store: LocatedStore?, timedOut: Bool) {
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
                    return (LocatedStore(container: container,
                                         store: store,
                                         structureVersions: structureVersions(in: store)), false)
                }
            }
            log("[内核探针] 5/5 找法一没有命中")
        } else {
            log("[内核探针] 5/5 找法一（应用快照）：没有缓存路径")
        }

        guard let entries = try? manager.contentsOfDirectory(atPath: applicationsRoot) else {
            log("[内核探针] 5/5 列不出 \(applicationsRoot)")
            return (nil, false)
        }
        log("[内核探针] 5/5 应用数据容器 \(entries.count) 个，开始找法二、找法三")

        // Level 2 — the container-manager query: read each container's own
        // metadata and match PosterBoard's bundle identifier.
        for (index, entry) in entries.enumerated() {
            if pastDeadline(deadline) {
                log("[内核探针] 5/5 找法二因超过总时限停下（已查 \(index)/\(entries.count) 个容器）")
                return (nil, true)
            }
            if index % 200 == 0 && index > 0 {
                log("[内核探针] 5/5 已查 \(index)/\(entries.count) 个容器")
            }
            let container = (applicationsRoot as NSString).appendingPathComponent(entry)
            guard containerHasPosterBoardIdentity(container) else { continue }
            if let store = storeIn(container: container) {
                log("[内核探针] 5/5 找法二命中（容器管理查询）：\(container)")
                return (LocatedStore(container: container,
                                     store: store,
                                     structureVersions: structureVersions(in: store)), false)
            }
        }
        log("[内核探针] 5/5 找法二没有命中")

        // Level 3 — the metadata scan fallback: look for the store directory
        // itself in every container.
        for entry in entries {
            if pastDeadline(deadline) {
                log("[内核探针] 5/5 找法三因超过总时限停下")
                return (nil, true)
            }
            let container = (applicationsRoot as NSString).appendingPathComponent(entry)
            if let store = storeIn(container: container) {
                log("[内核探针] 5/5 找法三命中（商店目录扫描）：\(container)")
                return (LocatedStore(container: container,
                                     store: store,
                                     structureVersions: structureVersions(in: store)), false)
            }
        }
        log("[内核探针] 5/5 找法三没有命中")
        return (nil, false)
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
