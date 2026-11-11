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

    /// How the last finished run took effect, when it used the in-process
    /// route. The home page shows a manual-respring button from this.
    @Published private(set) var lastEffect: PosterBoardEffect?

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
        DriftEngine.shared.onLog = { line in RunLog.shared.append(line) }
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
                        await MainActor.run {
                            DriftSession.shared.errorText = "minimuxer 已启动但始终未能就绪。\n\n\(reason)\n\nminimuxer.log 的最后几行：\n\(tail)"
                        }
                    } else {
                        await DriftSession.shared.noteCoreReady()
                    }
                } catch {
                    let tail = RustLog.tail()
                    DriftEngine.shared.log("minimuxer.log tail:\n\(tail)")
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
                DriftEngine.shared.log("device identity: lockdownd answered on attempt "
                    + "\(attempt + 1), after the first read raced minimuxer's start")
            }
        }
        await DeviceIdentityMonitor.shared.publish(read)
    }

    // MARK: - Wallpaper runs

    func cancelRun() { DriftEngine.shared.requestCancel() }

    /// Run one wallpaper apply in an already-decided mode and record it.
    /// Returns a one-line outcome for the page's status area, plus the actual
    /// effect when the in-process route produced one.
    func run(selection: PosterBoardSelection, mode: PosterBoardApplyMode,
             identity: DeviceIdentity) async -> (ok: Bool, message: String, effect: PosterBoardEffect?) {
        // An abandoned run (its calls walked away from) does not block a
        // successor — `beginRun` inside the engine makes the final call.
        guard !InFlightCall.shared.hasLiveRun else {
            return (false, "已有一轮刷入正在进行", nil)
        }
        lastEffect = nil
        // Feedback #30: the funnel refuses a restore run while the gate
        // is closed, even if a caller forgot to consult it — judgement,
        // reset and video all arrive here, so this is the one place a
        // restore run cannot slip past.
        if mode == .backup && !DriftRestoreGate.isEnabled {
            DriftEngine.shared.log("run refused: restore route is suspended (feedback #30)")
            return (false, DriftRestoreGate.notice, nil)
        }
        PosterBoardApplyModeSettings.current = mode
        let isResetSelection = selection.fullReset || !selection.resetModes.isEmpty
        let methodLabel = isResetSelection ? "恢复刷 · 重置" : "免注销直刷"
        running = true
        RunLog.shared.clear()
        defer { running = false }
        do {
            // 2.0.0: the facade takes the wallpaper selection alone. The
            // old call passed empty tweak / status-bar / template
            // selections because the GoldenNugget engine built every
            // feature into one pass; this app has no such surface, and
            // the facade's transports are the wallpaper routes only.
            try await DriftEngine.shared.applyWallpapers(
                selection: selection,
                deviceVersion: identity.version)
            let effect = DriftEngine.shared.lastPosterBoardEffect
            lastEffect = effect
            // 2.0.0 history shape: the record names the user-facing
            // method; the internal channel, the providers written and
            // the store-verification grade ride along as their own fields.
            let verification = DriftEngine.shared.lastVerification
            let providers = verification.map {
                Set($0.expected.map { String($0.split(separator: "/").first ?? "") })
                    .sorted().joined(separator: "、")
            }
            ApplyHistory.record(mode: methodLabel,
                                success: true,
                                device: identity.describe,
                                model: identity.productType, ios: identity.version,
                                effect: effect?.historyLabel,
                                channel: mode == .backup ? nil : mode.shortTitle,
                                provider: providers,
                                verification: verification?.summary)
            // The reset flags are one-shot; the calling page clears its own
            // selection on success (this session only ever holds a copy).
            errorText = nil
            switch mode {
            case .worseQuery:
                if let effect {
                    return (true, "\(effect.headline)。\(effect.detail)", effect)
                }
                return (true, "刷入完成，壁纸已写入", nil)
            case .direct:
                if let verification, verification.allConfirmed {
                    return (true, "刷入完成：已核验，\(verification.confirmed.count) 张描述符都在设备商店里，免注销生效", nil)
                }
                if let verification {
                    return (true, "已写入、未确认显示：\(verification.summary)。文件已送达，但设备商店没有确认收录——先去壁纸库看一眼；没有的话把日志包发出来排查", nil)
                }
                return (true, "刷入完成，壁纸已刷新，免注销生效", nil)
            case .airlift:
                if let verification, verification.allConfirmed {
                    return (true, "刷入完成：已核验，\(verification.confirmed.count) 张描述符都在设备商店里，设备将注销生效", nil)
                }
                if let verification {
                    return (true, "已写入、未确认显示：\(verification.summary)。文件已送达，但设备商店没有确认收录——先去壁纸库看一眼；没有的话把日志包发出来排查", nil)
                }
                return (true, "刷入完成，设备将注销生效", nil)
            case .backup:
                return (true, "刷入完成，设备将重启生效", nil)
            }
        } catch {
            if let failure = error as? TransportFailure, failure.isCancellation {
                DriftEngine.shared.log("run cancelled")
                ApplyHistory.record(mode: methodLabel, success: false, error: "已取消",
                                    device: identity.describe,
                                    model: identity.productType, ios: identity.version)
                return (false, "刷入已取消", nil)
            }
            DriftEngine.shared.log("posterboard apply failed: \(error.localizedDescription)")
            ApplyHistory.record(mode: methodLabel, success: false, error: error.localizedDescription,
                                device: identity.describe,
                                model: identity.productType, ios: identity.version)
            return (false, error.localizedDescription, nil)
        }
    }
}

