import Foundation
import SwiftUI
import Minimuxer

/// Drift's connection session: the one owner of the pairing record, the
/// minimuxer core's start, device-identity reads and wallpaper runs.
///
/// In the base app these jobs lived on the (single, all-features) home page.
/// Drift's four pages all need pieces of them — the wallpaper page runs the
/// apply, Settings manages the pairing record, every page shows connection
/// state — so they live here instead, with the same behaviour the base app
/// shipped: same start sequence, same bounded identity poll, same run
/// bookkeeping. Nothing about the wire changes.
@MainActor
final class DriftSession: ObservableObject {
    static let shared = DriftSession()

    /// The pairing record, persisted exactly where the base app persisted it.
    @Published private(set) var pairingRaw: String?
    /// A user-presentable connection/run problem, shown as a banner by the
    /// shell. Cleared by the next successful step.
    @Published var errorText: String? {
        willSet { errorRetryAction = nil }
    }
    @Published var errorRetryAction: (() -> Void)?
    /// True while a wallpaper run is in flight.
    @Published private(set) var running = false
    /// The full-screen "flashing" cover (collection #150, corrected
    /// 2026-11-11): Grace's requirement is that the cover appears the
    /// moment the user taps Apply — before the re-judgement, the identity
    /// refresh and the container search — and stays up for every channel
    /// until the run is done. `running` flips too late for that (it waits
    /// for the funnel's checks), so the cover has its own flag: the home
    /// view raises it on tap, `run` raises it on entry as a backstop for
    /// other callers, and both clear it when the work ends.
    @Published var flashCover = false

    /// A one-line stage hint shown under the flashing cover. The local
    /// channel's first container search can take a while, and the cover is
    /// the only place the user can see where the run is.
    @Published var flashStage: String?

    /// Which full-screen cover is up, when it is not the flashing one
    /// (collection round 2026-11-12, Grace): restarting PosterBoard and
    /// repairing a pack get the same treatment as flashing — a blocking
    /// card with a progress bar and no text under the bar. The respring
    /// case exists for the post-delete activation (#212): only the two
    /// tunnel methods' post-delete actions are covered; the local
    /// method's swipe-close has nothing in-app to cover.
    @Published var cover: CoverKind?
    /// The up cover's progress, 0...1, or nil while no phase has
    /// reported. Fed by the engine's real run progress while flashing,
    /// and by phase marks for restart / repair.
    @Published var coverProgress: Double?
    /// Whether the flash cover may show that progress as a bar. The
    /// flash cover is bare by Grace's 2026-11-15 call — spinner and
    /// 「正在刷入」only, every channel — with one exception (build 4,
    /// 2026-11-21): a restore dry run can hold the cover for minutes
    /// on its pull, so its run raises this and the cover shows the
    /// pull's own percent as a real bar. Set by the funnel for the
    /// `.backup` mode only, cleared with the cover.
    @Published var coverShowsProgress = false

    enum CoverKind {
        case restartingPosterBoard, respringing, repairing
        var title: String {
            switch self {
            case .restartingPosterBoard: return "正在重启 PosterBoard"
            case .respringing: return "正在注销"
            case .repairing: return "正在修复"
            }
        }
    }

    /// A plain explanation the user asked to see — the restore seal's
    /// notice, a sealed method's reason, the post-import problem list.
    /// Shown in its own alert (#206: the apply card's status line no
    /// longer carries these).
    @Published var noticeText: String?
    @Published var noticeTitle: String = "提示"

    /// How the last finished run took effect, when it used the in-process
    /// route. The home page shows a manual-respring button from this.
    @Published private(set) var lastEffect: PosterBoardEffect?

    /// The restore dry run a one-flow apply is currently writing back
    /// (Alpha line). Set by the funnel the moment a restore dry run
    /// passes its checks, held only for the span of the immediate
    /// write-back inside the same run, and cleared on either outcome;
    /// a non-restore run also clears it as a safety net. Nothing waits
    /// on it any more — there is no parked report and no dry-run card.
    @Published private(set) var pendingRestoreDryRun: RestoreDryRunReport?

    /// A finished restore write-back is waiting on the user's answer
    /// to the restart offer (Alpha line, Grace, 2026-11-21): the root
    /// view shows「刷入成功，需要重启生效，是否重启？」while this is
    /// set; 确定 sends the diagnostics-relay restart, 取消 leaves the
    /// device as it is (a manual restart does the same job).
    @Published var restoreRestartOffer = false

    private var didBootstrap = false
    private static let startLock = NSLock()
    private static var startInFlight = false

    /// True once minimuxer has answered its readiness poll in this process.
    /// `ensureCoreStarted()` keys off it: a start that failed because the
    /// tunnel was not up yet is retried when the tunnel monitor reports the
    /// tunnel ready, instead of the session sitting dead until relaunch.
    private var coreReady = false

    /// The pairing-record watch's loop, while it runs.
    private var pairingWatch: Task<Void, Never>?

    private init() {}

    var paired: Bool { pairingRaw != nil }

    /// Present an error with an optional user-triggered retry action.
    func presentError(_ message: String, retry: (() -> Void)? = nil) {
        errorText = message
        errorRetryAction = retry
    }

    func dismissError() {
        errorText = nil
        errorRetryAction = nil
    }

    /// The 确定 half of the post-restore restart offer: ask the
    /// device to restart itself through the diagnostics relay. A
    /// refusal lands as an ordinary error — the flash already
    /// succeeded, and a manual restart does the same job.
    func restartDeviceAfterRestore() async {
        restoreRestartOffer = false
        do {
            try await DriftEngine.shared.restartDevice()
        } catch {
            presentError("重启命令没发出去：\(error.localizedDescription) 壁纸已经刷入，手动重启一次也能生效。")
        }
    }

    // MARK: - Launch

    /// Wire the engine's log into the run log, restore the pairing record and
    /// start the core. Idempotent: safe to call from every appearance.
    func bootstrap() {
        DriftEngine.shared.onLog = { line in RunLog.shared.append(line) }
        // Coalesced (cleanup round, 2026-11-13): the engine reports
        // per descriptor; the cover reads at most ten updates a second.
        let coverProgressCoalescer = ProgressCoalescer<Double?>(interval: 0.1) { value in
            DriftSession.shared.coverProgress = value
        }
        DriftEngine.shared.onProgress = { percent in
            let value = percent.isNaN ? nil : percent / 100
            Task { @MainActor in coverProgressCoalescer.offer(value) }
        }
        guard !didBootstrap else { return }
        didBootstrap = true
        let autoImportDisabled = UserDefaults.standard.bool(forKey: PairingRecord.Key.autoImportDisabled)
        if !autoImportDisabled, reimportPairingFile() {
            startMinimuxer()
        }
        Task { await refreshIdentity() }
    }

    // MARK: - Pairing record

