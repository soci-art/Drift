import Foundation
import Minimuxer
import SwiftUI

/// An error whose message is meant for the operator, not for a stack trace.
struct GoldenNuggetError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// The apply pipeline, ported from GoldenNugget's own apply pass
// (`device_manager._apply_tweak_pass`) onto this app's restore machinery.
//
// Flow:
//   1. Compile the selection to plists — before the device is touched, so an
//      impossible selection costs nothing.
//   2. Real protective backup via mobilebackup2 — triggers the iOS 27
//      backup-password/trust popup and establishes an authorized session.
//      FactoryInfo {Applications: {}} skips app containers device-side.
//      shouldPreserve drains photos/movies mid-stream.
//   3. Prune Manifest.db to the protective keep-set (drained files still
//      have rows — they must be removed or restore requests them), then inject
//      the compiled tweak plists as rows + payloads.
//   4. Restore via mobilebackup2.
//
// This type is the run orchestrator and the app-facing facade.  The work itself
// lives in `Core/`: `ProtectiveBackup` (stage 2), `BackupInjector` (stage 3),
// `RestoreRunner` (stage 4), with `ChannelRecovery` / `StallGuard` /
// `TransportFailure` handling the retry and silence verdicts, `ManifestStore`
// owning the manifest, `RustLog` + `WireCensus` reading the Rust evidence, and
// `AppLog` being the process-wide log bus.  The facade is kept so the SwiftUI
// layer does not have to know any of that.
class GoldenNuggetEngine {
    static let shared = GoldenNuggetEngine()

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
    ///
    /// Every run entry point throws to a view that turns the error into a status
    /// line, and a status line lives exactly as long as the screen: the file sink
    /// is the only record a failed run leaves once the app is closed. It has to
    /// be written here rather than at the call sites because there are four of
    /// them and a fifth would silently skip it — which is how a posterboard apply
    /// came to end with its last line still on the *fetch* and nothing saying
    /// why.
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
    /// That is why `minimuxer.log` never existed and a failed mobilebackup2
    /// backup produced no Rust-side evidence.  Safe to call repeatedly — every
    /// call after the first returns -2 without changing anything.
    @discardableResult
    func enableRustFileLogging() -> Int32 {
        // One line per call was wrong twice over: `.onAppear` fires on every
        // navigation back and `startMinimuxer` calls this again, so a session
        // that never got a tunnel printed the same "rust log → …" line a dozen
        // times — the loudest thing in a log whose real failure was one line
        // lower. The Rust side is process-wide state; the first answer is the
        // only one that describes it.
        if let cached = RustLog.initResult {
            return cached
        }

        let hygiene = PairingLogPrivacy.removeLegacyDumps(
            at: [AppPaths.rustLog, AppPaths.rustLogArchive, AppPaths.appLog]
        )
        if !hygiene.isEmpty {
            // Named, not silent: this is free space on the volume the device's
            // backup space check measures, and its absence is why backups that
            // used to work started offering zero files.
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

        // rc=0 only means the subscriber was installed; the file itself is
        // created by the first line the Rust side writes, so it is legitimately
        // absent here. What must be true NOW is that the directory exists —
        // a missing parent is the one case where the sink can never come up, and
        // it is invisible afterwards (status reads "size=MISSING" forever).
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
    /// reported yet.  The reference's home page prints the same number in its
    /// process-status line (`IOSApplyPage.set_status` parses `NN%` out of the
    /// status text), and a multi-minute restore with no number on it is the one
    /// screen the operator keeps re-reading to guess whether it is alive.
    private(set) var progress: Double?

    /// Route progress into the UI.  Called from the Rust progress callbacks, so
    /// the handler hops to the main actor itself.
    var onProgress: ((Double) -> Void)?

    /// Route the remaining-time estimate into the UI with the same story as
    /// `onProgress`: the feed happens on the Rust callback thread, the handler
    /// hops to the main actor.  Empty string until a stable rate is known — the
    /// desktop's status line shows nothing while `eta.py` is still quiet.
    var onEta: ((String) -> Void)?

    /// The last formatted remaining time (`""` before an estimate exists or
    /// while nothing is running).
    private(set) var etaText: String = ""

    /// How the last run's in-process write decided to take effect, if this run
    /// used that route. Reset at the start of every run; the session reads it
    /// after the run to word the completion prompt and the history record.
    private(set) var lastPosterBoardEffect: PosterBoardEffect?

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

    // MARK: - Run: apply the ported GoldenNugget tweaks

    /// Apply everything this app can deliver: the compiled plist tweaks, the skip-setup
    /// files, and the PosterBoard selection — **one pass, one button**.
    ///
    /// This is GoldenNugget's `device_manager._apply_tweak_pass`, whose file list is
    /// built from every feature at once: its `needs_posterboard` flag decides whether the
    /// store's database has to be fetched first, and the wallpapers then ride the same
    /// restore as the tweaks.  There is no separate apply for wallpapers — this port had
    /// one for a while, a second button running the same four stages over a different
    /// payload set, and it is gone.  What is left of it is the flag.
    ///
    /// The compile runs *before* the device is touched, so an empty or impossible
    /// selection fails without paying for a backup first.  The PosterBoard database is
    /// the one input that has to come off the device; that stage therefore talks to it,
    /// but it is still ahead of the expensive protective pull and of the restore.
    func applyTweaks(
        selection: TweakSelection,
        posterBoard: PosterBoardSelection,
        statusBar: StatusBarSelection,
        templates: TemplateSelection,
        deviceVersion: String,
        isIPhone: Bool,
        deviceModel: String = "",
        communityPayloads: [TweakPayload] = [],
        communityPresetEntry: [String: Any]? = nil
    ) async throws {
        // `_prepare_rollback_preset` (`main_window_mixins.py:1090`): keep the
        // last successful apply available as a one-click rollback *before* the
        // next apply overwrites it.  Best-effort, like the reference.
        try await loggedRun("apply") {
            GoldenNuggetPresets.prepareRollback()
            try await applyTweaksRun(selection: selection,
                                     posterBoard: posterBoard,
                                     statusBar: statusBar,
                                     templates: templates,
                                     deviceVersion: deviceVersion,
                                     isIPhone: isIPhone, deviceModel: deviceModel, communityPayloads: communityPayloads)
        }
        // `_save_last_applied_preset` (`main_window_mixins.py:1101`): a run
        // that returned is a successful apply — it becomes the rollback source
        // for the next one.  The model string is derived because the engine
        // does not carry a full identity; the snapshot is internal metadata.
        _ = GoldenNuggetPresets.saveLastApplied(selection: selection,
                                                deviceModel: deviceModel.isEmpty ? (isIPhone ? "iPhone" : "iPad") : deviceModel,
                                                iosVersion: deviceVersion)
        if let entry = communityPresetEntry {
            do { try GoldenNuggetPresets.attachTemplates(entry, to: GoldenNuggetPresets.lastAppliedName) }
            catch { log("Template rollback snapshot could not be saved: \(error.localizedDescription)") }
        }
    }

    private func applyTweaksRun(
        selection: TweakSelection,
        posterBoard: PosterBoardSelection,
        statusBar: StatusBarSelection,
        templates: TemplateSelection,
        deviceVersion: String,
        isIPhone: Bool,
        deviceModel: String = "",
        communityPayloads: [TweakPayload] = []
    ) async throws {
        AppLog.shared.memory.reset()
        clearCancel()
        clearProgress()
        lastPosterBoardEffect = nil
        let runStage = StageTimer("RUN apply")
        defer { runStage.done() }

        let identity = await DeviceIdentity.read()
        let safety = await MainActor.run {
            HotLoadService.shared.policy(deviceVersion: identity.version.isEmpty ? deviceVersion : identity.version,
                                         model: identity.productType.isEmpty ? deviceModel : identity.productType)
        }
        var features: Set<String> = []
        if posterBoard.isActive { features.insert("PosterBoard") }
        if statusBar.isActive { features.insert("Status Bar") }
        if templates.isActive || !communityPayloads.isEmpty { features.insert("Templates") }
        try safety.requireAllowed(features: features)
        try safety.validateCommunity(communityPayloads)
        for warning in safety.warnings(for: selection) + safety.warnings(forFeatures: features) { log("HotLoad warning: \(warning)") }
        if let issue = selection.validationIssue() { throw GoldenNuggetError(issue) }
        let compiled = TweakCompiler.compile(selection: selection,
                                             deviceVersion: deviceVersion,
                                             isIPhone: isIPhone, deviceModel: deviceModel,
                                             hiddenTweakIDs: safety.hiddenTweakIDs,
                                             forcedDaemonKeys: safety.forcedDaemonKeys)

        let tweakPayloads = try TweakCompiler.merging(community: communityPayloads, builtIn: compiled.payloads, deviceVersion: deviceVersion)

        // The status bar is built here, on the version the page already read, and
        // for the same reason the plist compile is: a payload that cannot be built
        // has to fail before the device is touched.  The page resolves the
        // mechanism from this same number, so the two cannot disagree.
        var statusBarPayloads: [TweakPayload] = []
        if statusBar.isActive {
            let mechanism = StatusBarMechanism.mechanism(for: deviceVersion)
            let built = try statusBar.payload(for: mechanism)
            statusBarPayloads = [TweakPayload(domain: mechanism.domain,
                                              relativePath: mechanism.restorePath,
                                              contents: built.data)]
            // The count, then the parenthetical the reference's summary has: an
            // enabled-but-empty selection still writes a file, and the log has to
            // say so, or a reset reads as a no-op.
            log("Status bar: \(statusBar.overrides.activeCount) override(s)"
                + " \(statusBar.overrides.activeCount == 0 ? "(a reset)" : "") via "
                + "\(mechanism == .classic ? "the classic struct" : "the iOS 27 archive") "
                + "→ \(statusBarPayloads[0].label) (\(built.data.count) B)")
            for field in built.dropped {
                log("  ⚠️ \(field) has no counterpart in the iOS 27 archive and was not delivered")
            }
        }

        // Upstream's skip-setup block rides the same apply, **ahead of** the
        // tweaks (`device_manager.add_skip_setup`).  Its warnings are logged
        // below: the parts this port cannot reproduce must not read like parity.
        //
        // Always the un-supervised variant.  The `supervised` / `organizationName`
        // arguments used to come off the Supervision page, and the page is gone —
        // it recorded `IsSupervised` without ever writing the
        // `SupervisorHostCertificates` that make the flag mean anything, so a
        // device this app "supervised" sat in a state the reference never
        // produces on purpose.  `SkipSetup` still carries the supervised shape
        // because `scripts/skipsetup-check.swift` checks both, but nothing in the
        // app selects it any more.
        let skipSetup = SkipSetupSettings.shared.skipSetupEnabled
            ? SkipSetup.build(supervised: false, organizationName: "")
            : SkipSetup.Build(payloads: [], warnings: [])

        guard !tweakPayloads.isEmpty || !skipSetup.payloads.isEmpty || posterBoard.isActive
                || statusBar.isActive || templates.usesDomains else {
            throw GoldenNuggetError("没有可应用的内容：没有启用任何调整（或者每个已启用的都"
                + "被跳过了）、跳过设置处于关闭、状态栏未改动、"
                + "PosterBoard 页没有选择任何内容，也没有模板通过"
                + "备份域交付。")
        }
        log("Tweaks: \(tweakPayloads.count) file(s) from \(compiled.locations.count) plist(s)")
        for location in compiled.locations { log("  → \(location.rawValue)") }
        for item in compiled.skipped { log("  ⚠️ skipped \(item.label): \(item.reason)") }
        if !skipSetup.payloads.isEmpty {
            log("Skip setup: \(skipSetup.payloads.count) file(s) ahead of the tweaks")
            for payload in skipSetup.payloads { log("  → \(payload.label)") }
            for warning in skipSetup.warnings { log("⚠️ \(warning)") }
        }

        // The apply mode picks the mechanism, and it is the user's choice: the
        // backup path below and the AirLift path install the same wallpapers two
        // different ways, and neither can stand in for the other. The mode's
        // constraints are checked *here*, before `prepareRun`, so a selection the
        // chosen mode cannot honour fails without paying for a tunnel first.
        let modeIdentity = await DeviceIdentity.read()
        // The in-process route reads its version from the process, not from
        // lockdown: the app *is* the device. That is not a shortcut, it is the
        // only answer available when no pairing record exists — which is the
        // whole point of the route, and the case a `deviceVersion` of "" would
        // otherwise push into the backup fallback.
        let modeVersion = modeIdentity.version.isEmpty
            ? (deviceVersion.isEmpty ? WorseQueryEscape.processVersion : deviceVersion)
            : modeIdentity.version
        let posterBoardMode = PosterBoardApplyModeSettings.resolved(
            deviceVersion: modeVersion,
            buildVersion: modeIdentity.buildVersion)
        let hasPosterBoardTemplates = templates.templates.contains { $0.isPosterBoard && !$0.requiresSparserestore }
        if (posterBoard.isActive || hasPosterBoardTemplates) && posterBoardMode == .airlift {
            try checkAirliftCanApply(posterBoard: posterBoard,
                templates: templates.templates.filter { $0.isPosterBoard && !$0.requiresSparserestore },
                deviceVersion: modeVersion, buildVersion: modeIdentity.buildVersion)
        }

        // A reset and a wallpaper selection cannot ride the same run, and the
        // reference's own code is why: `apply_tweak` returns on its reset branch
        // before it ever reads the packs, so such a run empties the store and
        // installs none of the wallpapers the page still shows as selected. This
        // port inherits that shape, and the reset survives a failed run (it is
        // cleared only when an apply succeeds), so the two really can be armed at
        // once without the user meaning to — a run that then succeeded would read
        // as "applying wallpapers erased every wallpaper". Refuse, and name both
        // halves instead of silently preferring the destructive one.
        if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
            let carriesWallpapers = !posterBoard.tendies.isEmpty || posterBoard.video != nil
                || hasPosterBoardTemplates
            if carriesWallpapers {
                throw GoldenNuggetError("PosterBoard 页已有一个待执行的重置："
                    + "（\(posterBoard.describe)），同时还选中了壁纸。重置运行"
                    + "不会安装任何壁纸——它会清空库，并在读取壁纸包之前就返回"
                    + "——所以这样应用会抹掉所有壁纸且不新增任何一张。请"
                    + "关闭重置来安装壁纸，或者取消选择壁纸来执行重置。")
            }
            log("PosterBoard: \(posterBoard.describe) — this run clears the store and installs "
                + "nothing.")
        }

        // Templates, if the page has any.  Two routes, and which one a template
        // takes is decided by its own `domain` — `templates_tweak.apply_tweak`
        // makes the same split: a PosterBoard template rides the wallpapers, and
        // everything else is walked here into payloads.
        var templatePayloads: [TweakPayload] = []
        var posterBoardTemplates: [TemplateFile] = []
        if templates.isActive {
            log("Templates: \(templates.describe)")
            // ReplaceOption URLs belong to the current selection. Keep their
            // staging files available for this apply and any subsequent retry.
            for entry in templates.undeliverable {
                log("  ⚠️ \(entry.template.title) was not delivered: \(entry.reason)")
            }
            let deliverable = templates.templates.filter { !$0.requiresSparserestore }
            let work = AppPaths.templatesWorkDirectory
            try? FileManager.default.removeItem(at: work)
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            } catch {
                throw GoldenNuggetError("无法创建模板工作目录："
                    + "(\(work.lastPathComponent)): \(error.localizedDescription)")
            }
            for template in deliverable {
                if template.isPosterBoard {
                    // Left for `PosterBoard.compile`: its extracted tree has to
                    // be walked by `PosterBoardBuilder`, which is what turns a
                    // descriptor into a wallpaper.
                    posterBoardTemplates.append(template)
                    log("  → \(template.title): rides with the wallpapers (domain "
                        + "\(template.domain))")
                    continue
                }
                log("  → \(template.title): \(template.effectiveDomain)")
                templatePayloads += try TemplateDelivery.payloads(
                    for: template, into: work, log: { AppLog.write($0) })
            }
            if !templatePayloads.isEmpty {
                let total = templatePayloads.reduce(0) { $0 + $1.byteCount }
                log("Templates: \(templatePayloads.count) payload(s) ("
                    + ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
                    + ")")
            }
        }

        // The in-process route: `worse_query` gives this process a sandbox
        // extension for PosterBoard's container, so there is no tunnel to open,
        // no pairing record to consult and no backup to take. It runs here —
        // after the pack/template lists are built and before `prepareRun` —
        // because that is the last point at which the whole run can succeed
        // without a device connection. It carries wallpapers only; anything
        // else in the same selection is refused rather than silently dropped.
        if posterBoardMode == .worseQuery && (posterBoard.isActive || !posterBoardTemplates.isEmpty) {
            try checkLocalCanApply(
                posterBoard: posterBoard,
                templates: posterBoardTemplates,
                hasOtherPayloads: !skipSetup.payloads.isEmpty || !tweakPayloads.isEmpty
                    || !statusBarPayloads.isEmpty || !templatePayloads.isEmpty
                    || !communityPayloads.isEmpty,
                deviceVersion: modeVersion)
            log("PosterBoard: \(posterBoard.describe) — on-device, no tunnel")
            let effect = try await PosterBoardLocal.apply(
                selection: posterBoard,
                templates: posterBoardTemplates,
                deviceVersion: modeVersion,
                log: { AppLog.write($0) },
                progress: { overall in self.logProgress("posterboard local", overall) })
            lastPosterBoardEffect = effect
            log("Apply succeeded: the wallpapers are in PosterBoard's container; "
                + "effect — \(effect.headline). No pairing, no tunnel and no backup "
                + "were needed for the write.")
            return
        }

        let udid = try await prepareRun()
        // Resolved once, here, because two stages need it: the PosterBoard compile (its
        // reset preferences change at 26.4) and the manifest-format fork inside
        // `deliver`.  `resolvedDeviceVersion` carries the reasoning for refusing to
        // guess — a device whose version cannot be read must not be treated as iOS 26.
        let version = try await resolvedDeviceVersion(deviceVersion)
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        log("device version for the manifest-format fork: \(version) (major \(major))")

        // PosterBoard, if the page has anything. Two mechanisms, chosen above:
        // the store's database first — a wallpaper exists only once it has a row in
        // it — and then the wallpapers themselves, unless AirLift is doing it, in
        // which case there is no database and no payload: the injection into the
        // container *is* the apply.
        var posterBoardPayloads: [TweakPayload] = []
        var posterBoardSnapshotDirectory: URL?
        var posterBoardInjectedInContainer = false
        if (posterBoard.isActive || !posterBoardTemplates.isEmpty) && posterBoardMode == .direct {
            log("PosterBoard: \(posterBoard.describe) — direct over the pairing tunnel, no backup")
            try checkDirectCanApply(selection: posterBoard, templates: posterBoardTemplates,
                                    deviceVersion: version, buildVersion: modeIdentity.buildVersion)
            try await applyPosterBoardOverDirect(selection: posterBoard,
                                                 templates: posterBoardTemplates,
                                                 deviceVersion: version,
                                                 buildVersion: modeIdentity.buildVersion)
            posterBoardInjectedInContainer = true
        } else if (posterBoard.isActive || !posterBoardTemplates.isEmpty) && posterBoardMode == .airlift {
            log("PosterBoard: \(posterBoard.describe) — over AirLift, no backup")
            try await applyPosterBoardOverAirlift(selection: posterBoard,
                                                 templates: posterBoardTemplates,
                                                 deviceVersion: version,
                                                 buildVersion: modeIdentity.buildVersion)
            posterBoardInjectedInContainer = true
        } else if posterBoard.isActive || !posterBoardTemplates.isEmpty {
            // A PosterBoard template is a wallpaper source even when no pack and
            // no video were picked, so it opens this branch by itself — the
            // reference's `apply_tweak` does the same (`len(tendies) == 0 and
            // len(templates) == 0 and videoFile == None` is the only early
            // return, and `templates` is one of the three terms).
            if posterBoard.isActive {
                log("PosterBoard: \(posterBoard.describe)")
            } else {
                log("PosterBoard: \(posterBoardTemplates.count) template(s) and nothing else")
            }
            var structureVersion = PosterBoard.fallbackStructureVersion
            var database: URL?
            var preservedPosterBoardFiles: [TweakPayload] = []
            if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
                // Resets synthesize their own store state; additions, including
                // template-only descriptors, must start with the device's database.
                log("PosterBoard: reset only — no database is needed, and none is fetched.")
            } else {
                // Feedback #21: the targeted fetch is gone. Every
                // mobilebackup2 pull on Grace's device dies at the directory
                // listing, so the database now comes from this app's own
                // copies — the cache of an earlier fetch, or an empty store
                // built on the spot — and never from a pull. Nothing is
                // preserved from the live container (there is no snapshot
                // without a pull), which the source label in the log states.
                let local = try PosterBoardBackup.localDatabase(
                    udid: udid, log: { AppLog.write($0) })
                database = local.database
                structureVersion = local.structureVersion
                preservedPosterBoardFiles = []
                posterBoardSnapshotDirectory = nil
                log("PosterBoard: database source — \(local.sourceLabel); "
                    + "no existing container files are preserved (no pull)")
            }
            posterBoardPayloads = try await PosterBoard.compile(
                selection: posterBoard,
                templates: posterBoardTemplates,
                structureVersion: structureVersion,
                database: database,
                preservedPayloads: preservedPosterBoardFiles,
                includeSnapshotFiles: posterBoardSnapshotDirectory == nil,
                deviceVersion: version,
                workingDirectory: PosterBoard.workDirectory,
                log: { AppLog.write($0) })
            let onDisk = posterBoardPayloads.filter { $0.source != nil }.count
            let total = posterBoardPayloads.reduce(0) { $0 + $1.byteCount }
            log("PosterBoard: \(posterBoardPayloads.count) payload(s), \(onDisk) of them on disk "
                + "(\(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)))")
        }