// MARK: - Mode judgement

/// Why one delivery mode is or is not usable right now.
struct DriftModeAvailability: Identifiable, Equatable {
    let mode: PosterBoardApplyMode
    let available: Bool
    let reason: String
    /// What finishing the run in this mode would do about making the wallpaper
    /// visible — the card previews this before the user taps Apply.
    let effect: String
    var id: String { mode.rawValue }
}

/// The user's method pick — the only choice the UI offers since 2.0.0.
///
/// There are exactly two user-facing methods: 免注销直刷 (which internally
/// picks a write channel by system version and premises) and 恢复刷 (sealed:
/// visible, never selectable, its runs do not exist). Everything finer —
/// the in-process channel, the two tunnel channels — is an internal detail
/// of 免注销直刷 and never appears as a pick.
enum DriftMethodPick: String {
    case auto
    case directFlash
    case restore

    var label: String {
        switch self {
        case .auto: return "自动选择"
        case .directFlash: return "免注销直刷"
        case .restore: return "恢复刷"
        }
    }

    /// Read a stored pick, mapping the pre-2.0.0 per-channel values onto
    /// the method they belonged to.
    static func fromStored(_ raw: String?) -> DriftMethodPick {
        switch raw {
        case "directFlash", "direct", "airlift", "worseQuery": return .directFlash
        case "restore", "backup": return .restore
        default: return .auto
        }
    }
}

/// Why a run will use the channel it uses, in one user-facing sentence.
struct DriftModeJudgement {
    /// The internal channel the run will use. Meaningless when blocked.
    var mode: PosterBoardApplyMode
    var reason: String
    /// Set when no run may start at all right now. `mode` is then a
    /// placeholder — callers must check `isBlocked` before running anything.
    var blockedReason: String?
    /// One row per internal channel, with its own reason and expected effect.
    var options: [DriftModeAvailability] = []
    /// How the chosen channel is expected to take effect.
    var expectedEffect: String = ""
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
    /// * **Local premise** — the app's own system version plus a granted App
    ///   Group. Both are readable in-process, so this is decided without a
    ///   pairing record, a tunnel or Wi-Fi.
    /// * **Tunnel premise** — a saved pairing record, a connected tunnel and a
    ///   real device identity (version *and* build). Both tunnel modes need all
    ///   three; when one is missing they are unavailable and say which, and the
    ///   app's own version is never substituted for the device's.
    private struct Premises {
        let appVersion: String
        let localReady: Bool
        let localWhy: String
        let directReady: Bool
        let directWhy: String
        let airliftReady: Bool
        let airliftWhy: String
        let restoreReady: Bool
        let restoreWhy: String

        func isAvailable(_ mode: PosterBoardApplyMode) -> Bool {
            switch mode {
            case .backup: return restoreReady
            case .direct: return directReady
            case .airlift: return airliftReady
            case .worseQuery: return localReady
            }
        }

        func why(_ mode: PosterBoardApplyMode) -> String {
            switch mode {
            case .backup: return restoreWhy
            case .direct: return directWhy
            case .airlift: return airliftWhy
            case .worseQuery: return localWhy
            }
        }
    }