    /// Make sure a usable pairing record exists, and report whether one does.
    /// Precedence (the base app's, kept): the file on disk, then the persisted
    /// copy, then a record the installer embedded. Each candidate is shape-
    /// validated before use, so a corrupt file falls through instead of
    /// blocking the launch.
    @discardableResult
    func reimportPairingFile() -> Bool {
        let dest = AppPaths.pairingFile
        let stored = UserDefaults.standard.string(forKey: PairingRecord.Key.stored)
        let embedded = Bundle.main.object(forInfoDictionaryKey: "ALTPairingFile") as? String
        let candidates: [(source: String, raw: String?)] = [
            ("Documents/pairingfile.plist", try? String(contentsOf: dest, encoding: .utf8)),
            // Pre-rename installs paired into the lockdown-era filename; it is
            // migrated to `pairingfile.plist` by the write-back below.
            ("Documents/pairingfile.mobiledevicepairing (legacy)", try? String(contentsOf: AppPaths.legacyPairingFile, encoding: .utf8)),
            ("stored PairingFile", stored),
            ("Info.plist ALTPairingFile", embedded),
        ]
        for (source, rawOpt) in candidates {
            guard let raw = rawOpt?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            guard PairingRecord.usable(raw) else {
                DriftEngine.shared.log("pairing record rejected (\(source)): \(PairingRecord.sourceLabel(raw))")
                continue
            }
            let onDisk = (try? String(contentsOf: dest, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if onDisk != raw {
                do {
                    try raw.write(to: dest, atomically: true, encoding: .utf8)
                    DriftEngine.shared.log("pairing record re-imported from \(source) into \(dest.lastPathComponent) (\(PairingRecord.sourceLabel(raw)))")
                } catch {
                    DriftEngine.shared.log("pairing record found (\(source)) but could not be written to Documents: \(error.localizedDescription)")
                }
            }
            pairingRaw = raw
            return true
        }
        pairingRaw = nil
        return false
    }

    /// Import a pairing record the user picked. The validate → write → read
    /// back contract is `PairingRecord`'s; what stays here is the state, the
    /// log line and starting the core.
    func importPairing(from url: URL) throws {
        let record = try PairingRecord.accept(contentsOf: url)
        // A successful import answers an earlier reset, so the flag goes back
        // down — otherwise every later launch would skip the automatic load.
        UserDefaults.standard.set(false, forKey: PairingRecord.Key.autoImportDisabled)
        pairingRaw = record
        errorText = nil
        DriftEngine.shared.log("pairing file imported: \(PairingRecord.sourceLabel(record)) "
            + "→ \(AppPaths.pairingFile.lastPathComponent), \(record.count) bytes, read back OK")
        startMinimuxer()
        Task { await refreshIdentity() }
    }

    /// Forget the pairing record in memory and in the persisted copy. The
    /// file in Documents is deliberately left alone — it may be the user's
    /// only copy; the persisted flag is what makes the reset stick across
    /// launches instead of deleting the file.
    func resetPairing() {
        pairingRaw = nil
        UserDefaults.standard.removeObject(forKey: PairingRecord.Key.stored)
        UserDefaults.standard.set(true, forKey: PairingRecord.Key.autoImportDisabled)
        RunLog.shared.clear()
        DriftEngine.shared.log("pairing reset: record cleared from memory and storage; "
            + "\(AppPaths.pairingFile.lastPathComponent) kept on disk, automatic import "
            + "disabled until the next import")
    }

    /// Accept a pairing record that arrived as raw plist text (wireless
    /// self-pairing saves through the same disk contract as a file import).
    func adoptPairingFromDisk() {
        if reimportPairingFile() {
            errorText = nil
            startMinimuxer()
            Task { await refreshIdentity() }
        }
    }

    /// Record that the core answered its readiness poll, and take the
    /// identity read that was waiting on it.
    func noteCoreReady() async {
        coreReady = true
        await refreshIdentity()
    }

    /// Start the core if there is a record and it has never come up — the
    /// tunnel monitor calls this when the tunnel turns ready, which is how
    /// "opened LocalDevVPN after Drift" recovers on its own.
    func ensureCoreStarted() {
        guard paired, !coreReady else { return }
        DriftEngine.shared.log("tunnel is ready and the core is not — starting minimuxer now")
        startMinimuxer()
    }

    // MARK: - Pairing-record watch

    /// Watch the canonical path for a record arriving outside an import on
    /// the page the user is looking at (Grace, 2026-11-09: 配对记录也没有
    /// 实时检测）. Wireless self-pairing writes the file from a sheet, a
    /// record can be copied into Documents, a re-pair replaces it — until
    /// this watch, none of that moved `pairingRaw` until the next launch.
    ///
    /// The watch only ever **adopts**: it never un-pairs. A record the user
    /// deleted on purpose stays deleted — the reset's
    /// `autoImportDisabled` flag is honoured here exactly as at launch —
    /// and a file vanishing mid-session does not strand a core that is
    /// already running on the in-memory copy.
    func startPairingWatch() {
        guard pairingWatch == nil else { return }
        pairingWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.noticePairingRecordOnDisk()
            }
        }
    }

    func stopPairingWatch() {
        pairingWatch?.cancel()
        pairingWatch = nil
    }

    private func noticePairingRecordOnDisk() {
        guard !running else { return }
        guard !UserDefaults.standard.bool(forKey: PairingRecord.Key.autoImportDisabled) else { return }
        guard let disk = PairingRecord.onDisk(), disk != pairingRaw else { return }
        DriftEngine.shared.log("pairing record noticed on disk — adopting it "
            + "(\(PairingRecord.sourceLabel(disk)))")
        adoptPairingFromDisk()
    }

    // MARK: - minimuxer start (ported sequence)

    func startMinimuxer() {
        guard let pairingRaw else { return }
        Self.startLock.lock()
        if Self.startInFlight {
            Self.startLock.unlock()
            DriftEngine.shared.log("minimuxer start already in progress — ignoring this request")
            return
        }
        Self.startInFlight = true
        Self.startLock.unlock()

        let docs = URL.documents.path(percentEncoded: false)
        DispatchQueue.global(qos: .userInitiated).async(execute: DispatchWorkItem { [pairingRaw] in
            defer {
                Self.startLock.lock()
                Self.startInFlight = false
                Self.startLock.unlock()
            }
            // Probe the tunnel first so the RSD handshake can reach the
            // device before the core starts.
            let tunnelStage = StageTimer("tunnel probe")
            guard Tunnel.waitForTunnel(log: { line in DriftEngine.shared.log(line) }) else {
                tunnelStage.done("FAILED")
                // Collection #134 (Grace, 2026-11-11): a background probe
                // failing must not interrupt the user with a modal. The
                // method rows already say the tunnel channels are
                // unavailable and why; errors only pop for actions the
                // user started. This stays in the log for diagnostics.
                DriftEngine.shared.log("tunnel probe: \(Tunnel.peerIP):\(Tunnel.servicePort) unreachable — background start skipped (not shown to the user)")
                return
            }
            tunnelStage.done("reachable")
            Task {
                do {
                    let minimuxer = Minimuxer.shared()
                    // File logging has to be enabled before `setLogging`:
                    // that call snapshots the flag when it builds the sink.
                    DriftEngine.shared.enableRustFileLogging()
                    let core = minimuxer.core
                    try await core.setLogging(true)
                    try await core.setDeviceProbeTimeout(3000)
                    // The createTunnel-time values are cached natively; the
                    // Swift `Tunnel` store stays the source of truth and each
                    // report is logged, because a wrong peer address strands
                    // the createTunnel step silently otherwise.
                    await core.bindConnectionConfig(ConnectionConfigBinding(
                        setTunnelIfaceIp: { value in Tunnel.noteReported { $0.ifaceIP = value } },
                        setTunnelPeerIp: { value in Tunnel.noteReported { $0.peerIP = value } },
                        setTunnelPeerSubnetMask: { value in Tunnel.noteReported { $0.peerSubnetMask = value } },
                        setTunnelPeerReachable: { value in Tunnel.noteReported { $0.peerReachable = value } },
                        setTunnelIfaceSubnetMask: { value in Tunnel.noteReported { $0.ifaceSubnetMask = value } },
                        getRemoteServerIp: { "" },
                        setRemoteReachable: { _ in },
                        // Use the same peer as the pre-start probe, even when
                        // LocalDevVPN's routes cannot be auto-discovered.
                        getOverrideTunnelPeerIp: { Tunnel.peerIP },
                        setOverrideTunnelPeerReachable: { value in Tunnel.noteReported { $0.overridePeerReachable = value } },
                        getConnectionMode: { .localVPN }
                    ))
                    // Diagnostic only, no verdict attached (a lockdown-only
                    // key rule would misread the valid .rppairing record an
                    // iOS 17+ device uses); start() gives the real verdict.
                    if let keys = PairingRecord.topLevelKeys(pairingRaw) {
                        DriftEngine.shared.log("pairing file top-level keys: \(keys.isEmpty ? "(empty)" : keys.sorted().joined(separator: ", "))")
                    } else {
                        DriftEngine.shared.log("pairing file: NOT a parseable plist")
                    }
                    try await core.start(pairingFile: pairingRaw, mountPath: docs)

                    // Bounded readiness poll, backing off to 2 s, 20 s cap.
                    let readyStage = StageTimer("minimuxer readiness")
                    var isReady = false
                    var readinessFailure: String?
                    var delay: UInt64 = 300_000_000
                    var poll = 0
                    let deadline = Date().addingTimeInterval(20)
                    while !isReady, Date() < deadline {
                        poll += 1
                        let readiness = await core.isReady()
                        if case .success(true) = readiness { isReady = true; break }
                        if case .failure(let error) = readiness {
                            readinessFailure = core.describeError(error)
                        }
                        try await Task.sleep(nanoseconds: delay)
                        delay = min(delay * 2, 2_000_000_000)
                    }
                    readyStage.done("ready=\(isReady) after \(poll) poll(s)")
                    DriftEngine.shared.log("minimuxer started. ready=\(isReady)")
                    if !isReady {
                        let reason = readinessFailure ?? "未知原因"
                        let tail = RustLog.tail()
                        DriftEngine.shared.log("minimuxer readiness failed: \(reason)")
                        DriftEngine.shared.log("minimuxer.log tail:\n\(tail)")
                        // Same rule as the tunnel probe above: background
                        // startup trouble is logged, not popped.
                    } else {
                        await DriftSession.shared.noteCoreReady()
                    }
                } catch {
                    let tail = RustLog.tail()
                    DriftEngine.shared.log("minimuxer.log tail:\n\(tail)")
                    DriftEngine.shared.log("minimuxer start failed: \(error.localizedDescription)")
                }
            }
        })
    }