        // Skip setup, then the tweaks, then the status bar, then the wallpapers: one
        // array, one pass through the injector, which derives the directory rows from
        // each payload's path.  The order is the reference's — `add_skip_setup`
        // ahead of the tweaks, and `apply_classic_tweak` / `apply_ios27_tweak`
        // before the wallpapers — and it only actually matters for the two
        // skip-setup files, which land in the order they are appended.
        let payloads = skipSetup.payloads + tweakPayloads + statusBarPayloads
            + posterBoardPayloads + templatePayloads

        // Wallpapers-only run in AirLift mode: the injection already happened and
        // it resprings on its way out, so running the backup/restore tail here
        // would buy a full protective pull for an empty payload list.
        if payloads.isEmpty && posterBoardInjectedInContainer {
            log("Apply succeeded: the wallpapers are in PosterBoard's container and it has "
                + "refreshed — no backup was taken.")
            return
        }

        try await deliver(payloads: payloads, udid: udid, version: version, label: "应用",
                          posterBoardSnapshot: posterBoardSnapshotDirectory) {
            log("Apply succeeded: the device confirmed it finished.")
            log("Reboot the device so the injected preferences take effect.")
            if posterBoardInjectedInContainer {
                log("The wallpapers went in through a direct route and are already live; only "
                    + "the tweaks above needed the reboot.")
            } else if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
                log("The PosterBoard store was cleared. Reboot the device, then add wallpapers "
                    + "again — a reset makes the locally cached database copy stale, so the "
                    + "next apply rebuilds from an empty store database.")
            } else if posterBoard.isActive {
                log("Reboot the device so the PosterBoard store picks the new wallpapers up.")
            }
        }
        // A reset just emptied the device store, so the locally cached
        // database copy now describes wallpapers that no longer exist.
        // Drop it: the next apply rebuilds from an empty store database
        // instead of resurrecting the cleared rows (feedback #21).
        if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
            let cached = PosterBoardBackup.cachedDatabase(udid: udid)
            if FileManager.default.fileExists(atPath: cached.path) {
                try? FileManager.default.removeItem(at: cached)
                log("PosterBoard: dropped the locally cached store database — "
                    + "the reset made it stale.")
            }
        }
        do { try CommunityApplyRecord.record(communityPayloads, udid: udid) }
        catch { log("Community apply history could not be saved: \(error.localizedDescription)") }
    }

    func resetCommunityTweaks() async throws {
        try await loggedRun("community reset") {
            clearCancel()
            clearProgress()
            let udid = try await prepareRun()
            let version = try await resolvedDeviceVersion("")
            let plan = try CommunityApplyRecord.resetPlan(udid)
            for path in plan.remaining { log("Community file requires manual recovery: \(path)") }
            guard !plan.payloads.isEmpty else {
                throw GoldenNuggetError("没有已记录的可重置的托管偏好。其他被替换的文件需要手动恢复：\(plan.remaining.joined(separator: ", "))")
            }
            try await deliver(payloads: plan.payloads, udid: udid, version: version, label: "社区重置") {
                log("Community Managed Preferences reset. Reboot the device.")
            }
            try CommunityApplyRecord.didReset(udid)
        }
    }

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
                + "请切换到「恢复式」来应用全部内容。"
                + DriftRestoreGate.unavailableSuffix)
        }
        if selection.fullReset || !selection.resetModes.isEmpty {
            throw GoldenNuggetError("直刷无法重置 PosterBoard 库——它只会添加壁纸。"
                + "要重置，请把刷入方式切换到「恢复式」。"
                + DriftRestoreGate.unavailableSuffix)
        }
        if selection.video != nil {
            throw GoldenNuggetError("直刷无法应用 PosterBoard 视频：它的帧是为恢复准备的。"
                + "请把刷入方式切换到「恢复式」。"
                + DriftRestoreGate.unavailableSuffix)
        }
        if selection.tendies.contains(where: \.isUnsafeContainer) {
            throw GoldenNuggetError("包含商店数据库的壁纸包只能用恢复式。")
        }
        let reason = PosterBoardDirect.unavailableReason(deviceVersion: deviceVersion,
                                                         buildVersion: buildVersion)
        guard reason.isEmpty else { throw GoldenNuggetError(reason) }
        guard FileManager.default.fileExists(atPath: AppPaths.pairingFile.path) else {
            throw GoldenNuggetError("直刷需要一份配对记录，但还没有保存任何一份。"
                + "请先在首页导入一份，或者改用「本机直刷」。")
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
        try await PosterBoardDirect.apply(
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
                + "还带有容器文件；请切换到「恢复式」来应用全部内容。"
                + DriftRestoreGate.unavailableSuffix)
        }
        if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
            throw GoldenNuggetError("AirLift 无法重置 PosterBoard 库——它只会添加"
                + "壁纸。要重置，请把应用模式切换到「恢复式」。"
                + DriftRestoreGate.unavailableSuffix)
        }
        if posterBoard.video != nil {
            throw GoldenNuggetError("AirLift 无法应用 PosterBoard 视频：它的帧是"
                + "是为恢复准备的。请把应用模式切换到「恢复式」。"
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
            throw GoldenNuggetError("本机直刷只能写入壁纸：所选内容里还有调整、跳过设置、"
                + "状态栏或其他模板文件，它们不会通过这条路径送达。请只保留壁纸，"
                + "或改用其他刷入方式。")
        }
        if templates.contains(where: \.isContainer) {
            throw GoldenNuggetError("本机直刷只安装模板描述文件。所选模板还带有容器文件；"
                + "请改用「恢复式」来应用全部内容。"
                + DriftRestoreGate.unavailableSuffix)
        }
        if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
            throw GoldenNuggetError("本机直刷无法重置 PosterBoard 库——它只会添加壁纸。"
                + "要重置，请把刷入方式切换到「恢复式」。"
                + DriftRestoreGate.unavailableSuffix)
        }
        if posterBoard.video != nil {
            throw GoldenNuggetError("本机直刷无法应用 PosterBoard 视频：它的帧是为恢复准备的。"
                + "请把刷入方式切换到「恢复式」。"
                + DriftRestoreGate.unavailableSuffix)
        }
        if posterBoard.tendies.contains(where: \.isUnsafeContainer) {
            throw GoldenNuggetError("包含商店数据库的壁纸包只能用恢复式。")
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
        try await PosterBoardAirlift.apply(
            selection: selection,
            templates: templates,
            structureVersion: structureVersion,
            deviceVersion: deviceVersion,
            pairingPath: AppPaths.pairingFile.path,
            log: { AppLog.write($0) },
            progress: { overall in self.logProgress("posterboard airlift", overall) }
        )
    }

    /// Fetch only the device's PosterBoard database, without applying anything.
    ///
    /// The page's own action, and the reference has the same one (its "Fetch
    /// Database File" wizard in `pb_dialog.py`) for the same reason: the fetch is
    /// the one stage of a wallpaper apply that can fail on its own terms — the
    /// device decides whether it will upload the container — so being able to run
    /// it alone, watch it, and retry is worth a button. The result is cached at
    /// `PosterBoardBackup.cachedDatabase(udid:)`, and an apply reuses nothing:
    /// it fetches its own, because a copy fetched before a reset is stale.
    func fetchPosterBoardDatabase() async throws {
        try await loggedRun("posterboard database fetch") {
            try await fetchPosterBoardDatabaseRun()
        }
    }

    private func fetchPosterBoardDatabaseRun() async throws {
        AppLog.shared.memory.reset()
        clearCancel()
        clearProgress()
        let stage = StageTimer("RUN posterboard database fetch")
        defer { stage.done() }

        let udid = try await prepareRun()
        _ = try await PosterBoardBackup.fetch(
            backupRoot: AppPaths.posterBoardFetchRoot, udid: udid,
            onProgress: { overall in self.logProgress("posterboard backup progress", overall) },
            log: { AppLog.write($0) })
        log("PosterBoard database fetched and validated.")
    }

    /// Inject the PosterBoard packs over AirLift, and nothing else.
    ///
    /// The home page's Apply is one combined run — tweaks and wallpapers ride
    /// together through a single protective backup — which is right for a
    /// backup-mode selection and wrong for this one: AirLift writes the
    /// descriptors straight into the container, so a run that carries nothing
    /// but wallpapers should not buy a backup at all. That early return lives
    /// in the combined path and is reached only when no tweak is selected, so
    /// this is the same injection on its own, with no payloads to deliver and
    /// no mode switch to remember.
    ///
    /// - Parameters:
    ///   - selection: the page's selection. Only its packs are honoured, exactly
    ///     as in the combined run.
    ///   - deviceVersion: what the page already read; the constraints are checked
    ///     against it rather than resolved again over a second connection.
    func applyPosterBoardViaAirlift(_ selection: PosterBoardSelection,
                                    deviceVersion: String) async throws {
        try await loggedRun("posterboard airlift apply") {
            try await applyPosterBoardViaAirliftRun(selection, deviceVersion: deviceVersion)
        }
    }

    private func applyPosterBoardViaAirliftRun(_ selection: PosterBoardSelection,
                                               deviceVersion: String) async throws {
        AppLog.shared.memory.reset()
        clearCancel()
        clearProgress()
        let stage = StageTimer("RUN posterboard airlift apply")
        defer { stage.done() }

        try await HotLoadService.requireAllowed(features: ["PosterBoard"])
        let identity = await DeviceIdentity.read()
        let version = identity.version.isEmpty ? deviceVersion : identity.version
        try checkAirliftCanApply(posterBoard: selection,
            deviceVersion: version,
            buildVersion: identity.buildVersion)
        log("PosterBoard: \(selection.describe) — over AirLift, no backup")
        try await applyPosterBoardOverAirlift(selection: selection,
                                              deviceVersion: version,
                                              buildVersion: identity.buildVersion)
        log("PosterBoard: injected over AirLift and resprung. No backup was taken, and no "
            + "tweak was delivered — the home page's Apply is what delivers those.")
    }

    // MARK: - The shared delivery tail
    //
    // Both applies end in the same stages, and the order is load-bearing:
    // the manifest-format fork decides which manifest shape gets synthesised
    // on the host (no backup is pulled on either branch — feedback #21), the
    // injection writes this run's rows into it, and the restore is what
    // delivers any of it.

    /// One payload set through stages 1–4.  `udid` and `version` come from the caller:
    /// the PosterBoard stage talks to the device (and needs the version) before this
    /// runs, so resolving them again here would be a second answer to a settled question.
    private func deliver(
        payloads: [TweakPayload],
        udid: String,
        version: String,
        label: String,
        posterBoardSnapshot: URL? = nil,
        onSuccess: () -> Void
    ) async throws {
        // The two versions take opposite paths, and the split is the
        // reference's one-line fork (`backup.py:113`) widened to the whole run:
        // iOS 26 speaks legacy MBDB and can have a backup built for it from
        // nothing; iOS 27+ speaks the modern sqlite Manifest.db, which this
        // app now also builds from nothing (feedback #21 removed the
        // protective pull — every mobilebackup2 backup-direction exchange
        // dies on Grace's device). Comparing "26.0" against "27.0" lexically
        // would put 26.9 on the wrong side, so compare the major component.
        //
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        // Development mode can force the iOS 26 branch, so the reported version is no
        // longer the last word on which branch runs -- only the default for it. Read
        // once, here, and both decisions below quote the same snapshot.
        let dev = DevSettings.effective
        let ios27 = major >= 27 && !dev.forcePartialRestore
        let hasEligibility = payloads.contains { $0.domain == "SysContainerDomain-com.apple.eligibilityd" }
        if hasEligibility && !ios27 {
            throw GoldenNuggetError("Siri AI 覆盖需要 iOS 27 的 sqlite 清单格式，且设备不能开启加密本地备份（运行前检查会核对）。请关闭强制部分恢复后重试。")
        }
        // Reported before the fork, because this number *is* the fork: the
        // branch lines below say where the run went, this says why.
        log("device version for the manifest-format fork: \(version) (major \(major))")
        if dev.forcePartialRestore {
            log("development mode: forcing the iOS 26 branch on a major \(major) device "
                + "-- no protective backup will be pulled")
        }

        // iOS 26: a Partial Restore, built rather than pulled -- an empty device
        // directory, the host-side manifests, then this run's rows. Nothing was
        // pulled, so there is no device state to reconcile against and the
        // prune would only discard what this run just wrote.
        //
        // iOS 27: the same shape since feedback #21 — a backup synthesised on
        // the host (empty Files-table Manifest.db, host-side manifests, this
        // run's rows), nothing pulled and nothing pruned. The historical
        // objection to synthesis was `restored` rejecting a domain it cannot
        // resolve ("Failed to prepare INSERT for
        // ManagedPreferencesDomain"); the injector answers that by
        // registering AppDomain payloads in Manifest.plist itself
        // (`pruneAndInject`'s applications pass), and the encrypted-backup
        // premise the pulled Manifest.plist used to prove is now checked
        // before every run by `preflightBackupEncryption`.
        let backupRoot: URL
        let prune: Bool
        if ios27 {
            log("Manifest format: sqlite (iOS 27+ path), synthesised locally — no backup pulled")
            backupRoot = try synthesizedBackup(udid: udid)
            prune = false
            // No media stage (feedback #27): the reference pulled the
            // device's photos and videos over AFC at exactly this point —
            // after the synthesised backup, before the restore — which on
            // a full camera roll meant gigabytes copied into the container
            // before the restore even started, in the one flow whose whole
            // point (#21) is that nothing is pulled. The stage is removed,
            // not gated on `DevSettings.skipAfcMedia`: no setting can bring
            // it back, and the line below is the run log's proof that the
            // delivery went straight from synthesis to the restore.
            log("AFC media 已按 Drift 口径停用 — 刷入全程不拉取设备媒体")
        } else {
            log("Manifest format: legacy MBDB (iOS 26 path), built from nothing")
            backupRoot = try await partialRestore(udid: udid)
            prune = false
        }

        clearProgress()
        log("Pruning and injecting tweaks…")
        try await BackupInjector.pruneAndInject(
            backupRoot: backupRoot,
            udid: udid,
            tweakPayloads: payloads,
            posterBoardSnapshot: posterBoardSnapshot,
            prune: prune,
            ios27: ios27
        )

        try await runRestore(backupRoot: backupRoot, udid: udid, label: label,
                             onSuccess: onSuccess)
    }

    /// Put the named pages back to stock, on the device.
    ///
    /// A port of `device_manager.reset_tweaks` (`device_manager.py:1104`): a
    /// fixed set of files written over the device's own, with nothing read back
    /// first — no psysbackup capture, on either branch. The page set comes from
    /// the picker the reference's `ResetDialog` offers, not from this app's
    /// tweak selection; the two are unrelated, and the reference's dialog is
    /// likewise built from `get_resettable_pages`, not from what is enabled.
    ///
    /// It is the same pipeline as `applyTweaks` with a different payload list, so
    /// it reuses `protectiveBackup` / `partialRestore` / `pruneAndInject` /
    /// `runRestore` rather than growing a second restore path. The two branches
    /// differ in what a nulled file is written as (0 bytes vs. a valid empty
    /// plist — `TweakReset` has the table and the reason) and in which manifest
    /// the run needs, for the same reason the apply forks:
    ///
    /// * **iOS 27+** speaks the modern sqlite `Manifest.db`. The reset used
    ///   to pull the protective backup here because a synthesized manifest
    ///   was rejected for lacking the device's domain registration; since
    ///   feedback #21 no flow pulls a backup at all (every pull dies on
    ///   Grace's device), so the reset synthesises one exactly as an apply
    ///   does and lets the injector register the domains it delivers.
    /// * **iOS 26** speaks legacy MBDB and can have a backup built for it from
    ///   nothing, so the reset synthesises one.
    ///
    /// What is deliberately absent is the reference's `clear_lastapply`: it drops
    /// the apply record so a later apply does not skip Phase 2 against a reset
    /// device, and there is no phase-2 skip in this port to guard. The app's own
    /// selection is left alone too, exactly as the reference leaves the tweaks
    /// page as the user had it — the reset is of the *device*, and the selection
    /// is what would put the tweaks back.
    func resetPages(pages: Set<ResetPage>) async throws {
        try await loggedRun("page reset") { try await resetPagesRun(pages: pages) }
    }

    private func resetPagesRun(pages: Set<ResetPage>) async throws {
        try await HotLoadService.requireAllowed(features: Set(pages.map(\.title)))
        AppLog.shared.memory.reset()
        clearCancel()
        clearProgress()
        let runStage = StageTimer("RUN page reset")
        defer { runStage.done() }

        guard !pages.isEmpty else {
            throw GoldenNuggetError("没有选择任何页面——没有可重置的内容。")
        }

        let udid = try await prepareRun()

        // Read the version here for the same reason the apply does: the pages
        // read it before lockdown answers, so a value of "" would put a 27
        // device on the 26 branch and hand it 0-byte plists.
        let version = try await resolvedDeviceVersion("")
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        let dev = DevSettings.effective
        let ios27 = major >= 27 && !dev.forcePartialRestore

        let plan = TweakReset.plan(pages: pages, ios27: ios27)
        guard !plan.payloads.isEmpty else {
            throw GoldenNuggetError("所选页面都对应不到任何文件——没有可重置的内容。")
        }

        // The reference appends the skip-setup files to the *reset's* file list
        // too (`add_skip_setup(files_to_restore, uses_domains)`, called after the
        // null loop and before `start_restore`), subject to its own gate — which
        // on iOS 27 only passes when the file list already restores real domains,
        // and in the reset path that means the Daemons page was ticked. Reproduced
        // as written; see `TweakReset.skipSetupAllowed(pages:ios27:)`.
        let skipSetupOn = SkipSetupSettings.shared.skipSetupEnabled
        let skipSetup: SkipSetup.Build
        if !skipSetupOn {
            skipSetup = SkipSetup.Build(payloads: [], warnings: [])
        } else if plan.skipSetupAllowed {
            skipSetup = SkipSetup.build(supervised: false, organizationName: "")
        } else {
            skipSetup = SkipSetup.Build(payloads: [], warnings: [])
            log("Skip Setup is on, but the reference omits its two files here: on iOS 27 "
                + "the reset restores no real domain unless the Daemons page is ticked, "
                + "and that is its `add_skip_setup` condition. Tick Daemons, or reset on "
                + "iOS 26, to include them.")
        }

        log("Reset: \(pages.count) page(s) — \(plan.targets.count) file(s) on iOS \(version)")
        for target in plan.targets {
            log("  → \(target.path) [\(target.kind.rawValue), "
                + "\(target.contents.count) bytes]")
        }
        for item in plan.skipped { log("  ⚠️ skipped \(item.label): \(item.reason)") }
        for page in ResetPage.allCases where pages.contains(page) {
            log("  page \(page.title): \(page.locations.count) file(s)")
        }
        if ios27 {
            log("iOS 27 branch: a nulled file is written as a valid empty plist, not 0 bytes — "
                + "a truncated plist is a SpringBoard boot loop on this release. Nothing is read "
                + "back from the device first: this is the reference's own no-capture fallback, "
                + "not a psysbackup restore of the original values.")
        } else {
            log("iOS 26 branch: a nulled file is written as 0 bytes, over a synthesised MBDB "
                + "backup (no device content pulled).")
        }

        let backupRoot: URL
        let prune: Bool
        if ios27 {
            log("Manifest format: sqlite (iOS 27+ path), synthesised locally — no backup pulled")
            backupRoot = try synthesizedBackup(udid: udid)
            prune = false
        } else {
            log("Manifest format: legacy MBDB (iOS 26 path), built from nothing")
            backupRoot = try await partialRestore(udid: udid)
            prune = false
        }

        try await BackupInjector.pruneAndInject(
            backupRoot: backupRoot,
            udid: udid,
            // Same order as the reference's file list: the daemons file first, then
            // the nulled ones, then the two skip-setup files last — the reference
            // calls `add_skip_setup` after the null loop.
            tweakPayloads: plan.payloads + skipSetup.payloads,
            prune: prune,
            ios27: ios27
        )

        try await runRestore(backupRoot: backupRoot, udid: udid, label: "页面重置") {
            log("Reset succeeded: the device confirmed it finished.")
            log("The pages above are back to their defaults. The selections in this app are "
                + "untouched — applying again would write the tweaks back.")
            log("Reboot the device so the restored files take effect.")
        }
    }

    // MARK: - Media facade

    /// Copy the device's photos and videos into the app container without a
    /// tweak run behind it.
    ///
    /// **Disabled outright in Drift (feedback #27).** The reference started
    /// one of these when the setup guide finished and topped it up on every
    /// launch, so the media store would be full when "Restore media" needed
    /// it. Drift has no media feature and a standing rule that nothing is
    /// ever pulled from the device (#21), so the facade stays only so any
    /// stale caller lands somewhere harmless: it logs the refusal and does
    /// nothing. The refusal deliberately ignores
    /// `DevSettings.skipAfcMedia` — this is Drift policy enforced at the
    /// entry layer, not a development-mode preference.
    ///
    /// - Parameters:
    ///   - reason: what asked for this, quoted in the log so two callers can be
    ///     told apart in a bug report.
    ///   - force: formerly skipped the rate limit; now ignored.
    func startAutomaticMediaPull(reason: String, force: Bool = false) {
        log("AFC media 已按 Drift 口径停用 — 自动拉取不再启动（\(reason)）")
    }

    /// Put the container's photos and videos back on the device.
    ///
    /// The counterpart of the automatic pull, and the one button the user is
    /// expected to press: after a reset — or after reinstalling the app's data —
    /// this writes every stored file back to the Media root, verifying each
    /// write. Runs as a run (`InFlightCall`), so it cannot overlap with an apply.
    func restoreMedia() async throws {
        try await loggedRun("media restore") {
            // The restore writes to the device while a pull reads from it; the
            // store's own lock would reject this with a generic "busy", which
            // reads like a stuck app rather than a copy still in progress.
            guard !AfcMediaBackup.isTransferActive else {
                throw GoldenNuggetError("从设备拷贝的操作还在运行。"
                    + "等它完成之后就可以开始恢复媒体——它已经拷好的内容"
                    + "都已经保留下来了。")
            }
            let manifest = try AfcMediaBackup.read()
            guard !manifest.entries.isEmpty else {
                throw GoldenNuggetError(
                    "媒体库是空的——没有可放回设备的内容。媒体页的"
                    + "「拉取」按钮可以填充它，设置过程也会自动填充。")
            }
            let bytes = manifest.entries.reduce(0) { $0 + $1.size }
            log("AFC media: restoring \(manifest.entries.count) file(s), "
                + "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) "
                + "to the device")
            try await AfcMediaBackup.push { self.log($0) }
            log("AFC media: restore finished — the local copies stay in the container "
                + "until the Media page empties them")
        }
    }

    // MARK: - Protective flow stages
    //
    // The full flow, kept in one place because the order is load-bearing.

    /// Stage 1: the working backup, into `<Documents>/<udid>/`.
    ///
    /// A Partial Restore, so it is built rather than pulled: an empty device
    /// directory, then the host-side manifests, then this run's rows and
    /// payloads. There is no user content to preserve and nothing to wipe, which
    /// is why the reference's three-phase flow (and its safe-state recovery) has
    /// no part here on iOS 26 -- the restore lands on the live device.
    private func partialRestore(udid: String) async throws -> URL {
        let backupRoot = AppPaths.fullBackupRoot(udid: udid)
        try resetDirectory(backupRoot)
        log("Partial Restore: synthesising backup at \(backupRoot.lastPathComponent) "
            + "(no device content pulled)")
        return backupRoot
    }

    /// An iOS 27 backup synthesised on the host, the #21 replacement for the
    /// protective pull in the delivery tail: an empty device directory, a
    /// Manifest.db carrying only the `Files` table, and then whatever
    /// `pruneAndInject` writes into it (host-side manifests via
    /// `HostManifests.ensure`, then this run's rows). Same root as the flows
    /// it replaces, so the restore stage sees the shape it always saw.
    private func synthesizedBackup(udid: String) throws -> URL {
        let backupRoot = AppPaths.fullBackupRoot(udid: udid)
        try resetDirectory(backupRoot)
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        try ManifestStore(deviceDir: deviceDir).createEmptyManifestDB()
        log("Synthesised backup at \(backupRoot.lastPathComponent) "
            + "(no device content pulled — feedback #21)")
        return backupRoot
    }

    // MARK: - Local backup management (feedback #21)
    //
    // The two user-facing companions of the no-pull rule: a backup that is
    // already on disk can still be written back, and it can be deleted —
    // neither needs the pull direction that no longer works.

    /// The newest local backup tree: a `<Documents>/<udid>/<udid>/` folder
    /// holding a manifest. Pure filesystem scan — no device contact, so the
    /// settings page can offer the two actions below without a tunnel.
    static func localBackupCandidate() -> (root: URL, udid: String)? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: URL.documents, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        var best: (root: URL, udid: String, date: Date)?
        for entry in entries where entry.hasDirectoryPath {
            let name = entry.lastPathComponent
            let deviceDir = entry.appendingPathComponent(name, conformingTo: .data)
            let hasManifest = fm.fileExists(atPath: deviceDir.appendingPathComponent("Manifest.db").path)
                || fm.fileExists(atPath: deviceDir.appendingPathComponent("Manifest.mbdb").path)
            guard hasManifest else { continue }
            let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if best == nil || date > best!.date {
                best = (entry, name, date)
            }
        }
        return best.map { (root: $0.root, udid: $0.udid) }
    }

    /// Write an existing local backup back to the device. Restore is the
    /// write direction only — it never pulls — so it stays available under
    /// the #21 rule that killed every backup-direction exchange.
    func restoreLocalBackup() async throws {
        try await loggedRun("local backup restore") {
            clearCancel()
            clearProgress()
            let udid = try await prepareRun()
            guard let candidate = Self.localBackupCandidate() else {
                throw GoldenNuggetError("本地没有可恢复的备份。")
            }
            guard candidate.udid == udid else {
                throw GoldenNuggetError("本地备份属于另一台设备，与当前设备不一致，已停止恢复。")
            }
            log("Restoring the local backup back to the device "
                + "(write-only — nothing is pulled)")
            try await runRestore(backupRoot: candidate.root, udid: udid, label: "恢复备份") {
                log("Restore succeeded: the device confirmed it finished.")
                log("Reboot the device so the restored files take effect.")
            }
        }
    }

    /// Delete the local backup tree. Local only — no device contact.
    func deleteLocalBackup() throws {
        guard let candidate = Self.localBackupCandidate() else {
            throw GoldenNuggetError("本地没有可删除的备份。")
        }
        try FileManager.default.removeItem(at: candidate.root)
        log("Deleted the local backup (\(candidate.root.lastPathComponent))")
    }

    /// A real protective backup into `<Documents>/<udid>/`.
    private func protectiveBackup(udid: String) async throws -> URL {
        let backupRoot = AppPaths.fullBackupRoot(udid: udid)
        try resetDirectory(backupRoot)
        try await ProtectiveBackup.run(backupRoot: backupRoot, udid: udid) { overall in
            self.logProgress("backup progress", overall)
        }
        log("Protective backup complete.")
        clearProgress()
        return backupRoot
    }

    // MARK: - Research diagnostics (feedback #31)

    /// Research builds only: run ONE protective pull and nothing else.
    ///
    /// This is the spare-device diagnosis entry for the pull silence of
    /// feedback #14/#21: the device asks for the state files, asks for a
    /// directory listing, and then never speaks again. The entry exists so
    /// that session can be run on its own — with the [MB2-PULL] trace
    /// live — without going anywhere near prune, injection or restore.
    /// It deliberately does NOT consult the mode judgement: a diagnostic
    /// that needs the judge's permission to run could never observe the
    /// systems that need it most (on the spare device's iOS 27.3 the
    /// judge can only land on the restore tier, which is closed). The
    /// judge's landing for the connected device is still written to the
    /// log, in full, so the report shows where the version falls. The
    /// restore gate stays closed in this build — the pull is the only
    /// mobilebackup2 direction this entry can start.
    ///
    /// Returns a one-line outcome for the Settings row that called it.
    func researchDiagnosticPull() async throws -> String {
        guard DriftResearchBuild.isActive else {
            throw GoldenNuggetError("诊断拉取只在研究构建里提供（分发构建没有这个入口）。")
        }
        return try await loggedRun("research diagnostic pull") {
            clearCancel()
            clearProgress()
            let udid = try await prepareRun()
            let identity = await DeviceIdentity.read()
            let tunnelReady = await MainActor.run { TunnelMonitor.shared.status == .ready }
            let verdict = DriftJudge.judge(
                identity: identity,
                selection: PosterBoardSelection(),
                pick: nil,
                tunnelReady: tunnelReady)
            log("[MB2-PULL] research pull: device ProductVersion="
                + "\(identity.version.isEmpty ? "<unread>" : identity.version) "
                + "BuildVersion=\(identity.buildVersion.isEmpty ? "<unread>" : identity.buildVersion) "
                + "ProductType=\(identity.productType.isEmpty ? "<unread>" : identity.productType)")
            log("[MB2-PULL] research pull: judge landing for an empty selection — "
                + "mode \(verdict.mode.title), reason: \(verdict.reason)"
                + (verdict.isBlocked ? " (blocked: \(verdict.blockedReason ?? ""))" : "")
                + "; restore gate closed (the research build does not open it — feedback #31)")
            log("[MB2-PULL] research pull: this entry does not consult the judge — "
                + "it only pulls, and never prunes, injects or restores")
            _ = try await protectiveBackup(udid: udid)
            return "诊断拉取完成：设备备份已拉到本地。下一步到「记录」里点「打包分享记录」，把整包发回分析。"
        }
    }

    // MARK: - Shared run plumbing
    //
    // The sequence below is order-sensitive, so it lives in one place.

    /// Everything a run does before touching the device.
    ///
    /// Returns the device UDID (needed to name the backup root).  Throws
    /// `GoldenNuggetError` for the operator-facing failures.
    private func prepareRun() async throws -> String {
        try await HotLoadService.requireAllowed()
        let minimuxer = Minimuxer.shared()
        guard await testReady(minimuxer) else {
            throw GoldenNuggetError("minimuxer 尚未就绪。请确保 Wi-Fi 和隧道可用（LocalDevVPN 或 WireGuard + em_proxy），然后选择配对文件。")
        }
        guard let udid = try await minimuxer.core.fetchUDID() else {
            throw GoldenNuggetError("无法获取设备 UDID")
        }
        log("UDID: \(udid)")
        log("Tunnel: \(Tunnel.describe())")
        try await Diagnostics.preflightBackupEncryption()
        // Everything after this byte offset is this run's Rust output.
        markRustLog()

        return udid
    }

    /// The version the manifest-format fork branches on — never a guess.
    ///
    /// An empty `fallback` means "the page never managed to read it" (it reads
    /// once, when it appears, and lockdown may not have been answering yet), and
    /// **not** "iOS 26". Parsing it as 0 used to send a 27.0 device down the
    /// legacy branch, which cannot work there: that branch synthesises a backup
    /// from nothing, and what the device answers is
    /// `MBErrorDomain/205 — No keybag in manifest` (2026-09-26).
    ///
    /// So re-read lockdown — `prepareRun()` has just shown it is ready — and
    /// refuse to continue if even that fails. Refusing beats defaulting: the two
    /// branches want different manifest formats, and a wrong pick costs the
    /// operator a whole run plus a puzzle like this one.
    private func resolvedDeviceVersion(_ fallback: String) async throws -> String {
        if !fallback.isEmpty { return fallback }
        log("device version: the caller had none (it read the identity before lockdown answered) "
            + "— re-reading before the format fork")
        let identity = await DeviceIdentity.read()
        guard !identity.version.isEmpty else {
            throw GoldenNuggetError(
                "无法读取设备的 iOS 版本（lockdown 的 ProductVersion），而本次运行"
                + "需要靠它来选择清单格式：iOS 27+ 用 sqlite Manifest.db，iOS 26 "
                + "用旧式 MBDB，两种都在主机上合成、不从设备拉取。请解锁设备、确认隧道已连通，然后再运行一次。")
        }
        log("device version: lockdown answered \(identity.version)")
        return identity.version
    }

    /// Start from an empty backup root.  Both flows need this: the manifest is
    /// merged into, not replaced, so a leftover Manifest.db from a previous run
    /// would leak its rows (and its pruned keep-set) into this one.
    private func resetDirectory(_ url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Clamp and throttle a Rust progress callback down to whole percent.
    ///
    /// The callback fires per file; logging every call appended thousands of
    /// lines and pushed the interesting ones out of the UI list.
    private func logProgress(_ prefix: String, _ overall: Double) {
        let pct = overall < 0 ? 0 : min(overall, 100)
        reportProgress(pct)
        log(String(format: "\(prefix): %.0f%%", pct))
    }

    /// Stage 4: one mobilebackup2 restore, with the iOS-27 transient-channel
    /// retry in front of it.
    ///
    /// `onSuccess` carries only the success wording — the two flows describe
    /// their outcome differently, but the failure line is the same.
    private func runRestore(
        backupRoot: URL,
        udid: String,
        label: String,
        onSuccess: () -> Void
    ) async throws {
        // Say what is being offered before offering it.  Every recorded "the
        // restore said success but only part came back" run so far has had to be
        // reconstructed from the prune / inject / placeholder lines after the
        // fact; this puts the same numbers in one place, at the moment they are
        // still actionable.
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        log(ManifestStore(deviceDir: deviceDir).auditAgainstDisk())

        clearProgress()
        log("Restoring backup… (this is the stage that finalizes on the device)")
        let code = try await ChannelRecovery.retry(
            label: label,
            attempts: 3,
            diagnostics: { await Diagnostics.report() }
        ) {
            try await RestoreRunner.run(backupRoot: backupRoot, sourceIdentifier: udid)
        }

        if code == 0 {
            onSuccess()
        } else {
            // Unreachable while RestoreRunner verifies its own outcome, but kept
            // so a future path that stops doing so cannot fail silently.
            log("restore returned \(code) without confirming completion — inspect the log above.")
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
}