    private static func premises(identity: DeviceIdentity, tunnelReady: Bool) -> Premises {
        // The in-process route judges the app's *own* system, always. Its
        // device read is irrelevant: the app is the device.
        let appVersion = WorseQueryEscape.processVersion
        let localReady = WorseQueryEscape.isAvailable(deviceVersion: appVersion)
        let localWhy = WorseQueryEscape.unavailableReason(deviceVersion: appVersion)

        var tunnelMissing: String?
        if !PairingRecord.isInstalled {
            tunnelMissing = "还没有配对文件（配对只是隧道通道的前提，本机通道不需要）"
        } else if !tunnelReady {
            tunnelMissing = "隧道未连通（打开 LocalDevVPN 并连上 Wi-Fi）"
        } else if identity.version.isEmpty {
            tunnelMissing = "还没有读到设备系统版本"
        } else if identity.buildVersion.isEmpty {
            tunnelMissing = "还没有读到设备构建号（27.2 的可用范围按构建号判断）"
        }

        let directReady = tunnelMissing == nil
            && PosterBoardDirect.isAvailable(deviceVersion: identity.version,
                                             buildVersion: identity.buildVersion)
        let directWhy = tunnelMissing
            ?? PosterBoardDirect.unavailableReason(deviceVersion: identity.version,
                                                   buildVersion: identity.buildVersion)
        let airliftReady = tunnelMissing == nil
            && Airlift.isSupported(deviceVersion: identity.version,
                                   buildVersion: identity.buildVersion)
        let airliftWhy = tunnelMissing
            ?? Airlift.unsupportedReason(deviceVersion: identity.version,
                                         buildVersion: identity.buildVersion)

        return Premises(
            appVersion: appVersion,
            localReady: localReady,
            localWhy: localWhy,
            directReady: directReady,
            directWhy: directWhy,
            airliftReady: airliftReady,
            airliftWhy: airliftWhy,
            restoreReady: DriftRestoreGate.isEnabled,
            restoreWhy: DriftRestoreGate.isEnabled ? "可用：刷完重启" : "已封存：暂时不可用")
    }

    /// How a mode makes the wallpaper visible, in the user's terms.
    static func expectedEffect(for mode: PosterBoardApplyMode) -> String {
        switch mode {
        case .worseQuery:
            return "写完判定：配对、LocalDevVPN、Wi-Fi 齐全则免注销；否则只提示，可手动注销"
        case .direct:
            return "免注销（只重启 PosterBoard；未确认时回落注销）"
        case .airlift:
            return "注销生效"
        case .backup:
            return "重启生效"
        }
    }

    /// The per-mode rows the judgement card prints.
    private static func optionRows(_ p: Premises, identity: DeviceIdentity) -> [DriftModeAvailability] {
        let appVersion = p.appVersion
        let device = identity.version.isEmpty
            ? "设备系统版本未读到"
            : "设备 iOS \(identity.version)\(identity.buildVersion.isEmpty ? "" : "（\(identity.buildVersion)）")"
        let group = WorseQueryEscape.discoveredGroupIdentifier ?? "已发现"
        return [
            DriftModeAvailability(
                mode: .worseQuery,
                available: p.localReady,
                reason: p.localReady
                    ? "可用：iOS \(appVersion)，签名授予的 App Group 可打开（\(group)）"
                    : p.localWhy,
                effect: expectedEffect(for: .worseQuery)),
            DriftModeAvailability(
                mode: .direct,
                available: p.directReady,
                reason: p.directReady
                    ? "可用：\(device) 在 26.0–27.1 及 27.2 测试版 1/2 内"
                    : p.directWhy,
                effect: expectedEffect(for: .direct)),
            DriftModeAvailability(
                mode: .airlift,
                available: p.airliftReady,
                reason: p.airliftReady
                    ? "可用：\(device) 在 26.2–27.1 及 27.2 测试版 1/2 内"
                    : p.airliftWhy,
                effect: expectedEffect(for: .airlift)),
            DriftModeAvailability(
                mode: .backup,
                available: p.restoreReady,
                reason: p.restoreWhy,
                effect: expectedEffect(for: .backup)),
        ]
    }