    // MARK: - Device identity

    /// Read the device identity with the base app's bounded poll and publish
    /// it to the monitor every page observes. An empty identity is not
    /// harmless (it parses to major 0 and takes the wrong engine branch), so
    /// a first `.unknown` is retried for up to 15 s before being published.
    func refreshIdentity() async {
        guard paired else { return }
        var read = await DeviceIdentity.read()
        if read == .unknown {
            let deadline = Date().addingTimeInterval(15)
            var attempt = 0
            var delay: UInt64 = 300_000_000
            while read == .unknown, Date() < deadline {
                attempt += 1
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 2_000_000_000)
                read = await DeviceIdentity.read()
            }
            if read != .unknown {
                DriftEngine.shared.log("device identity: lockdownd answered on attempt "
                    + "\(attempt + 1), after the first read raced minimuxer's start")
            }
        }
        await DeviceIdentityMonitor.shared.publish(read)
    }

    // MARK: - Wallpaper runs

    func cancelRun() { DriftEngine.shared.requestCancel() }

    /// Restart PosterBoard under its cover (#201): the bar sits on the
    /// first of the two phases (kill → relaunch) while the attempt is
    /// in flight and completes when the result lands.
    func restartPosterBoardUnderCover() async -> (confirmed: Bool, status: PosterRefresh.Status) {
        cover = .restartingPosterBoard
        coverProgress = 0.5
        defer { cover = nil; coverProgress = nil }
        let result = await PosterRefresh.attempt(pairingPath: AppPaths.pairingFile.path)
        coverProgress = 1
        try? await Task.sleep(nanoseconds: 350_000_000)
        return result
    }

    /// Trigger the respring under a cover (#212, post-delete tunnel
    /// activations only). The respring itself ends the UI moments
    /// later; the cover is for the wait in between.
    @discardableResult
    func respringUnderCover() -> Bool {
        cover = .respringing
        coverProgress = nil
        let triggered = NeoSpring.trigger()
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if cover == .respringing { cover = nil }
        }
        return triggered
    }

    /// Run one wallpaper apply in the channel the judgement chose and record
    /// the four facts separately: the method the user picked, the channel the
    /// run actually used, how it takes effect, and the store-verification
    /// grade. None of those may stand in for another.
    func run(selection: PosterBoardSelection, mode: PosterBoardApplyMode,
             pick: DriftMethodPick,
             identity: DeviceIdentity) async -> (ok: Bool, message: String, effect: PosterBoardEffect?) {
        // An abandoned run (its calls walked away from) does not block a
        // successor — `beginRun` inside the engine makes the final call.
        guard !InFlightCall.shared.hasLiveRun else {
            return (false, "已有一轮刷入正在进行", nil)
        }
        flashCover = true
        flashStage = (mode == .worseQuery) ? "正在定位壁纸商店，第一次会慢一些" : nil
        coverShowsProgress = (mode == .backup)
        defer { flashCover = false; flashStage = nil; coverShowsProgress = false }
        lastEffect = nil
        // Feedback #30: the funnel refuses a restore run while the gate
        // is closed, even if a caller forgot to consult it — judgement,
        // reset and video all arrive here, so this is the one place a
        // restore run cannot slip past.
        if mode == .backup && !DriftRestoreGate.isEnabled {
            DriftEngine.shared.log("run refused: restore route is suspended (feedback #30)")
            return (false, "暂不可用", nil)
        }
        if mode != .backup, pendingRestoreDryRun != nil {
            pendingRestoreDryRun = nil
            DriftEngine.shared.discardRestoreDryRun()
        }
        let isResetSelection = selection.fullReset || !selection.resetModes.isEmpty
        let selectedLabel = isResetSelection ? "重置" : pick.label
        // Collection #143: flashing the same pack twice stacked copies in
        // the store that nobody could tell apart. If a receipt for one of
        // the selected packs still verifies as in-store, refuse and say
        // where to remove the old copy. Only a confirmed in-store receipt
        // blocks — absent or unverifiable ones let the run proceed.
        if mode != .backup, !isResetSelection {
            let names = Set(selection.tendies.map(\.name))
            let receipts = PosterBoardLocalReceipts.load().filter { names.contains($0.pack) }
            if !receipts.isEmpty {
                let states = await PosterBoardManagement.reconcile(
                    receipts,
                    tunnelReady: TunnelMonitor.shared.status == .ready,
                    log: { DriftEngine.shared.log($0) })
                let dup = Set(receipts.filter { states[$0.id] == .inStore }.map(\.pack))
                if let first = selection.tendies.first(where: { dup.contains($0.name) }) {
                    return (false, "「\(first.name)」已经刷过一份了，还在壁纸商店里。先在管理页删掉旧的，再刷这个包。", nil)
                }
            }
        }
        running = true
        RunLog.shared.clear()
        defer { running = false }
        do {
            try await DriftEngine.shared.applyWallpapers(
                selection: selection,
                mode: mode,
                deviceVersion: identity.version)
            if mode == .backup, let dryRun = DriftEngine.shared.lastRestoreDryRun {
                // One flow (Grace, 2026-11-21): a restore apply is the
                // whole route in a single run — the dry run's checks
                // pass, then the write-back follows immediately, with
                // no parked report and no second confirmation. The
                // machine gates are unchanged: the audit already gated
                // the dry run, and the service re-verifies the dry-run
                // fingerprint inside the write-back before restoring. The outcome earns
                // the run's single history entry, recorded here.
                pendingRestoreDryRun = dryRun
                flashStage = "正在写回，期间不要切后台或锁屏"
                DriftEngine.shared.log("恢复刷：干跑通过（指纹 \(dryRun.fingerprintShort)），直接写回")
                do {
                    try await DriftEngine.shared.writeBackRestore()
                    pendingRestoreDryRun = nil
                    ApplyHistory.record(mode: "恢复刷",
                                        success: true,
                                        device: identity.describe,
                                        model: identity.productType, ios: identity.version,
                                        effect: "重启生效",
                                        channel: nil,
                                        packName: dryRun.packNames.joined(separator: "、"),
                                        packFiles: dryRun.packFiles,
                                        logSliceText: RunLog.shared.recordSnapshot())
                    errorText = nil
                    // The completion itself is the restart offer
                    // (Grace, 2026-11-21): the root view asks「刷入
                    // 成功，需要重启生效，是否重启？」while the page's
                    // status line just says it succeeded. Counts and
                    // the fingerprint live in the log and the history
                    // entry, not in the user's face.
                    restoreRestartOffer = true
                    return (true, "刷入成功", nil)
                } catch {
                    pendingRestoreDryRun = nil
                    let message = error.localizedDescription
                    DriftEngine.shared.log("恢复刷写回失败：\(message)")
                    ApplyHistory.record(mode: "恢复刷",
                                        success: false, error: message,
                                        device: identity.describe,
                                        model: identity.productType, ios: identity.version,
                                        packName: dryRun.packNames.joined(separator: "、"),
                                        packFiles: dryRun.packFiles,
                                        logSliceText: RunLog.shared.recordSnapshot())
                    return (false, message, nil)
                }
            }
            let effect = DriftEngine.shared.lastPosterBoardEffect
            lastEffect = effect
            let verification = DriftEngine.shared.lastVerification
            let providers = verification.map {
                Set($0.expected.map { String($0.split(separator: "/").first ?? "") })
                    .sorted().joined(separator: "、")
            }
            let iosVersion = (mode == .worseQuery) ? WorseQueryEscape.processVersion
                : (identity.version.isEmpty ? WorseQueryEscape.processVersion : identity.version)
            ApplyHistory.record(mode: selectedLabel,
                                success: true,
                                device: identity.describe,
                                model: identity.productType, ios: iosVersion,
                                effect: effect?.historyLabel,
                                channel: mode == .backup ? nil : mode.shortTitle,
                                provider: providers,
                                verification: verification?.summary,
                                packName: selection.tendies.map(\.name).joined(separator: "、"), packFiles: selection.tendies.map { $0.url.lastPathComponent }, logSliceText: RunLog.shared.recordSnapshot())
            // The reset flags are one-shot; the calling page clears its own
            // selection on success (this session only ever holds a copy).
            errorText = nil
            switch mode {
            case .worseQuery:
                let opened = await MainActor.run { PosterBoardLaunch.open() }
                let hint = opened
                    ? "已打开 PosterBoard 以刷新集合，请在应用切换器里上滑结束它，然后检查锁定屏幕壁纸选择器。"
                    : "请打开锁定屏幕壁纸选择器来刷新 PosterBoard；如果壁纸未出现，请在应用切换器里上滑结束 PosterBoard 后重试。"
                if let effect {
                    return (true, "\(effect.headline)。\(hint)", effect)
                }
                return (true, "刷入完成，壁纸已写入。\(hint)", nil)
            case .direct:
                if let verification, verification.allConfirmed {
                    return (true, "刷入完成：已核验，\(verification.confirmed.count) 张描述符都在设备商店里。\(effect?.detail ?? "") ", effect)
                }
                if let verification {
                    return (true, "已写入、未确认显示：\(verification.summary)。文件已送达，但设备商店没有确认收录——先去壁纸库看一眼；没有的话把日志包发出来排查", effect)
                }
                return (true, "刷入完成：\(effect?.detail ?? "免注销生效")", effect)
            case .airlift:
                if let verification, verification.allConfirmed {
                    return (true, "刷入完成：已核验，\(verification.confirmed.count) 张描述符都在设备商店里，设备将注销生效。", effect)
                }
                if let verification {
                    return (true, "已写入、未确认显示：\(verification.summary)。文件已送达，但设备商店没有确认收录——先去壁纸库看一眼；没有的话把日志包发出来排查", effect)
                }
                return (true, "刷入完成，设备将注销生效。", effect)
            case .backup:
                return (true, "刷入完成，设备将重启生效", nil)
            }
        } catch {
            if let failure = error as? TransportFailure, failure.isCancellation {
                DriftEngine.shared.log("run cancelled")
                let iosVersion = (mode == .worseQuery) ? WorseQueryEscape.processVersion
                : (identity.version.isEmpty ? WorseQueryEscape.processVersion : identity.version)
                ApplyHistory.record(mode: selectedLabel, success: false, error: "已取消",
                                    device: identity.describe,
                                    model: identity.productType, ios: iosVersion,
                                    packName: selection.tendies.map(\.name).joined(separator: "、"), packFiles: selection.tendies.map { $0.url.lastPathComponent }, logSliceText: RunLog.shared.recordSnapshot())
                return (false, "刷入已取消", nil)
            }
            DriftEngine.shared.log("posterboard apply failed: \(error.localizedDescription)")
            let message = Self.flashFailureMessage(error: error, selection: selection)
            let iosVersion = (mode == .worseQuery) ? WorseQueryEscape.processVersion
                : (identity.version.isEmpty ? WorseQueryEscape.processVersion : identity.version)
            ApplyHistory.record(mode: selectedLabel, success: false, error: message,
                                device: identity.describe,
                                model: identity.productType, ios: iosVersion,
                                packName: selection.tendies.map(\.name).joined(separator: "、"), packFiles: selection.tendies.map { $0.url.lastPathComponent }, logSliceText: RunLog.shared.recordSnapshot())
            return (false, message, nil)
        }
    }

    /// How far through its five steps a probe log line says the probe
    /// is, as a 0...1 fraction — the same step markers the probe's own
    /// cover-stage translation keys off. Nil when the line carries no
    /// step news (the bar simply holds where it is).
    nonisolated private static func kernelProbeFraction(for line: String) -> Double? {
        if line.contains("全部通过") { return 1 }
        if line.contains("5/5") { return 0.85 }
        if line.contains("[容器定位]") || line.contains("4/5") { return 0.7 }
        if line.contains("3/5") { return 0.5 }
        if line.contains("2/5") || line.contains("[内核链]") { return 0.3 }
        if line.contains("1/5") { return 0.12 }
        return nil
    }

    /// 内核直刷：先验证内核后端对真实 PosterBoard store 的
    /// 读写能力，再将已选描述符以暂存 + 校验 + 原子改名方式写入。
    /// 不调用 WorseQuery、App Group 或隧道，也不处理生效刷新。
    func runKernelApply(identity: DeviceIdentity,
                         selection: PosterBoardSelection) async -> (ok: Bool, message: String) {
        guard !InFlightCall.shared.hasLiveRun else {
            return (false, "已有一轮刷入正在进行")
        }
        guard !selection.tendies.isEmpty else {
            return (false, "先在「壁纸包」里选择要写入的 .tendies 包。")
        }
        guard selection.video == nil,
              selection.preGeneratedVideoDirectory == nil,
              !selection.fullReset,
              selection.resetModes.isEmpty else {
            return (false, "内核直刷当前只支持已选的 .tendies 描述文件，不处理视频或重置任务。")
        }
        let premise = KernelDirectPremise.evaluate(version: WorseQueryEscape.processVersion)
        guard premise.ready else {
            return (false, "内核直刷现在用不了：\(premise.reason)。")
        }
        // Refuse container snapshots before the kernel probe: the kernel
        // writer only supports managed descriptor providers, not whole-store
        // packages. Give the user the actionable pack-page correction.
        let containerPacks = selection.tendies.filter { $0.posterType == .container }
        guard containerPacks.isEmpty else {
            let names = containerPacks.map(\.name).joined(separator: "、")
            return (false, "「\(names)」是『容器』类型的包，这类包内核直刷写不了。"
                + "请到壁纸包页把它的出现位置改回『自动』，再刷一次。")
        }

        flashCover = true
        flashStage = "正在验证内核与 PosterBoard 容器读写，期间不要切后台或锁屏"
        // One bar for the whole run, exactly like 本机直刷 (Grace,
        // 2026-11-15): the probe's scan-and-locate phase fills the
        // first 40%, the writer's per-descriptor progress the rest.
        coverProgress = 0
        defer { flashCover = false; flashStage = nil; coverProgress = nil }
        running = true
        lastEffect = nil
        RunLog.shared.clear()
        defer { running = false }

        DriftEngine.shared.log("内核直刷：开始（本机 \(KernelDirectPremise.modelIdentifier)，"
            + "iOS \(WorseQueryEscape.processVersion)，构建 \(WorseQueryEscape.processBuildVersion)，"
            + "设备读数 \(identity.describe)，包数 \(selection.tendies.count)）")

        let report = await KernelDirectProbe.run(log: { line in
            DriftEngine.shared.log(line)
            if let fraction = Self.kernelProbeFraction(for: line) {
                Task { @MainActor in
                    let current = DriftSession.shared.coverProgress ?? 0
                    DriftSession.shared.coverProgress = max(current, fraction * 0.4)
                }
            }
        })
        guard report.passed,
              let containerPath = report.containerPath,
              let storePath = report.storePath else {
            let reason = report.failure ?? "没有取得 PosterBoard 容器路径"
            DriftEngine.shared.log("内核直刷：前置验证失败 —— \(reason)")
            ApplyHistory.record(
                mode: "内核直刷",
                success: false,
                error: reason,
                device: identity.describe,
                model: identity.productType,
                ios: WorseQueryEscape.processVersion,
                packName: selection.tendies.map(\.name).joined(separator: "、"),
                packFiles: selection.tendies.map { $0.url.lastPathComponent },
                logSliceText: RunLog.shared.recordSnapshot()
            )
            return (false, "内核直刷前置验证失败：\(reason) 本次没有写入壁纸。")
        }

        // Do not publish a second copy of a pack that Drift previously
        // flashed and whose every receipt still matches a live store entry.
        // Unreceipted or stale entries remain eligible for a normal write.
        let storeEntries = KernelDirectWriter.enumerateStore(
            storePath: storePath, log: { DriftEngine.shared.log($0) })
        let inStore = Set(storeEntries.map {
            "\($0.provider)/\($0.uuid)/\($0.generation)"
        })
        let journal = PosterBoardLocalReceipts.load()
        var skippedPacks: [String] = []
        var writeSelection = selection
        writeSelection.tendies = selection.tendies.filter { tendie in
            let packReceipts = journal.filter { $0.pack == tendie.name }
            guard !packReceipts.isEmpty,
                  packReceipts.allSatisfy({
                      inStore.contains("\($0.extensionID)/\($0.folderName)/\($0.generation)")
                  }) else { return true }
            skippedPacks.append(tendie.name)
            return false
        }
        if !skippedPacks.isEmpty {
            DriftEngine.shared.log("[内核直刷] 防重复刷：\(skippedPacks.joined(separator: "、")) 已在商店里，本轮跳过")
        }
        if writeSelection.tendies.isEmpty {
            ApplyHistory.record(
                mode: "内核直刷",
                success: true,
                device: identity.describe,
                model: identity.productType,
                ios: WorseQueryEscape.processVersion,
                channel: "内核直刷",
                verification: "选的包都已在商店里，跳过重复刷入",
                packName: selection.tendies.map(\.name).joined(separator: "、"),
                packFiles: selection.tendies.map { $0.url.lastPathComponent },
                logSliceText: RunLog.shared.recordSnapshot()
            )
            DriftEngine.shared.log("[内核直刷] 本轮所有包均已存在，跳过写入")
            return (true, "选的包都已经在壁纸商店里了，不用重复刷。")
        }

        flashStage = "内核读写已建立，正在写入 PosterBoard 描述文件"
        DriftEngine.shared.log("[内核直刷] 探针通过，进入正式写入阶段")
        let writerStarted = Date()
        do {
            let outcome: KernelDirectWriter.Outcome = try await withCheckedThrowingContinuation {
                continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        DriftEngine.shared.log("[内核直刷] KernelDirectWriter.apply() 已启动")
                        let result = try KernelDirectWriter.apply(
                            selection: writeSelection,
                            containerPath: containerPath,
                            storePath: storePath,
                            structureVersions: report.structureVersions,
                            deviceVersion: WorseQueryEscape.processVersion,
                            log: { DriftEngine.shared.log($0) },
                            progress: { value in
                                DriftEngine.shared.log(String(format: "[内核写入] 进度 %.0f%%", value))
                                Task { @MainActor in
                                    let mapped = 0.4 + 0.6 * (value / 100)
                                    let current = DriftSession.shared.coverProgress ?? 0
                                    DriftSession.shared.coverProgress = max(current, mapped)
                                }
                            }
                        )
                        DriftEngine.shared.log(String(format: "[内核直刷] KernelDirectWriter.apply() 返回：%d 个描述符，耗时 %.2f 秒",
                                                       result.installedCount, Date().timeIntervalSince(writerStarted)))
                        continuation.resume(returning: result)
                    } catch {
                        DriftEngine.shared.log("[内核直刷] KernelDirectWriter.apply() 抛出错误：\(error.localizedDescription)")
                        continuation.resume(throwing: error)
                    }
                }
            }
            let verification = outcome.verification
            DriftEngine.shared.log("内核直刷写入完成：\(outcome.installedCount) 个描述符；\(verification.summary)")
            // #319: dump the store through the same kernel session, after the
            // write has settled and before the receipt is recorded, so the
            // comparison lines travel with this run's log. Read-only.
            await Self.dumpKernelStore(container: containerPath,
                                  store: storePath,
                                  generation: verification.structureVersion,
                                  placedFolders: Set(outcome.placed.map(\.folderName)))
            // #334 (Grace, 2026-11-15): kernel writes join the receipt
            // journal like every other channel's, so the management
            // page can list and delete them later. Only the verified
            // placements are recorded.
            PosterBoardLocalReceipts.remember(
                outcome.placed.map {
                    PosterBoardLocalReceipts.KernelWrite(
                        pack: $0.pack, extensionID: $0.extensionID,
                        folderName: $0.folderName, numericID: $0.numericID,
                        parent: $0.parent)
                },
                confirmed: verification.confirmed)
            // Match Drift's existing WorseQuery activation: bring PosterBoard
            // forward so the user can swipe it away from the app switcher.
            // The existing, confirmed NeoSpring action remains available as
            // the alternative from the activation card below.
            // The open attempt (and its result) happens before the history
            // record so both land in this run's record and log slice; the
            // record also carries the channel's effect line like every
            // other channel's records do.
            let opened = await MainActor.run { PosterBoardLaunch.open() }
            DriftEngine.shared.log("[内核直刷] 打开 PosterBoard：\(opened ? "已打开" : "未能打开")")
            ApplyHistory.record(
                mode: "内核直刷",
                success: true,
                device: identity.describe,
                model: identity.productType,
                ios: WorseQueryEscape.processVersion,
                effect: PosterBoardEffectKind.closePosterBoard.historyLabel,
                channel: "内核直刷",
                provider: verification.providersSeen.sorted().joined(separator: "、"),
                verification: verification.summary,
                packName: selection.tendies.map(\.name).joined(separator: "、"),
                packFiles: selection.tendies.map { $0.url.lastPathComponent },
                logSliceText: RunLog.shared.recordSnapshot()
            )
            let refreshHint = opened
                ? "已打开 PosterBoard，请在应用切换器里上滑结束它，它重新打开后就会读到新壁纸。"
                : "请打开锁定屏幕壁纸选择器刷新 PosterBoard，再从应用切换器上滑结束它。"
            let skipNote = skippedPacks.isEmpty ? "" : "另有 \(skippedPacks.count) 个包已在商店里，本轮跳过：\(skippedPacks.joined(separator: "、"))。"
            return (true, "内核直刷已写入 \(outcome.installedCount) 个描述符，写后核验：\(verification.summary)。\(skipNote)\(refreshHint) 也可以使用下方「注销」方式生效。")
        } catch {
            let message = error.localizedDescription
            DriftEngine.shared.log("内核直刷写入失败：\(message)")
            // #319: the order asks for the dump once the probe has passed even
            // when the write itself failed; the kernel session is still here.
            await Self.dumpKernelStore(container: containerPath,
                                  store: storePath,
                                  generation: report.structureVersions.first
                                      ?? PosterBoard.fallbackStructureVersion,
                                  placedFolders: [])
            ApplyHistory.record(
                mode: "内核直刷",
                success: false,
                error: message,
                device: identity.describe,
                model: identity.productType,
                ios: WorseQueryEscape.processVersion,
                packName: selection.tendies.map(\.name).joined(separator: "、"),
                packFiles: selection.tendies.map { $0.url.lastPathComponent },
                logSliceText: RunLog.shared.recordSnapshot()
            )
            return (false, "内核直刷写入失败：\(message)")
        }
    }

    /// #319: run the read-only store dump off the main thread.
    private static func dumpKernelStore(container: String,
                                        store: String,
                                        generation: Int,
                                        placedFolders: Set<String>) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                _ = KernelDirectStoreDump.run(
                    container: container,
                    store: store,
                    generation: generation,
                    placedFolders: placedFolders,
                    log: { DriftEngine.shared.log($0) }
                )
                continuation.resume()
            }
        }
    }

    /// Collection #219 (Grace, 2026-11-12): when a channel finds no
    /// descriptors at the top of the extracted pack, its error still
    /// carries a fixed suffix steering the user to the sealed restore
    /// route — wrong for the common case, which is a pack whose layout
    /// is merely misplaced (feedback #217). Rewrite that one failure
    /// here, where the packs are known: a pack the repair check flags
    /// as structurally broken earns directions to「壁纸修复」; anything
    /// else is stated plainly. The raw channel text stays in the log.
    private static func flashFailureMessage(error: Error,
                                            selection: PosterBoardSelection) -> String {
        let raw = error.localizedDescription
        guard raw.contains("没有找到壁纸描述文件") else { return raw }
        if let broken = selection.tendies.first(where: {
            !PackRepair.blockingIssues(of: $0).isEmpty
        }) {
            return "「\(broken.name)」的结构有问题，现在刷不了。"
                + "去它的详细页点「壁纸修复」，修好后刷修复出来的新包。"
        }
        let name = selection.tendies.first?.name ?? "这个包"
        return "在「\(name)」里没有找到壁纸内容，这个包刷不了。"
    }
}


