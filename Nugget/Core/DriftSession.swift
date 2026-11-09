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
    @Published var errorText: String?
    /// True while a wallpaper run is in flight.
    @Published private(set) var running = false

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

    // MARK: - Launch

    /// Wire the engine's log into the run log, restore the pairing record and
    /// start the core. Idempotent: safe to call from every appearance.
    func bootstrap() {
        GoldenNuggetEngine.shared.onLog = { line in RunLog.shared.append(line) }
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
                GoldenNuggetEngine.shared.log("pairing record rejected (\(source)): \(PairingRecord.sourceLabel(raw))")
                continue
            }
            let onDisk = (try? String(contentsOf: dest, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if onDisk != raw {
                do {
                    try raw.write(to: dest, atomically: true, encoding: .utf8)
                    GoldenNuggetEngine.shared.log("pairing record re-imported from \(source) into \(dest.lastPathComponent) (\(PairingRecord.sourceLabel(raw)))")
                } catch {
                    GoldenNuggetEngine.shared.log("pairing record found (\(source)) but could not be written to Documents: \(error.localizedDescription)")
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
        GoldenNuggetEngine.shared.log("pairing file imported: \(PairingRecord.sourceLabel(record)) "
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
        GoldenNuggetEngine.shared.log("pairing reset: record cleared from memory and storage; "
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
        GoldenNuggetEngine.shared.log("tunnel is ready and the core is not — starting minimuxer now")
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
        GoldenNuggetEngine.shared.log("pairing record noticed on disk — adopting it "
            + "(\(PairingRecord.sourceLabel(disk)))")
        adoptPairingFromDisk()
    }

    // MARK: - minimuxer start (ported sequence)

    func startMinimuxer() {
        guard let pairingRaw else { return }
        Self.startLock.lock()
        if Self.startInFlight {
            Self.startLock.unlock()
            GoldenNuggetEngine.shared.log("minimuxer start already in progress — ignoring this request")
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
            guard Tunnel.waitForTunnel(log: { line in GoldenNuggetEngine.shared.log(line) }) else {
                tunnelStage.done("FAILED")
                DispatchQueue.main.async {
                    DriftSession.shared.errorText = "隧道未就绪：\(Tunnel.peerIP):\(Tunnel.servicePort) 不可达。\n\n\(Tunnel.requirements)"
                }
                return
            }
            tunnelStage.done("reachable")
            Task {
                do {
                    let minimuxer = Minimuxer.shared()
                    // File logging has to be enabled before `setLogging`:
                    // that call snapshots the flag when it builds the sink.
                    GoldenNuggetEngine.shared.enableRustFileLogging()
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
                        GoldenNuggetEngine.shared.log("pairing file top-level keys: \(keys.isEmpty ? "(empty)" : keys.sorted().joined(separator: ", "))")
                    } else {
                        GoldenNuggetEngine.shared.log("pairing file: NOT a parseable plist")
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
                    GoldenNuggetEngine.shared.log("minimuxer started. ready=\(isReady)")
                    if !isReady {
                        let reason = readinessFailure ?? "未知原因"
                        let tail = RustLog.tail()
                        GoldenNuggetEngine.shared.log("minimuxer readiness failed: \(reason)")
                        GoldenNuggetEngine.shared.log("minimuxer.log tail:\n\(tail)")
                        await MainActor.run {
                            DriftSession.shared.errorText = "minimuxer 已启动但始终未能就绪。\n\n\(reason)\n\nminimuxer.log 的最后几行：\n\(tail)"
                        }
                    } else {
                        await DriftSession.shared.noteCoreReady()
                    }
                } catch {
                    let tail = RustLog.tail()
                    GoldenNuggetEngine.shared.log("minimuxer.log tail:\n\(tail)")
                    await MainActor.run {
                        DriftSession.shared.errorText = "\(error.localizedDescription)\n\nminimuxer.log 的最后几行：\n\(tail)"
                    }
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
                GoldenNuggetEngine.shared.log("device identity: lockdownd answered on attempt "
                    + "\(attempt + 1), after the first read raced minimuxer's start")
            }
        }
        await DeviceIdentityMonitor.shared.publish(read)
    }

    // MARK: - Wallpaper runs

    func cancelRun() { GoldenNuggetEngine.shared.requestCancel() }

    /// Run one wallpaper apply in an already-decided mode and record it.
    /// Returns a one-line outcome for the page's status area.
    func run(selection: PosterBoardSelection, mode: PosterBoardApplyMode,
             identity: DeviceIdentity) async -> (ok: Bool, message: String) {
        guard !InFlightCall.shared.isRunActive else {
            return (false, "已有一轮刷入正在进行")
        }
        PosterBoardApplyModeSettings.current = mode
        running = true
        RunLog.shared.clear()
        defer { running = false }
        do {
            try await GoldenNuggetEngine.shared.applyTweaks(
                selection: TweakSelection(),
                posterBoard: selection,
                statusBar: StatusBarSelection(),
                templates: TemplateSelection(),
                deviceVersion: identity.version,
                isIPhone: identity.isIPhone,
                deviceModel: identity.productType)
            ApplyHistory.record(mode: mode.title, success: true,
                                device: identity.describe,
                                model: identity.productType, ios: identity.version)
            // The reset flags are one-shot; the calling page clears its own
            // selection on success (this session only ever holds a copy).
            errorText = nil
            return (true, mode == .airlift ? "刷入完成，设备将注销生效" : "刷入完成，设备将重启生效")
        } catch {
            if let failure = error as? TransportFailure, failure.isCancellation {
                GoldenNuggetEngine.shared.log("run cancelled")
                ApplyHistory.record(mode: mode.title, success: false, error: "已取消",
                                    device: identity.describe,
                                    model: identity.productType, ios: identity.version)
                return (false, "刷入已取消")
            }
            GoldenNuggetEngine.shared.log("posterboard apply failed: \(error.localizedDescription)")
            ApplyHistory.record(mode: mode.title, success: false, error: error.localizedDescription,
                                device: identity.describe,
                                model: identity.productType, ios: identity.version)
            return (false, error.localizedDescription)
        }
    }
}

// MARK: - Mode judgement

/// Why a run will use the mode it uses, in one user-facing sentence.
struct DriftModeJudgement {
    var mode: PosterBoardApplyMode
    var reason: String
    /// Set when the user's manual pick was overridden by a hard limit.
    var overriddenPick: PosterBoardApplyMode?
}

enum DriftJudge {
    static let manualKey = "DriftManualMode"

    /// The user's manual pick, or nil for automatic.
    static var manualPick: PosterBoardApplyMode? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: manualKey) else { return nil }
            return PosterBoardApplyMode(rawValue: raw)
        }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: manualKey) }
    }

    /// Decide the delivery mode for a selection, in Drift's order:
    /// hard limits first (video, store reset, store-database packs, system
    /// out of the direct range, unknown device), then the manual pick, then
    /// the automatic default (direct whenever the system allows it).
    ///
    /// The pick arrives as a parameter, not from `manualPick`: the pages hold
    /// it in `@AppStorage` so a menu tap re-renders the judgement card at
    /// once. Reading the UserDefaults-backed static here made the card a
    /// snapshot — it only caught up when some unrelated state (an imported
    /// pack) happened to redraw the page.
    static func judge(identity: DeviceIdentity, selection: PosterBoardSelection,
                      pick: PosterBoardApplyMode?) -> DriftModeJudgement {
        func forced(_ reason: String) -> DriftModeJudgement {
            DriftModeJudgement(mode: .backup, reason: reason,
                               overriddenPick: pick == .airlift ? .airlift : nil)
        }
        if selection.video != nil {
            return forced("视频壁纸只能用恢复式，刷完会重启")
        }
        if selection.fullReset || !selection.resetModes.isEmpty {
            return forced("重置壁纸商店只能用恢复式，刷完会重启")
        }
        if selection.tendies.contains(where: \.isUnsafeContainer) {
            return forced("包含商店数据库的壁纸包只能用恢复式，刷完会重启")
        }
        if identity.version.isEmpty {
            return forced("暂时读不到设备系统信息，按恢复式处理，刷完会重启")
        }
        if AirliftAvailability.isHidden(deviceVersion: identity.version, buildVersion: identity.buildVersion) {
            return forced("当前系统不在直刷支持范围内，用恢复式，刷完会重启")
        }
        if let pick {
            return DriftModeJudgement(
                mode: pick,
                reason: pick == .airlift ? "已手动选择直刷，刷完只注销不重启"
                                         : "已手动选择恢复式，刷完会重启",
                overriddenPick: nil)
        }
        return DriftModeJudgement(mode: .airlift, reason: "当前系统支持直刷，刷完只注销不重启", overriddenPick: nil)
    }
}
