import Foundation
import KernelDirect

/// The kernel preflight for 内核直刷. It establishes the 3106 kernel R/W
/// backend, locates PosterBoard's real container, and proves create/write/read
/// /delete access inside the actual wallpaper store. It never writes a
/// wallpaper descriptor; that is the next stage in KernelDirectWriter.
///
/// The probe re-checks the device premise, then runs two independent
/// 60-second windows: one for the chain (including its sandbox-escape
/// retries) and one for locating and testing the store. Neither window can
/// spend the other's budget. sandbox_escape is attempted for compatibility,
/// but its return value is not the write gate.
///
/// Success requires all five. A failure returns an error and leaves the device
/// untouched; the app stays alive because 3106's longjmp path is what runs
/// the chain. A failed or timed-out chain taints this process — the order
/// requires a relaunch before another attempt, and the chain is not safe to
/// run twice.
enum KernelDirectProbe {
    /// The chain, from its start through any sandbox-escape retries.
    static let chainTimeout: TimeInterval = 60
    /// Store location and its read/write self-test, counted on its own.
    static let locationTimeout: TimeInterval = 60

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

        // Keep the full diagnostic log, but also mirror meaningful probe
        // milestones into the flashing cover. Without this, the user sees
        // one static "checking" message while pathleak may be scanning.
        let emit: @Sendable (String) -> Void = { line in
            log(line)
            guard let stage = visibleStage(for: line) else { return }
            Task { @MainActor in
                DriftSession.shared.flashStage = stage
            }
        }