// MARK: - Mode judgement

/// Why one channel is or is not usable right now.
struct DriftModeAvailability: Identifiable, Equatable {
    let mode: PosterBoardApplyMode
    let available: Bool
    let reason: String
    /// How finishing in this channel makes the wallpaper visible.
    let effect: String
    /// Sealed shut rather than merely unavailable: the system is in range
    /// but the signing grants no usable App Group, so the local channel
    /// cannot ever work for this install and its row is not selectable
    /// (collection #142, Grace 2026-11-11).
    var sealed: Bool = false
    var id: String { mode.rawValue }
}

/// The user's method pick. Six methods, exactly as named: 自动选择 and the
/// five channels. The kernel pick is always in the list (Grace,
/// 2026-11-15); its channel is not a `PosterBoardApplyMode` — the judge
/// handles the pick directly. The restore pick joined the list on
/// 2026-11-19 (Grace): selectable, badged 实验， mirroring the kernel
/// pick — and the route opened as a regular feature on 2026-11-22:
/// no switch and no badge; the judge answers from the device
/// premises (iOS 27 segment by build number, the tunnel trio), and
/// `DriftRestoreGate` remains only as an emergency stop.
enum DriftMethodPick: String, CaseIterable, Identifiable {
    case auto
    case noRespring
    case respring
    case local
    case kernel
    case restore

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "自动选择"
        case .noRespring: return "免注销直刷"
        case .respring: return "注销直刷"
        case .local: return "本机直刷"
        case .kernel: return "内核直刷"
        case .restore: return "恢复刷"
        }
    }

    /// The small line under the name in the method card. Deliberately free of
    /// mechanism names (`worse_query`, `AirLift`).
    var subtitle: String {
        switch self {
        case .auto: return "按条件自动挑选通道"
        case .noRespring: return "隧道写入 · 刷完即生效，无需注销"
        case .respring: return "隧道写入 · 注销后生效"
        case .local: return "本机写入，免配对、免隧道"
        case .kernel: return "内核写入，免配对、免隧道、不要求签名"
        case .restore: return "通过恢复方式刷入壁纸"
        }
    }

    /// The channel a manual pick forces; `.auto` decides at run time.
    /// The kernel and restore picks have no channel here — the judge
    /// handles both directly.
    var channel: PosterBoardApplyMode? {
        switch self {
        case .auto, .kernel, .restore: return nil
        case .noRespring: return .direct
        case .respring: return .airlift
        case .local: return .worseQuery
        }
    }

    /// Read a stored pick. Every value written by 2.0.0 or 1.x means the same
    /// thing now: let Drift choose. Only the three new raw values are picks.
    static func fromStored(_ raw: String?) -> DriftMethodPick {
        switch raw {
        case "noRespring": return .noRespring
        case "respring": return .respring
        case "local": return .local
        case "kernel": return .kernel
        case "restore": return .restore
        default: return .auto
        }
    }
}

