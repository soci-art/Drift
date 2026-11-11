import Foundation
import Minimuxer

/// Drift 2.0.0's engine facade — the replacement for `GoldenNuggetEngine`.
///
/// What changed in the swap, and what deliberately did not:
///
/// * **Gone**: the whole GoldenNugget apply pipeline — tweak compilation,
///   skip-setup, status bar, community templates/presets, and the
///   `deliver()` tail that synthesised a backup on the host and restored
///   it (the mechanism behind feedback #42's phantom tweak payloads and
///   the MBErrorDomain 211 that failed otherwise-clean wallpaper runs).
///   There is no backup/restore code behind this facade at all; the
///   restore mode is refused with the suspension notice, and
///   `DriftRestoreGate` stays as the standing notice source.
/// * **Kept, behaviour-identical**: the three wallpaper transports and
///   their pre-flight checks, moved here from the old engine — the
///   in-process route (a thin call into the frozen `PosterBoardLocal`),
///   the direct transaction (`PosterBoardDirect`) and the AirLift
///   injection (`PosterBoardAirlift`) — plus the logging / cancellation /
///   progress facades the session and the views already use.
/// * **Simplified, on purpose**: the old `prepareRun()` also ran the
///   hot-load tweak-policy gate and the backup-encryption preflight.
///   Both protected the restore path only; the tunnel transports never
///   restore, so the facade keeps just the minimuxer-readiness third of
///   it. The version used for mode resolution and for the route checks
///   is the single fresh identity read (`modeVersion`), where the old
///   engine threaded two reads of the same value.
///
/// The facade's one entry point is `applyWallpapers(selection:deviceVersion:)`.
/// Drift's only caller passes an empty tweak/status-bar/template selection
/// by construction — there is no such surface in this app — so the facade
/// takes the wallpaper selection alone.
final class DriftEngine {
    static let shared = DriftEngine()

    private init() {}

    // MARK: - Logging facade

    /// Route engine log lines into the UI list.
    var onLog: ((String) -> Void)? {
        didSet { AppLog.shared.setUIHandler(onLog) }
    }

    func log(_ msg: String) {
        AppLog.shared.log(msg)
    }