        emit("[内核探针] run() 已进入：iOS \(version)，机型 \(model)")
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = Date()
                emit("[内核探针] 后台执行线程已启动")
                let report = execute(version: version, model: model, log: emit)
                emit(String(format: "[内核探针] execute() 返回：passed=%@，总耗时 %.2f 秒",
                            report.passed ? "true" : "false",
                            Date().timeIntervalSince(started)))
                continuation.resume(returning: report)
            }
        }
    }

    /// Translate low-level probe logs into concise, live cover text. The
    /// detailed log remains the source of truth for exact inode ranges,
    /// candidate counts, errno values and elapsed times.
    private static func visibleStage(for line: String) -> String? {
        if line.contains("全部通过") {
            return "PosterBoard 容器读写验证通过，准备写入壁纸"
        }
        if line.contains("[pathleak]") {
            if line.contains("开始") {
                return "正在分段定位 PosterBoard 容器"
            }
            if line.contains("超时") {
                return "PosterBoard 容器定位超时，正在整理诊断结果"
            }
            return "正在扫描 PosterBoard 容器，请保持 Drift 在前台"
        }
        if line.contains("[容器定位]") || line.contains("4/5") {
            return "正在定位 PosterBoard 容器"
        }
        if line.contains("5/5") {
            return "正在验证 PosterBoard 商店的创建、写入、读回与删除能力"
        }
        if line.contains("3/5") {
            return "内核读写能力已建立，正在确认目标容器访问状态"
        }
        if line.contains("2/5") || line.contains("[内核链]") {
            return "正在建立内核读写能力，请保持 Drift 在前台"
        }
        if line.contains("1/5") {
            return "正在复查当前系统版本与设备支持条件"
        }
        return nil
    }

    // MARK: - The five steps

    private static func execute(version: String,
                                model: String,
                                log: @escaping (String) -> Void) -> Report {
        executionLock.lock()
        defer { executionLock.unlock() }

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
        let chainDeadline = started.addingTimeInterval(chainTimeout)

        // Match 3106's iOS 17/18 kernel backend: successful kernel R/W is
        // enough to proceed. sandbox_escape is attempted, but its return
        // value is not treated as the container-access verdict.
        if alreadyEstablished {
            log("[内核探针] 2/5 本进程内核读写已建立，跳过重复 exploit")
        } else {
            log("[内核探针] 2/5 启动内核链（建链段上限 \(Int(chainTimeout)) 秒）…")
            fflush(stdout)
            let code = runChainWithDeadline(deadline: chainDeadline,
                                            log: { log($0) })
            let elapsed = Date().timeIntervalSince(started)
            if code == codeTimedOut {
                chainLock.lock(); chainFailedInThisProcess = true; chainLock.unlock()
                log(String(format: "[内核探针] 2/5 失败：超过 %.0f 秒没有返回，按失败处理", elapsed))
                return Report(passed: false,
                              failure: String(format: "内核链超过 %d 秒没有返回，按失败处理。", Int(chainTimeout)))
            }
            guard code == 0 else {
                chainLock.lock(); chainFailedInThisProcess = true; chainLock.unlock()
                log(String(format: "[内核探针] 2/5 失败：内核链返回 %d（耗时 %.1f 秒）", code, elapsed))
                return Report(passed: false, failure: "内核链失败（返回 \(code)）。")
            }
            chainLock.lock(); chainSucceededInThisProcess = true; chainLock.unlock()
            log(String(format: "[内核探针] 2/5 通过：内核读写已建立（耗时 %.1f 秒）", elapsed))
        }

        // The location window starts only after the chain window is done.
        let locationDeadline = Date().addingTimeInterval(locationTimeout)
        log("[内核探针] 定位段开始：独立上限 \(Int(locationTimeout)) 秒，不占用建链段")

        log("[内核探针] 3/5 内核读写状态确认：sandbox_escape 不作硬门槛")
        if pastDeadline(locationDeadline) {
            return timeoutReport(log: log, step: "3/5", segment: "定位段",
                                 seconds: locationTimeout, taintsChain: false)
        }
        log("[内核探针] 3/5 通过：开始检查真实目标容器")

        log("[内核探针] 4/5 定位 PosterBoard 容器")
        if pastDeadline(locationDeadline) {
            return timeoutReport(log: log, step: "4/5", segment: "定位段",
                                 seconds: locationTimeout, taintsChain: false)
        }
        let locatedResult = locateStore(deadline: locationDeadline, log: log)
        if locatedResult.timedOut {
            return timeoutReport(log: log, step: "4/5", segment: "定位段",
                                 seconds: locationTimeout, taintsChain: false)
        }
        guard let located = locatedResult.store else {
            log("[内核探针] 4/5 失败：三种找法都没有找到商店")
            return Report(passed: false, failure: "没有找到 PosterBoard 容器。")
        }
        let versions = located.structureVersions.map(String.init).joined(separator: "、")
        log("[内核探针] 4/5 通过：容器 \(located.container)，商店 \(located.store)，结构版本 \(versions.isEmpty ? "（无代际目录）" : versions)")

        log("[内核探针] 5/5 PosterBoard 容器写-读-删自检")
        if pastDeadline(locationDeadline) {
            return timeoutReport(log: log, step: "5/5", segment: "定位段",
                                 seconds: locationTimeout, taintsChain: false)
        }
        let selfTestStarted = Date()
        log("[内核探针] 5/5 自检：开始在真实 Store 创建临时文件")
        var probe = writeReadDelete(in: located.store, log: log)
        log(String(format: "[内核探针] 5/5 自检结束：耗时 %.2f 秒", Date().timeIntervalSince(selfTestStarted)))

        if let firstFailure = probe.failure {
            log("[内核探针] 5/5 首次自检失败：\(firstFailure)")
            let proc = currentKernelSelfProc()
            if proc == 0 {
                log("[内核探针] 脱沙盒重试跳过：没有可复用的 proc_self 指针")
            } else {
                while !pastDeadline(chainDeadline) {
                    // access-style check only: no files are created or modified here.
                    let reportsWritable = FileManager.default.isWritableFile(atPath: located.store)
                    log("[内核探针] 重试前只读权限检查：Store \(reportsWritable ? "报告可写" : "报告不可写")")
                    if reportsWritable {
                        log("[内核探针] 只读检查报告可写，不重复修改内核结构；保留自检失败结果")
                        break
                    }
                    guard let retryNumber = reserveEscapeRetry() else {
                        log("[内核探针] 脱沙盒重试已达到本进程上限 3 次")
                        break
                    }
                    log("[内核探针] 脱沙盒重试 \(retryNumber)/3：只重新执行 sandbox_escape，不重打内核链")
                    guard let escapeCode = runEscapeWithDeadline(proc: proc,
                                                                 deadline: chainDeadline,
                                                                 log: log) else {
                        log("[内核探针] 脱沙盒重试 \(retryNumber)/3 超时；本进程内核链标记为不可再次进入")
                        chainLock.lock(); chainFailedInThisProcess = true; chainLock.unlock()
                        return timeoutReport(log: log, step: "5/5 脱沙盒重试", segment: "建链段",
                                             seconds: chainTimeout, taintsChain: true)
                    }
                    log("[内核探针] 脱沙盒重试 \(retryNumber)/3 返回 \(escapeCode)；返回值不作硬门槛，立即重新自检")
                    probe = writeReadDelete(in: located.store, log: log)
                    if probe.failure == nil {
                        log("[内核探针] 脱沙盒重试 \(retryNumber)/3 后自检通过")
                        break
                    }
                    log("[内核探针] 脱沙盒重试 \(retryNumber)/3 后自检仍失败：\(probe.failure ?? "未知原因")")
                }
            }
        }

        if probe.failure != nil, pastDeadline(chainDeadline) {
            log("[内核探针] 5/5 建链段时限已到，不再做脱沙盒重试")
        }
        if let failure = probe.failure {
            log("[内核探针] 5/5 最终失败：\(failure)；本进程脱沙盒重试计数 \(escapeRetryCountForLog())/3")
            return Report(passed: false,
                          failure: "PosterBoard 容器写-读-删自检没有通过：\(failure)。请完全关闭 Drift 后重新打开，再重试一次。")
        }
        log("[内核探针] 5/5 通过：\(probe.path ?? "临时文件") 写入、读回一致、已删除")
        log("[内核探针] 全部通过：PosterBoard 容器可读写，未改动任何壁纸")

        return Report(passed: true, failure: nil,
                      containerPath: located.container,
                      storePath: located.store,
                      structureVersions: located.structureVersions)
    }

    private static func timeoutReport(log: (String) -> Void,
                                      step: String,
                                      segment: String,
                                      seconds: TimeInterval,
                                      taintsChain: Bool) -> Report {
        if taintsChain {
            chainLock.lock(); chainFailedInThisProcess = true; chainLock.unlock()
        }
        log("[内核探针] \(step) 失败：\(segment)超过 \(Int(seconds)) 秒")
        return Report(passed: false, failure: "\(segment)超过 \(Int(seconds)) 秒，按失败处理。")
    }

    private static func pastDeadline(_ deadline: Date) -> Bool {
        Date() >= deadline
    }

    // MARK: - The chain

    private static let codeTimedOut: Int32 = -999

    private static let chainLock = NSLock()
    private static let executionLock = NSLock()
    /// A failed or timed-out kernel chain is never re-entered in this process.
    private static var chainFailedInThisProcess = false
    /// The expensive kernel R/W chain is established at most once per process.
    private static var chainSucceededInThisProcess = false
    /// proc_self() captured from the successful chain; escape-only retries reuse it.
    private static var kernelSelfProc: UInt64 = 0
    /// At most three escape-only retries are allowed in one process.
    private static var escapeRetriesInThisProcess = 0

    private final class CodeBox: @unchecked Sendable {
        var value: Int32 = -1
        var escapeResult: Int32?
        var selfProc: UInt64 = 0
    }

    private final class EscapeBox: @unchecked Sendable {
        var value: Int32 = -1
    }

    private static func currentKernelSelfProc() -> UInt64 {
        chainLock.lock()
        defer { chainLock.unlock() }
        return kernelSelfProc
    }

    private static func reserveEscapeRetry() -> Int? {
        chainLock.lock()
        defer { chainLock.unlock() }
        guard escapeRetriesInThisProcess < 3 else { return nil }
        escapeRetriesInThisProcess += 1
        return escapeRetriesInThisProcess
    }

    private static func escapeRetryCountForLog() -> Int {
        chainLock.lock()
        defer { chainLock.unlock() }
        return escapeRetriesInThisProcess
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
                    box.selfProc = proc
                    box.escapeResult = sandbox_escape(proc)
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
        if box.selfProc != 0 {
            chainLock.lock()
            kernelSelfProc = box.selfProc
            chainLock.unlock()
        }
        if let escapeResult = box.escapeResult {
            log("[内核兼容] sandbox_escape 返回 \(escapeResult)；内核读写链已成功，继续验证目标容器")
        }
        return box.value
    }

    // MARK: - Chain output capture

    /// Re-run only sandbox_escape on the already-established kernel R/W backend.
    /// It uses the chain window's remaining time; a timed-out worker cannot
    /// be killed.
    private static func runEscapeWithDeadline(proc: UInt64,
                                              deadline: Date,
                                              log: @escaping (String) -> Void) -> Int32? {
        let savedStdout = startStdoutCapture(log: log)
        defer {
            if let savedStdout { stopStdoutCapture(saved: savedStdout) }
        }

        let box = EscapeBox()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            box.value = sandbox_escape(proc)
            finished.signal()
        }
        let remaining = max(0, deadline.timeIntervalSinceNow)
        if finished.wait(timeout: .now() + remaining) == .timedOut {
            return nil
        }
        return box.value
    }

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
        // #335: fd 1 is the capture pipe now — the log's console echo
        // must go to the saved real stdout, never into the pipe, or
        // every echoed line is captured and logged again forever.
        AppLog.consoleEchoFd = saved
        let readFd = fds[0]
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var pending = ""
            // Fold and cap at the capture point: a chain stuck repeating
            // one line must not flood the log and push the run's own lines
            // out of the record slice and the uploaded log's kept tail.
            // Consecutive duplicates collapse into one summary line, and
            // past `emitCap` lines the rest are counted, not logged.
            var lastLine: String?
            var repeatCount = 0
            var emitted = 0
            var dropped = 0
            let emitCap = 500
            func emit(_ text: String) {
                if emitted < emitCap {
                    log("[内核链] \(text)")
                    emitted += 1
                } else {
                    dropped += 1
                }
            }
            func flushRepeats() {
                if repeatCount > 0, let lastLine {
                    emit("（上一行重复 \(repeatCount) 次，已折叠：\(lastLine.prefix(80))）")
                    repeatCount = 0
                }
            }
            func handle(_ line: String) {
                if line == lastLine {
                    repeatCount += 1
                    return
                }
                flushRepeats()
                lastLine = line
                emit(line)
            }
            func flushPending() {
                while let idx = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<idx])
                    pending = String(pending[pending.index(after: idx)...])
                    if !line.isEmpty { handle(line) }
                }
            }
            while true {
                let count = read(readFd, &buffer, buffer.count)
                if count <= 0 { break }
                pending += String(decoding: buffer[0..<count], as: UTF8.self)
                flushPending()
            }
            if !pending.isEmpty { handle(pending) }
            flushRepeats()
            if dropped > 0 {
                log("[内核链] （链输出超过 \(emitCap) 行上限，已省略 \(dropped) 行）")
            }
            close(readFd)
        }
        return saved
    }

    /// Put fd 1 back. The chain may still be running after a timeout; the
    /// pipe's read end is therefore left to its reader, which sees EOF as
    /// soon as fd 1 stops pointing at the pipe.
    private static func stopStdoutCapture(saved: Int32) {
        AppLog.consoleEchoFd = nil
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
    }

    // MARK: - Write-read-delete

    private struct WriteReadDeleteResult {
        let path: String?
        let failure: String?
    }

    private static func writeReadDelete(in directory: String,
                                         log: (String) -> Void) -> WriteReadDeleteResult {
        let name = ".drift-kernel-probe-\(getpid())-\(UUID().uuidString)"
        let path = (directory as NSString).appendingPathComponent(name)
        let expected: UInt8 = 0x31

        log("[内核探针] 自检子阶段：open(O_CREAT|O_EXCL)")
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

        log("[内核探针] 自检子阶段：write 1 byte")
        var byte = expected
        let written = withUnsafeBytes(of: &byte) { write(fd, $0.baseAddress, 1) }
        // Capture errno now: close()/unlink() below would replace it, and a
        // failure report carrying their errno instead of the write's misleads
        // whoever reads the log later.
        let writeErrno = errno
        if written == 1, lseek(fd, 0, SEEK_SET) == 0 {
            log("[内核探针] 自检子阶段：read back")
            var got: UInt8 = 0
            let readCount = withUnsafeMutableBytes(of: &got) { read(fd, $0.baseAddress, 1) }
            readBack = readCount == 1 && got == expected
            wrote = true
        }
        close(fd)
        log("[内核探针] 自检子阶段：unlink 临时文件")
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

    /// Cached path → shared pathleak → metadata identity → store-directory
    /// fallback. The later probe stage performs a create/write/read/delete
    /// test in the returned store. `timedOut` distinguishes a deadline from
    /// a completed negative scan.
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
            log("[容器定位] 缓存快照检查开始：\(known.count) 个已知容器路径")
            let cacheStarted = Date()
            for (index, container) in known.enumerated() where isApplicationContainerPath(container) {
                log("[容器定位] 缓存候选 \(index + 1)/\(known.count)：检查商店目录")
                if let store = storeIn(container: container) {
                    log(String(format: "[容器定位] 缓存命中，耗时 %.2f 秒", Date().timeIntervalSince(cacheStarted)))
                    log("[内核探针] 5/5 找法一命中：\(container)")
                    PosterBoardContainerLocator.clearProgress()
                    return (LocatedStore(container: container,
                                         store: store,
                                         structureVersions: structureVersions(in: store)), false)
                }
            }
            log(String(format: "[容器定位] 缓存快照未命中，耗时 %.2f 秒", Date().timeIntervalSince(cacheStarted)))
            log("[内核探针] 5/5 找法一没有命中")
        } else {
            log("[容器定位] 缓存快照为空：没有可复用的容器路径")
        }

        // LaunchServices CSStore is a second, independent cold-start source.
        // It does not replace the kernel-side store validation or write/read/delete
        // self-test below; the resolved path must still pass storeIn(container:).
        if !pastDeadline(deadline) {
            log("[容器定位] 尝试 LaunchServices CSStore 解析 PosterBoard 容器")
            if let container = WorseQueryEscape.launchServicesContainerPath(bundleID: posterBoardBundleID),
               isApplicationContainerPath(container),
               let store = storeIn(container: container) {
                log("[内核探针] CSStore 命中 PosterBoard 容器：\\(container)")
                PosterBoardLocal.cachedContainer = container
                PosterBoardContainerLocator.clearProgress()
                return (LocatedStore(container: container, store: store,
                                     structureVersions: structureVersions(in: store)), false)
            }
            if pastDeadline(deadline) { return (nil, true) }
            log("[容器定位] CSStore 未命中或商店目录核验失败，继续现有 pathleak 流程")
        }

        // Match 本机直刷's cold-start locator: segmented pathleak discovery
        // finds direct child container paths without first enumerating the
        // entire Applications directory. The kernel backend validates each
        // candidate by checking PosterBoard's real store directory.
        log("[容器定位] 开始 pathleak 分段枚举")
        let pathleakStarted = Date()
        let pathleak = PosterBoardContainerLocator.scanPathleak(
            deadline: deadline,
            log: log
        ) { candidates, segment in
            for candidate in candidates where isApplicationContainerPath(candidate) {
                if storeIn(container: candidate) != nil {
                    log("[内核探针] pathleak 第 \(segment) 段命中 PosterBoard 容器")
                    PosterBoardLocal.cachedContainer = candidate
                    return candidate
                }
            }
            return nil
        }
        log(String(format: "[容器定位] pathleak 返回：available=%@，timedOut=%@，segments=%d，candidates=%d，耗时 %.2f 秒",
                   pathleak.available ? "true" : "false",
                   pathleak.timedOut ? "true" : "false",
                   pathleak.segments, pathleak.candidates,
                   Date().timeIntervalSince(pathleakStarted)))
        if pathleak.timedOut {
            return (nil, true)
        }
        if let container = pathleak.foundPath, let store = storeIn(container: container) {
            log("[内核探针] pathleak 命中：停在第 \(pathleak.segments) 段，"
                + "扫描 \(pathleak.scannedInodes)/\(pathleak.maxInode) 个 inode，"
                + "候选 \(pathleak.candidates) 个，枚举耗时 "
                + String(format: "%.0f ms", pathleak.enumerationMilliseconds))
            PosterBoardContainerLocator.clearProgress()
            return (LocatedStore(container: container, store: store,
                                 structureVersions: structureVersions(in: store)), false)
        }
        if pathleak.available {
            log("[内核探针] pathleak 未命中：扫描 \(pathleak.scannedInodes)/\(pathleak.maxInode) 个 inode，"
                + "候选 \(pathleak.candidates) 个，枚举耗时 "
                + String(format: "%.0f ms", pathleak.enumerationMilliseconds))
        }

        log("[容器定位] pathleak 未命中，开始读取 Applications 根目录")
        let directoryStarted = Date()
        guard let entries = try? manager.contentsOfDirectory(atPath: applicationsRoot) else {
            log(String(format: "[容器定位] Applications 根目录读取失败，耗时 %.2f 秒", Date().timeIntervalSince(directoryStarted)))
            log("[内核探针] 5/5 列不出 \(applicationsRoot)")
            return (nil, false)
        }
        log(String(format: "[容器定位] Applications 根目录读取完成：%d 个条目，耗时 %.2f 秒",
                   entries.count, Date().timeIntervalSince(directoryStarted)))
        log("[内核探针] 5/5 应用数据容器 \(entries.count) 个，开始找法二、找法三")

        // Level 2 — the container-manager query: read each container's own
        // metadata and match PosterBoard's bundle identifier.
        for (index, entry) in entries.enumerated() where UUID(uuidString: entry) != nil {
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
                PosterBoardLocal.cachedContainer = container
                PosterBoardContainerLocator.clearProgress()
                return (LocatedStore(container: container,
                                     store: store,
                                     structureVersions: structureVersions(in: store)), false)
            }
        }
        log("[内核探针] 5/5 找法二没有命中")

        // Level 3 — the metadata scan fallback: look for the store directory
        // itself in every container.
        for entry in entries where UUID(uuidString: entry) != nil {
            if pastDeadline(deadline) {
                log("[内核探针] 5/5 找法三因超过总时限停下")
                return (nil, true)
            }
            let container = (applicationsRoot as NSString).appendingPathComponent(entry)
            if let store = storeIn(container: container) {
                log("[内核探针] 5/5 找法三命中（商店目录扫描）：\(container)")
                PosterBoardLocal.cachedContainer = container
                PosterBoardContainerLocator.clearProgress()
                return (LocatedStore(container: container,
                                     store: store,
                                     structureVersions: structureVersions(in: store)), false)
            }
        }
        log("[内核探针] 5/5 找法三没有命中")
        return (nil, false)
    }


    private static func isApplicationContainerPath(_ path: String) -> Bool {
        let prefix = applicationsRoot + "/"
        guard path.hasPrefix(prefix) else { return false }
        return UUID(uuidString: (path as NSString).lastPathComponent) != nil
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