/// Why a run will use the channel it uses, in one user-facing sentence.
struct DriftModeJudgement {
    /// The pick the card is showing.
    var pick: DriftMethodPick
    /// The channel the run will use. Meaningless when blocked.
    var mode: PosterBoardApplyMode
    var reason: String
    /// Set when no run may start at all right now. `mode` is then a
    /// placeholder — callers must check `isBlocked` before running anything.
    var blockedReason: String?
    /// One row per channel, with its own reason and expected effect.
    var options: [DriftModeAvailability] = []
    /// How the chosen channel is expected to take effect.
    var expectedEffect: String = ""
    /// The run goes to the kernel writer, which has no
    /// `PosterBoardApplyMode` of its own: `mode` is then the local
    /// placeholder, and dispatchers must honour this flag instead
    /// (set for a manual 内核直刷 pick and for 自动选择 landing on it).
    var useKernel: Bool = false
    /// Whether the restore method's premises all hold on this device
    /// right now (the tunnel premises ready and the iOS 27 segment,
    /// judged by build number). The Home restore row and the
    /// tutorial read this for their 可用/不可用 status.
    var restoreAvailable: Bool = false
    var isBlocked: Bool { blockedReason != nil }
}

enum DriftJudge {
    static let manualKey = "DriftManualMode"