    /// Run `body` under `label`, writing a failure into the log before it escapes.
    private func loggedRun<T>(_ label: String,
                              _ body: () async throws -> T) async throws -> T {
        let runToken = try InFlightCall.shared.beginRun()
        defer { InFlightCall.shared.endRun(runToken) }
        do {
            return try await body()
        } catch let failure as TransportFailure where failure.isCancellation {
            log("\(label) stopped: \(failure.label)")
            throw failure
        } catch {
            log("\(label) failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Cancellation facade

    func requestCancel() { CancelFlag.shared.request() }

    func clearCancel() { CancelFlag.shared.clear() }

    // MARK: - Paths facade

    static var appLogURL: URL { AppPaths.appLog }
    static var rustLogURL: URL { AppPaths.rustLog }
    static var diagnosticsURL: URL { AppPaths.diagnostics }

    static func rustLogSize() -> UInt64 { RustLog.size() }
    static func appLogSize() -> UInt64 { AppLog.shared.file.size() }
    static func rustLogStatus() -> String { RustLog.status() }

    /// Remember the log offset so the next excerpt covers only THIS run.
    @discardableResult
    func markRustLog() -> UInt64 { RustLog.markStart() }

    // MARK: - Rust logging

    /// Point the Rust logger at `<Documents>/minimuxer.log` at DEBUG level.
    ///
    /// MUST run before `setLogging(true)` / `core.start()`: the Rust side
    /// latches on the first `idevice_init_logger` call for the whole process
    /// (`Once`), and the existing call site installs console=Error / file=OFF.
    /// Safe to call repeatedly — every call after the first returns -2
    /// without changing anything.
    @discardableResult
    func enableRustFileLogging() -> Int32 {
        if let cached = RustLog.initResult {
            return cached
        }

        let hygiene = PairingLogPrivacy.removeLegacyDumps(
            at: [AppPaths.rustLog, AppPaths.rustLogArchive, AppPaths.appLog]
        )
        if !hygiene.isEmpty {
            log("diagnostic logs reclaimed: \(hygiene.summary) — the backup volume needs this space")
        }
        let path = AppPaths.rustLog.path

        let rc: Int32
        if let gateway = Minimuxer.shared().ideviceGateway {
            rc = gateway.enableRustFileLogging(to: path)
        } else {
            rc = -99
        }
        RustLog.noteInitResult(rc)

        let meaning: String
        switch rc {
        case 0:   meaning = "file sink requested (DEBUG)"
        case -1:  meaning = "file error — path rejected by Rust"
        case -2:  meaning = "already initialized — a previous idevice_init_logger call won, Rust logs stay on console(Error) and never reach the file"
        case -3:  meaning = "invalid path string"
        case -99: meaning = "no ideviceGateway available"
        default:  meaning = "unknown"
        }
        log("rust log → \(path): rc=\(rc) (\(meaning))")

        if rc == 0 {
            let fm = FileManager.default
            let parent = URL.documents.path
            let parentExists = fm.fileExists(atPath: parent)
            log("rust log dir: \(parent) exists=\(parentExists) "
                + "(file appears with the first Rust line)")
            if !parentExists {
                log("⚠️ the Rust log directory does not exist — no Rust evidence will be "
                    + "written this session. This app is running somewhere its Documents "
                    + "path is not writable.")
            }
        }
        return rc
    }

    // MARK: - Diagnostics

    /// The failure dump; see `Diagnostics.report()`.
    func diagnostics() async -> String {
        await Diagnostics.report()
    }

    // MARK: - Progress facade

    /// Whole-percent progress of the run in flight, or nil when nothing has
    /// reported yet.
    private(set) var progress: Double?

    /// Route progress into the UI.
    var onProgress: ((Double) -> Void)?

    /// Route the remaining-time estimate into the UI with the same story as
    /// `onProgress`.
    var onEta: ((String) -> Void)?

    /// The last formatted remaining time (`""` before an estimate exists or
    /// while nothing is running).
    private(set) var etaText: String = ""

    /// How the last run's in-process write decided to take effect, if this run
    /// used that route. Reset at the start of every run; the session reads it
    /// after the run to word the completion prompt and the history record.
    private(set) var lastPosterBoardEffect: PosterBoardEffect?

    /// The last tunnel run's store verification (2.0.0): whether the
    /// descriptors the run wrote are actually in the device's store, read
    /// back over the tunnel. The session grades its success wording and
    /// the history record from this — a tunnel run may only say 完成 when
    /// the verification confirms every descriptor is in store.
    private(set) var lastVerification: PosterStoreVerification?

    /// The `eta.py` port.  Recreated per run so a new apply starts estimating
    /// from a clean slate even though the engine object is a singleton.
    private var etaEstimator = ProgressEta()

    private func reportProgress(_ percent: Double) {
        let clamped = percent < 0 ? 0 : min(percent, 100)
        progress = clamped
        onProgress?(clamped)
        let estimate = etaEstimator.update(clamped)
        etaText = estimate
        onEta?(estimate)
    }

    private func clearProgress() {
        progress = nil
        etaEstimator.reset()
        etaText = ""
        onProgress?(Double.nan)
        onEta?("")
    }

    /// Clamp and throttle a Rust progress callback down to whole percent.
    private func logProgress(_ prefix: String, _ overall: Double) {
        let pct = overall < 0 ? 0 : min(overall, 100)
        reportProgress(pct)
        log(String(format: "\(prefix): %.0f%%", pct))
    }

    // MARK: - Run: apply a wallpaper selection

    /// Apply one wallpaper selection through the mode the settings resolve
    /// to. The session has already judged and stored the pick; resolution
    /// here re-validates it against the device's actual version and build,
    /// exactly as the old engine did.
    func applyWallpapers(selection: PosterBoardSelection,
                         deviceVersion: String) async throws {
        try await loggedRun("apply") {
            try await applyWallpapersRun(selection: selection,
                                         deviceVersion: deviceVersion)
        }
    }

    private func applyWallpapersRun(selection: PosterBoardSelection,
                                    deviceVersion: String) async throws {
        AppLog.shared.memory.reset()
        clearCancel()
        clearProgress()
        lastPosterBoardEffect = nil
        lastVerification = nil
        let runStage = StageTimer("RUN apply")
        defer { runStage.done() }

        // A reset and a wallpaper selection cannot ride the same run: the
        // reset branch of the reference returns before it ever reads the
        // packs, so such a run would empty the store and install none of
        // the wallpapers the page still shows as selected. Refuse, and
        // name both halves. (Preserved from the old engine.)
        if selection.fullReset || !selection.resetModes.isEmpty {
            let carriesWallpapers = !selection.tendies.isEmpty || selection.video != nil
            if carriesWallpapers {
                throw GoldenNuggetError("PosterBoard 页已有一个待执行的重置："
                    + "（\(selection.describe)），同时还选中了壁纸。重置运行"
                    + "不会安装任何壁纸——它会清空库，并在读取壁纸包之前就返回"
                    + "——所以这样应用会抹掉所有壁纸且不新增任何一张。请"
                    + "关闭重置来安装壁纸，或者取消选择壁纸来执行重置。")
            }
            log("PosterBoard: \(selection.describe) — this run clears the store and installs "
                + "nothing.")
        }

        guard selection.isActive || selection.fullReset || !selection.resetModes.isEmpty else {
            throw GoldenNuggetError("没有可应用的内容：PosterBoard 页没有选择任何内容。")
        }

        // The apply mode picks the mechanism. The in-process route reads
        // its version from the process, not from lockdown: the app *is*
        // the device. (Preserved from the old engine.)
        let modeIdentity = await DeviceIdentity.read()
        let modeVersion = modeIdentity.version.isEmpty
            ? (deviceVersion.isEmpty ? WorseQueryEscape.processVersion : deviceVersion)
            : modeIdentity.version
        let mode = PosterBoardApplyModeSettings.resolved(
            deviceVersion: modeVersion,
            buildVersion: modeIdentity.buildVersion)

        switch mode {
        case .worseQuery:
            // The in-process route: no tunnel to open, no pairing record to
            // consult and no backup to take. It carries wallpapers only.
            // This is a thin call into the frozen `PosterBoardLocal`; the
            // check beside it is the old engine's, unchanged.
            try checkLocalCanApply(
                posterBoard: selection,
                templates: [],
                hasOtherPayloads: false,
                deviceVersion: modeVersion)
            log("PosterBoard: \(selection.describe) — on-device, no tunnel")
            let effect = try await PosterBoardLocal.apply(
                selection: selection,
                templates: [],
                deviceVersion: modeVersion,
                log: { AppLog.write($0) },
                progress: { overall in self.logProgress("posterboard local", overall) })
            lastPosterBoardEffect = effect
            log("Apply succeeded: the wallpapers are in PosterBoard's container; "
                + "effect — \(effect.headline). No pairing, no tunnel and no backup "
                + "were needed for the write.")
            return

        case .direct, .airlift:
            // The tunnel transports need the core up (the old prepareRun's
            // readiness third). The backup-only thirds of prepareRun — the
            // hot-load policy gate and the encryption preflight — do not
            // apply: these routes never take or restore a backup.
            let minimuxer = Minimuxer.shared()
            guard await testReady(minimuxer) else {
                throw GoldenNuggetError("minimuxer 尚未就绪。请确保 Wi-Fi 和隧道可用（LocalDevVPN 或 WireGuard + em_proxy），然后选择配对文件。")
            }
            // Everything after this byte offset is this run's Rust output.
            markRustLog()
            if mode == .direct {
                log("PosterBoard: \(selection.describe) — direct over the pairing tunnel, no backup")
                try checkDirectCanApply(selection: selection, templates: [],
                                        deviceVersion: modeVersion,
                                        buildVersion: modeIdentity.buildVersion)
                try await applyPosterBoardOverDirect(selection: selection,
                                                     templates: [],
                                                     deviceVersion: modeVersion,
                                                     buildVersion: modeIdentity.buildVersion)
            } else {
                try checkAirliftCanApply(posterBoard: selection, templates: [],
                                         deviceVersion: modeVersion,
                                         buildVersion: modeIdentity.buildVersion)
                log("PosterBoard: \(selection.describe) — over AirLift, no backup")
                try await applyPosterBoardOverAirlift(selection: selection,
                                                      templates: [],
                                                      deviceVersion: modeVersion,
                                                      buildVersion: modeIdentity.buildVersion)
            }
            log("Apply succeeded: the wallpapers are in PosterBoard's container.")
            return

        case .backup:
            // The restore route is suspended (feedback #30) and its whole
            // delivery machinery was removed in the 2.0.0 swap: there is no
            // backup or restore code behind this facade to fall back to.
            // The session funnel refuses this mode first; this is the
            // second, engine-side refusal with the same notice.
            throw GoldenNuggetError(DriftRestoreGate.notice)
        }
    }

    // MARK: - Readiness

    private func testReady(_ minimuxer: Minimuxer) async -> Bool {
        if case .success(true) = await minimuxer.core.isReady() {
            return true
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        if case .success(true) = await minimuxer.core.isReady() {
            return true
        }
        return false
    }

    // MARK: - Route checks and appliers (moved from the old engine, unchanged)

    /// Refuse a selection the direct route cannot carry.
    ///
    /// Same limits as AirLift: the transaction installs descriptor folders,
    /// so a reset, a video stage, a container template or any non-wallpaper
    /// payload cannot travel it. Unlike AirLift it also has its own closed
    /// version range (26.0–27.1, plus 27.2 beta 1/2), checked here rather than
    /// in the judge so a
    /// manual pick cannot bypass it.
    private func checkDirectCanApply(selection: PosterBoardSelection,
                                     templates: [TemplateFile],
                                     deviceVersion: String,
                                     buildVersion: String) throws {
        if templates.contains(where: \.isContainer) {
            throw GoldenNuggetError("直刷只安装模板描述文件。所选模板还带有容器文件；"
                + "请切换到「恢复刷」来应用全部内容。"
                + DriftRestoreGate.unavailableSuffix)
        }
        if selection.fullReset || !selection.resetModes.isEmpty {
            throw GoldenNuggetError("直刷无法重置 PosterBoard 库——它只会添加壁纸。"
                + "要重置，请把刷入方式切换到「恢复刷」。"
                + DriftRestoreGate.unavailableSuffix)
        }
        if selection.video != nil {
            throw GoldenNuggetError("直刷无法应用 PosterBoard 视频：它的帧是为恢复准备的。"
                + "请把刷入方式切换到「恢复刷」。"
                + DriftRestoreGate.unavailableSuffix)
        }
        if selection.tendies.contains(where: \.isUnsafeContainer) {
            throw GoldenNuggetError("包含商店数据库的壁纸包只能用恢复刷；恢复刷已封存，暂时刷不了。")
        }
        let reason = PosterBoardDirect.unavailableReason(deviceVersion: deviceVersion,
                                                         buildVersion: buildVersion)
        guard reason.isEmpty else { throw GoldenNuggetError(reason) }
        guard FileManager.default.fileExists(atPath: AppPaths.pairingFile.path) else {
            throw GoldenNuggetError("直刷需要一份配对记录，但还没有保存任何一份。"
                + "请先在首页导入一份，本机通道可用时会自动改走本机通道。")
        }
    }

    /// Run the direct PosterBoard transaction, reporting through the run log.
    private func applyPosterBoardOverDirect(selection: PosterBoardSelection,
                                            templates: [TemplateFile] = [],
                                            deviceVersion: String,
                                            buildVersion: String) async throws {
        let structureVersion = try PosterBoard.verifiedTunnelStructureVersion(
            deviceVersion: deviceVersion,
            buildVersion: buildVersion,
            log: { AppLog.write($0) })
        lastVerification = try await PosterBoardDirect.apply(
            selection: selection,
            templates: templates,
            structureVersion: structureVersion,
            deviceVersion: deviceVersion,
            buildVersion: buildVersion,
            pairingPath: AppPaths.pairingFile.path,
            log: { AppLog.write($0) },
            progress: { overall in self.logProgress("posterboard direct", overall) }
        )
    }

    /// Refuse a selection the AirLift path cannot carry, before anything is opened.
    ///
    /// A reset is a store operation and the video stage's frames are computed for
    /// the restore, so neither can travel a container write. Saying so up front is
    /// the alternative to accepting the selection and quietly dropping half of it.
    private func checkAirliftCanApply(posterBoard: PosterBoardSelection,
                                     templates: [TemplateFile] = [], deviceVersion: String, buildVersion: String = "") throws {
        if templates.contains(where: \.isContainer) {
            throw GoldenNuggetError("AirLift 只安装模板描述文件。所选模板"
                + "还带有容器文件；请切换到「恢复刷」来应用全部内容。"
                + DriftRestoreGate.unavailableSuffix)
        }
        if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
            throw GoldenNuggetError("AirLift 无法重置 PosterBoard 库——它只会添加"
                + "壁纸。要重置，请把应用模式切换到「恢复刷」。"
                + DriftRestoreGate.unavailableSuffix)
        }
        if posterBoard.video != nil {
            throw GoldenNuggetError("AirLift 无法应用 PosterBoard 视频：它的帧是"
                + "是为恢复准备的。请把应用模式切换到「恢复刷」。"
                + DriftRestoreGate.unavailableSuffix)
        }
        let reason = Airlift.unsupportedReason(deviceVersion: deviceVersion, buildVersion: buildVersion)
        guard reason.isEmpty else { throw GoldenNuggetError(reason) }
        guard FileManager.default.fileExists(atPath: AppPaths.pairingFile.path) else {
            throw GoldenNuggetError("AirLift 需要一份配对记录，但还没有保存任何一份。"
                + "请先在首页导入一份。")
        }
    }

    /// Refuse a selection the in-process route cannot carry.
    ///
    /// The route copies descriptor folders into PosterBoard's container. It has
    /// no manifest, so tweak/skip-setup/status-bar payloads in the same run would
    /// be dropped on the floor; a reset is a store operation it cannot express;
    /// and the video stage's frames are computed for the restore. Each is named
    /// instead of being silently ignored.
    private func checkLocalCanApply(posterBoard: PosterBoardSelection,
                                    templates: [TemplateFile],
                                    hasOtherPayloads: Bool,
                                    deviceVersion: String) throws {
        if hasOtherPayloads {
            throw GoldenNuggetError("本机通道只能写入壁纸：所选内容里还有调整、跳过设置、"
                + "状态栏或其他模板文件，它们不会通过这条路径送达。请只保留壁纸，"
                + "或改用其他刷入方式。")
        }
        if templates.contains(where: \.isContainer) {
            throw GoldenNuggetError("本机通道只安装模板描述文件。所选模板还带有容器文件；"
                + "请改用「恢复刷」来应用全部内容。"
                + DriftRestoreGate.unavailableSuffix)
        }
        if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
            throw GoldenNuggetError("本机通道无法重置 PosterBoard 库——它只会添加壁纸。"
                + "要重置，请把刷入方式切换到「恢复刷」。"
                + DriftRestoreGate.unavailableSuffix)
        }
        if posterBoard.video != nil {
            throw GoldenNuggetError("本机通道无法应用 PosterBoard 视频：它的帧是为恢复准备的。"
                + "请把刷入方式切换到「恢复刷」。"
                + DriftRestoreGate.unavailableSuffix)
        }
        if posterBoard.tendies.contains(where: \.isUnsafeContainer) {
            throw GoldenNuggetError("包含商店数据库的壁纸包只能用恢复刷；恢复刷已封存，暂时刷不了。")
        }
        let reason = WorseQueryEscape.unavailableReason(deviceVersion: deviceVersion)
        guard reason.isEmpty else { throw GoldenNuggetError(reason) }
    }

    /// Run the AirLift PosterBoard injection, reporting through the run log.
    private func applyPosterBoardOverAirlift(selection: PosterBoardSelection,
                                             templates: [TemplateFile] = [],
                                             deviceVersion: String,
                                             buildVersion: String) async throws {
        let structureVersion = try PosterBoard.verifiedTunnelStructureVersion(
            deviceVersion: deviceVersion,
            buildVersion: buildVersion,
            log: { AppLog.write($0) })
        lastVerification = try await PosterBoardAirlift.apply(
            selection: selection,
            templates: templates,
            structureVersion: structureVersion,
            deviceVersion: deviceVersion,
            pairingPath: AppPaths.pairingFile.path,
            log: { AppLog.write($0) },
            progress: { overall in self.logProgress("posterboard airlift", overall) }
        )
    }
}

// MARK: - Residual media store reclamation

extension DriftEngine {
    /// Empty the leftover AFC media store and return how many bytes were
    /// reclaimed (0 when there was nothing to reclaim or the removal failed).
    ///
    /// Moved here from the deleted `AfcMediaBackup` in the 2.0.0 swap: the
    /// device-side pull/push machinery is gone with the restore pipeline,
    /// but this launch-time cleanup is still live — older builds pulled the
    /// device's photos and videos into the container's media store partway
    /// through a flash (feedback #27 removed the step), and whatever is
    /// still parked there is a leftover copy with nothing pointing at it.
    /// Only this app's container copy is removed; the device's own library
    /// is never touched.
    @discardableResult
    static func reclaimResidualMediaStore() -> Int64 {
        let fm = FileManager.default
        let storeRoot = AppPaths.mediaStore
        guard fm.fileExists(atPath: storeRoot.path) else { return 0 }
        guard let enumerator = fm.enumerator(
            at: storeRoot, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var files = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values?.fileSize ?? 0)
        }
        guard files > 0 else { return 0 }
        try? fm.removeItem(at: storeRoot)
        return fm.fileExists(atPath: storeRoot.path) ? 0 : bytes
    }
}