    /// The automatic channel order inside 免注销直刷： the in-process
    /// channel first (it asks the least of the user), then the two tunnel
    /// channels. In the overlap zone any ready channel is acceptable — the
    /// first ready one wins. Restore is not in this order: it is a
    /// separate method, and while it is sealed it is never substituted.
    private static func firstAvailable(_ p: Premises) -> PosterBoardApplyMode? {
        for mode in [PosterBoardApplyMode.worseQuery, .direct, .airlift]
        where p.isAvailable(mode) {
            return mode
        }
        return nil
    }

    private static func channelReason(_ mode: PosterBoardApplyMode, manual: Bool) -> String {
        let head = manual ? "已手动选择免注销直刷，走" : "免注销直刷走"
        switch mode {
        case .worseQuery:
            return head + "本机通道：写入不用配对、不用隧道；生效方式写完再判定"
        case .direct:
            return head + "隧道通道：走配对隧道写入，只重启 PosterBoard，不注销"
        case .airlift:
            return head + "隧道通道（注销生效）：刷完只注销不重启"
        case .backup:
            return "恢复刷，刷完会重启"
        }
    }

    /// Decide the delivery channel for a selection.
    ///
    /// The user's pick is a *method* （免注销直刷 / 恢复刷）, never a channel.
    /// Hard limits come first (video, store reset, store-database packs —
    /// all restore-only, hence blocked while 恢复刷 is sealed), then the
    /// sealed-restore pick, then the channel order inside 免注销直刷.
    ///
    /// - Parameter tunnelReady: whether the loopback tunnel currently carries
    ///   traffic. The tunnel premise needs it, so the card must pass it on every
    ///   redraw; it defaults to false for callers that only need a static answer.
    static func judge(identity: DeviceIdentity, selection: PosterBoardSelection,
                      pick: DriftMethodPick,
                      tunnelReady: Bool = false) -> DriftModeJudgement {
        let p = premises(identity: identity, tunnelReady: tunnelReady)
        let rows = optionRows(p, identity: identity)

        func judged(_ mode: PosterBoardApplyMode, _ reason: String) -> DriftModeJudgement {
            DriftModeJudgement(mode: mode, reason: reason,
                               options: rows, expectedEffect: expectedEffect(for: mode))
        }
        func blocked(_ reason: String, notice: String) -> DriftModeJudgement {
            DriftModeJudgement(mode: .backup, reason: reason,
                               blockedReason: notice,
                               options: rows,
                               expectedEffect: expectedEffect(for: .backup))
        }
        /// Blocked because the selection can only travel the sealed method.
        func sealedBlocked(_ reason: String) -> DriftModeJudgement {
            blocked(reason, notice: DriftRestoreGate.notice)
        }

        // The sealed method, picked explicitly: visible, never runs.
        if pick == .restore {
            return sealedBlocked("你选了恢复刷——恢复刷已封存，暂时刷不了。免注销直刷不受影响。")
        }

        // Hard limits: these leave only the restore method, and while it is
        // sealed the answer is "cannot flash now" rather than a route the
        // user may not use.
        if selection.video != nil {
            return p.restoreReady
                ? judged(.backup, "视频壁纸只能用恢复刷，刷完会重启")
                : sealedBlocked("视频壁纸只能用恢复刷，但恢复刷已封存，现在刷不了")
        }
        if selection.fullReset || !selection.resetModes.isEmpty {
            return p.restoreReady
                ? judged(.backup, "重置壁纸商店只能用恢复刷，刷完会重启")
                : sealedBlocked("重置壁纸商店只能用恢复刷，但恢复刷已封存，现在做不了")
        }
        if selection.tendies.contains(where: \.isUnsafeContainer) {
            return p.restoreReady
                ? judged(.backup, "包含商店数据库的壁纸包只能用恢复刷，刷完会重启")
                : sealedBlocked("包含商店数据库的壁纸包只能用恢复刷，但恢复刷已封存，现在刷不了")
        }

        if let channel = firstAvailable(p) {
            return judged(channel, channelReason(channel, manual: pick == .directFlash))
        }
        let whys = [PosterBoardApplyMode.worseQuery, .direct, .airlift]
            .map { "\($0.shortTitle)：\(p.why($0))" }
            .joined(separator: "；")
        return blocked("免注销直刷现在没有可用通道（\(whys)），恢复刷又已封存，现在刷不了",
                       notice: "免注销直刷现在没有可用通道：\(whys)。")
    }
}