    /// The user's method pick (`.auto` when nothing is stored).
    static var manualPick: DriftMethodPick {
        get { DriftMethodPick.fromStored(UserDefaults.standard.string(forKey: manualKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: manualKey) }
    }

    /// The two premise classes, kept apart on purpose.
    ///
    /// * **Local premise** — the app's own system version and build plus a
    ///   granted App Group. All readable in-process, so this is decided
    ///   without a pairing record, a tunnel or Wi-Fi.
    /// * **Tunnel premise** — a saved pairing record, a connected tunnel and a
    ///   real device identity (version *and* build). Both tunnel channels need
    ///   all three; when one is missing they are unavailable and say which,
    ///   and the app's own version is never substituted for the device's.
    private struct Premises {
        let appVersion: String
        let appBuild: String
        let localReady: Bool
        let localWhy: String
        let localSealed: Bool
        let directReady: Bool
        let directWhy: String
        let respringReady: Bool
        let respringWhy: String
        let restoreReady: Bool
        let restoreWhy: String

        func isAvailable(_ mode: PosterBoardApplyMode) -> Bool {
            switch mode {
            case .backup: return restoreReady
            case .direct: return directReady
            case .airlift: return respringReady
            case .worseQuery: return localReady
            }
        }

        func why(_ mode: PosterBoardApplyMode) -> String {
            switch mode {
            case .backup: return restoreWhy
            case .direct: return directWhy
            case .airlift: return respringWhy
            case .worseQuery: return localWhy
            }
        }
    }

    private static func premises(identity: DeviceIdentity, tunnelReady: Bool) -> Premises {
        // The local channel judges the app's *own* system, always. Its device
        // read is irrelevant: the app is the device.
        let appVersion = WorseQueryEscape.processVersion
        let appBuild = WorseQueryEscape.processBuildVersion
        let localReady = WorseQueryEscape.isAvailable(deviceVersion: appVersion,
                                                      buildVersion: appBuild)
        let localWhy = InstallEnvironment.localReason(version: appVersion, build: appBuild)
        // Sealed is narrower than unavailable: the version is in range, so
        // only the signing stands in the way — and no setting or retry can
        // change that for this install.
        let localSealed = !localReady
            && WorseQueryEscape.isSupported(deviceVersion: appVersion,
                                            buildVersion: appBuild)

        var tunnelMissing: String?
        if !PairingRecord.isInstalled {
            tunnelMissing = "还没有配对文件（配对只是走两条隧道通道才需要，本机直刷不需要）"
        } else if !tunnelReady {
            tunnelMissing = "隧道未连通（打开 LocalDevVPN 并连上 Wi-Fi）"
        } else if identity.version.isEmpty {
            tunnelMissing = "还没有读到设备系统版本"
        } else if let order = PosterBoard.compareVersion(identity.version, "18"), order < 0 {
            // #314 (Grace, 2026-11-13): the tunnel floor is iOS 18.0
            // now, judged here at the session layer (the channels'
            // own gates are not this layer's to move). The whole 17
            // band is out: on iOS 17.0 正式版 the device refuses the
            // container lookup itself — two user logs, all five
            // lookup shapes disconnected by the device, and even a
            // build-number query comes back GetProhibited — and no
            // 17.1–17.7 device has ever produced a successful flash.
            // Upstream AirCard's floor is 18.0 as well. The app still
            // installs on 17.0 (its own floor stays) for the sake of
            // the future on-device routes aimed at that band.
            tunnelMissing = "设备系统是 iOS 17 这一代，隧道通道用不了。"
        } else if let lo = PosterBoard.compareVersion(identity.version, "26.0"), lo >= 0,
                  let hi = PosterBoard.compareVersion(identity.version, "26.2"), hi < 0 {
            // #331 (Grace, 2026-11-14): the coverage table is the
            // rulebook for which band opens which channel, and its
            // 26.0–26.1 row is local-only — the tunnel window opens
            // at 26.2. The channels' own gates would pass this band
            // (their floors sit lower), so the closure lives here at
            // the session layer, beside #314's 17-band closure, rather
            // than inside either channel.
            tunnelMissing = "设备系统是 iOS 26.0–26.1 正式版，隧道通道在这两版不开，请用本机直刷。"
        } else if identity.buildVersion.isEmpty,
                  PosterBoard.compareVersion(identity.version, "27.2") == 0 {
            // #294 (Grace, 2026-11-13): the build number only decides
            // anything on 27.2 itself — both tunnel channels key their
            // build lists to exactly that version and pass every other
            // version on the version alone. The pre-check used to demand
            // a build number for ALL versions, so a 17.0 device whose
            // tunnel read came back without one (lockdownd refuses the
            // key for some devices) had both tunnels condemned before
            // their own gates ever ran. 27.2 stays fail-closed: its own
            // gates reject an empty build on their own.
            tunnelMissing = "还没有读到设备构建号（27.2 的可用范围按构建号判断）"
        }

        let directReady = tunnelMissing == nil
            && PosterBoardDirect.isAvailable(deviceVersion: identity.version,
                                             buildVersion: identity.buildVersion)
        // #332 (Grace, 2026-11-14): the Home rows show ONE short line per
        // channel. When the tunnel premises themselves pass, a channel's
        // own refusal can only be its version/build gate (both reason
        // functions return nothing else), so the session layer states it
        // in one line and leaves the band detail to the tutorial pages —
        // the channels' own texts and gates are not touched.
        let directWhy = tunnelMissing
            ?? (directReady ? "" : "这个系统版本不支持。")
        let respringReady = tunnelMissing == nil
            && Airlift.isSupported(deviceVersion: identity.version,
                                   buildVersion: identity.buildVersion)
        let respringWhy = tunnelMissing
            ?? (respringReady ? "" : "这个系统版本不支持。")

        // Restore (opened on the formal line, Grace, 2026-11-22):
        // while the emergency gate is closed the answer stands — not
        // ready, 「暂不可用」. Open, the route needs the tunnel trio
        // the tunnel channels need (the restore rides the same
        // tunnel) and the iOS 27 segment judged by version AND build
        // number; a build that cannot be read is a stop, not a guess.
        let restoreReady: Bool
        let restoreWhy: String
        if !DriftRestoreGate.isEnabled {
            restoreReady = false
            restoreWhy = "暂不可用"
        } else if let missing = tunnelMissing {
            restoreReady = false
            restoreWhy = missing
        } else if identity.buildVersion.isEmpty {
            restoreReady = false
            restoreWhy = "还没有读到设备构建号（恢复刷按构建号判断系统段位）"
        } else if !Self.isRestoreSegment(version: identity.version) {
            restoreReady = false
            restoreWhy = "恢复刷这一版只开 iOS 27 这一段"
        } else {
            restoreReady = true
            restoreWhy = "可用：拉取设备备份，只换壁纸再写回，刷完重启生效"
        }

        return Premises(
            appVersion: appVersion,
            appBuild: appBuild,
            localReady: localReady,
            localWhy: localWhy,
            localSealed: localSealed,
            directReady: directReady,
            directWhy: directWhy,
            respringReady: respringReady,
            respringWhy: respringWhy,
            restoreReady: restoreReady,
            restoreWhy: restoreWhy)
    }

    /// The restore line's open segment: iOS 27.x, judged on the
    /// version's major component (the build-number presence is the
    /// caller's own check — see premises and DriftRestoreService).
    static func isRestoreSegment(version: String) -> Bool {
        (Int(version.split(separator: ".").first ?? "") ?? 0) == 27
    }

    /// How a channel makes the wallpaper visible, in the user's terms.
    static func expectedEffect(for mode: PosterBoardApplyMode) -> String {
        switch mode {
        case .worseQuery:
            return "写完提示：打开应用切换器，上滑关闭 PosterBoard，系统重新拉起后生效"
        case .direct:
            return "免注销：只重启 PosterBoard；刷新未确认时只提示，可手动注销"
        case .airlift:
            return "注销生效"
        case .backup:
            return "重启生效"
        }
    }

    /// The per-channel rows the judgement card prints.
    private static func optionRows(_ p: Premises, identity: DeviceIdentity) -> [DriftModeAvailability] {
        let device = identity.version.isEmpty
            ? "设备系统版本未读到"
            : "设备 \(SystemVersionName.display(version: identity.version, build: identity.buildVersion))"
        return [
            DriftModeAvailability(
                mode: .worseQuery,
                available: p.localReady,
                reason: p.localReady
                    ? "可用：\(SystemVersionName.display(version: p.appVersion, build: p.appBuild))，签名授予的 App Group 可打开"
                    : p.localWhy,
                effect: expectedEffect(for: .worseQuery),
                sealed: p.localSealed),
            DriftModeAvailability(
                mode: .direct,
                available: p.directReady,
                reason: p.directReady
                    ? "可用：\(device) 在 18.0–27.1 正式版及 27.2 beta 1 / 2 内"
                    : p.directWhy,
                effect: expectedEffect(for: .direct)),
            DriftModeAvailability(
                mode: .airlift,
                available: p.respringReady,
                reason: p.respringReady
                    ? "可用：\(device) 在 18.0–27.1 正式版及 27.2 beta 1 / 2 内"
                    : p.respringWhy,
                effect: expectedEffect(for: .airlift)),
        ]
    }

    /// The automatic channel order: the channel that asks least of the user
    /// first. Restore is not in this order — it is a separate sealed entry and
    /// is never substituted.
    private static func firstAvailable(_ p: Premises) -> PosterBoardApplyMode? {
        for mode in [PosterBoardApplyMode.worseQuery, .direct, .airlift]
        where p.isAvailable(mode) {
            return mode
        }
        return nil
    }

    private static func autoReason(_ mode: PosterBoardApplyMode) -> String {
        switch mode {
        case .worseQuery:
            return "自动选择：走本机直刷——在 App 内直接写进商店容器，不用配对、不用隧道；刷完按提示关闭 PosterBoard 生效"
        case .direct:
            return "自动选择：走免注销直刷——隧道事务写入后只重启 PosterBoard，不注销"
        case .airlift:
            return "自动选择：走注销直刷——隧道写入后注销生效"
        case .backup:
            return "暂不可用"
        }
    }

    private static func manualReason(_ mode: PosterBoardApplyMode) -> String {
        switch mode {
        case .worseQuery:
            return "已手动选择本机直刷：在 App 内直接写进商店容器，不用配对、不用隧道；刷完按提示关闭 PosterBoard 生效"
        case .direct:
            return "已手动选择免注销直刷：隧道事务写入后只重启 PosterBoard，不注销"
        case .airlift:
            return "已手动选择注销直刷：隧道写入后注销生效"
        case .backup:
            return "暂不可用"
        }
    }

    /// Decide the channel for a selection.
    ///
    /// Hard limits first (store reset and store-database packs remain
    /// restore-only, hence blocked while 恢复刷 is sealed). Video is accepted
    /// by every non-restore writer. Then: a manual pick
    /// is used as-is and is *unavailable* — never substituted — when its own
    /// premise fails; `.auto` takes the first ready channel in order.
    ///
    /// - Parameter tunnelReady: whether the loopback tunnel currently carries
    ///   traffic. The tunnel premise needs it, so the card must pass it on every
    ///   redraw; it defaults to false for callers that only need a static answer.
    static func judge(identity: DeviceIdentity, selection: PosterBoardSelection,
                      pick: DriftMethodPick,
                      tunnelReady: Bool = false) -> DriftModeJudgement {
        // The kernel pick is always visible and selectable. The judge
        // blocks it only when the system or model is outside its supported
        // compatibility range; manual picks never reroute.
        let p = premises(identity: identity, tunnelReady: tunnelReady)
        let rows = optionRows(p, identity: identity)

        func judged(_ mode: PosterBoardApplyMode, _ reason: String) -> DriftModeJudgement {
            DriftModeJudgement(pick: pick, mode: mode, reason: reason,
                               options: rows, expectedEffect: expectedEffect(for: mode),
                               restoreAvailable: p.restoreReady)
        }
        func blocked(_ reason: String, notice: String) -> DriftModeJudgement {
            DriftModeJudgement(pick: pick, mode: .backup, reason: reason,
                               blockedReason: notice, options: rows,
                               expectedEffect: expectedEffect(for: .backup),
                               restoreAvailable: p.restoreReady)
        }
        /// Blocked because the selection can only travel the sealed method.
        func sealedBlocked(_ reason: String) -> DriftModeJudgement {
            blocked(reason, notice: "暂不可用")
        }
        // Hard limits: these leave only the restore method, and while it is
        // sealed the answer is "cannot flash now".
        if selection.fullReset || !selection.resetModes.isEmpty {
            if DriftRestoreGate.isEnabled {
                return blocked("恢复刷这一版还不支持重置壁纸商店，这次刷不了。换个普通壁纸包，或者用别的方式重置。",
                               notice: "恢复刷还不支持重置壁纸商店。")
            }
            return p.restoreReady
                ? judged(.backup, "暂不可用")
                : sealedBlocked("暂不可用")
        }
        if selection.tendies.contains(where: \.isUnsafeContainer) {
            if DriftRestoreGate.isEnabled {
                return blocked("这个包是『容器』类型的，恢复刷这一版还写不了。先用别的方式刷，或者把出现位置改回『自动』再试。",
                               notice: "容器类型的包，恢复刷这一版还写不了。")
            }
            return p.restoreReady
                ? judged(.backup, "暂不可用")
                : sealedBlocked("暂不可用")
        }

        if pick == .kernel {
            // A manual kernel pick is used as-is when its premise
            // passes and blocked with the honest reason when it does
            // not; manual picks never reroute to another channel.
            let premise = KernelDirectPremise.evaluate(version: p.appVersion)
            if !premise.inBand {
                // Finer split (Grace, 2026-11-16): a 17/18 system
                // past the top of the band hears where the top is,
                // not just which generations the method belongs to.
                if premise.pastBandTop {
                    return blocked("你手动选了内核直刷：它只支持到 iOS 18.7.1，这台的系统是 iOS \(p.appVersion)，已经超过这个范围。手动选定后不会自动改走别的通道。",
                                   notice: "内核直刷只支持到 iOS 18.7.1。")
                }
                return blocked("你手动选了内核直刷：它只支持 iOS 17 / 18，这台的系统是 iOS \(p.appVersion)，不在这个范围。手动选定后不会自动改走别的通道。",
                               notice: "内核直刷只支持 iOS 17 / 18。")
            }
            if !premise.chipCovered {
                return blocked("你手动选了内核直刷：这台机型不在它的支持表里。手动选定后不会自动改走别的通道。",
                               notice: "这台机型不在内核直刷的支持表里。")
            }
            // Kernel Direct is a separate on-device writer, not a
            // PosterBoardApplyMode channel. Home dispatches it directly.
            return DriftModeJudgement(
                pick: pick,
                mode: .worseQuery,
                reason: "已手动选择内核直刷：会先验证 PosterBoard 容器读写，再写入已选描述文件；不用配对、不用隧道，对签名没要求。",
                blockedReason: nil,
                options: rows,
                expectedEffect: "写完提示：打开应用切换器，上滑关闭 PosterBoard，系统重新拉起后生效",
                useKernel: true,
                restoreAvailable: p.restoreReady)
        }

        if pick == .restore {
            // A manual restore pick mirrors the kernel pick (Grace,
            // 2026-11-19): selectable, never rerouted. Since the
            // formal opening (Grace, 2026-11-22) there is no switch:
            // the branch judges for real on the premises
            // restoreReady/restoreWhy already folded (tunnel trio,
            // iOS 27 segment by version and build number). A judged
            // run is the one-flow apply: the dry run chains straight
            // into the write-back inside the same run, and the
            // pre-start confirmation on the page covers the dangers.
            if p.restoreReady {
                return judged(.backup, "已手动选择恢复刷：拉取设备备份，只换壁纸再写回，刷完重启生效。")
            }
            return blocked("你手动选了恢复刷：\(p.restoreWhy)。手动选定后不会自动改走别的通道。",
                           notice: "恢复刷现在用不了：\(p.restoreWhy)。")
        }

        if let channel = pick.channel {
            if p.isAvailable(channel) {
                return judged(channel, manualReason(channel))
            }
            return blocked("你手动选了\(pick.label)：\(p.why(channel))。手动选定后不会自动改走别的通道。",
                           notice: "\(pick.label)现在不可用：\(p.why(channel))。")
        }

        // 自动选择把内核直刷也算进去 (Grace, 2026-11-15): on its own
        // band it asks the least of the user — no pairing, no tunnel,
        // no signing gate — and that band (iOS 17 / 18) never overlaps
        // the local channel's, so it is judged before the channel
        // order. It is a candidate whenever the system and model
        // compatibility premise is satisfied.
        let kernelPremise = KernelDirectPremise.evaluate(version: p.appVersion)
        if kernelPremise.ready {
            return DriftModeJudgement(
                pick: pick,
                mode: .worseQuery,
                reason: "自动选择：走内核直刷——会先验证 PosterBoard 容器读写，再写入已选描述文件；不用配对、不用隧道，对签名没要求。",
                blockedReason: nil,
                options: rows,
                expectedEffect: "写完提示：打开应用切换器，上滑关闭 PosterBoard，系统重新拉起后生效",
                useKernel: true)
        }

        if let channel = firstAvailable(p) {
            return judged(channel, autoReason(channel))
        }
        // #332 (Grace, 2026-11-14): this summary used to concatenate all
        // three channels' full reasons into one paragraph — the same
        // texts the rows and the header card already showed. One line is
        // enough here; each row above carries its own short reason.
        return blocked("自动选择：现在没有能用的方式。",
                       notice: "现在没有能用的方式。")
    }
}
