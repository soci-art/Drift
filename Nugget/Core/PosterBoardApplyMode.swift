import Foundation

/// How a PosterBoard selection reaches the device.
///
/// There are three, and they are not three implementations of one thing — they
/// are different mechanisms that happen to install the same wallpapers, so the
/// choice belongs to the user and the UI has to say what it costs.
///
///  - `.backup` is this port's original path: fetch the store's database, compile
///    the packs into payloads, and ride them through a protective backup and a
///    restore. It is the *reference's* mechanism, it works on every device the
///    rest of the app works on, and it ends in a reboot.
///  - `.airlift` is the AirCard path: open an AirTraffic tunnel over the pairing
///    record this app already holds and write straight into PosterBoard's data
///    container. No backup, no reboot — a respring is enough — but it needs
///    iOS 26.2+, LocalDevVPN, an unlocked device, and it cannot do a store reset.
///  - `.direct` is the pairing-tunnel path: one descriptor at a time through a
///    single AirTraffic/Books transaction (the same write module AirLift uses,
///    with the reload preferences merged into that transaction), then only
///    PosterBoard is restarted (DVT ProcessControl) so the wallpaper appears
///    without a respring. It works from iOS 26.0 to 27.1 and on 27.2 beta 1/2,
///    needs a pairing record and LocalDevVPN, and cannot reset the store.
///  - `.worseQuery` is the in-process path: `worse_query` consumes a sandbox
///    extension for PosterBoard's container from inside this app, so the copy
///    needs neither a pairing record nor a tunnel. The signing profile must
///    grant a usable App Group (discovered at runtime), and the system has to be
///    in worse_query's range (26.0–26.7.2 / 27.0–27.2). Like AirLift, it can add
///    descriptors but not reset the store. What happens afterwards depends on
///    the tunnel prerequisites at that moment — see `PosterBoardLocal`.
///
/// AirLift is the default *stored* preference. The backup path is this port's
/// original mechanism, not a better one: it costs a full protective backup and a
/// reboot, and it only has something left to do that the direct routes cannot —
/// the store reset. The judgement prefers the in-process route whenever it is
/// actually usable, because it demands the least from the user.
enum PosterBoardApplyMode: String, CaseIterable, Identifiable, Hashable {
    case backup
    case direct
    case airlift
    case worseQuery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backup:
            // The long title is what the history stores, so it states the
            // suspension for as long as the gate is closed.
            return DriftRestoreGate.isEnabled ? "恢复式" : "恢复式（暂时关闭）"
        case .direct: return "直刷免注销"
        case .airlift: return "AirLift 直刷"
        // Chinese-first, like the rest of Drift's own UI: `shortTitle` is what
        // the mode menu shows, and a String Catalog key added here would ship
        // untranslated until the catalog is regenerated on macOS. The short
        // name is deliberately the *only* user-facing name — no `worse_query`
        // in menus or history.
        case .worseQuery: return "本机直刷"
        }
    }

    /// The two- or three-word name the mode menu and the override note use.
    ///
    /// `title` is the long form (`AirLift (AirTraffic)`) and belongs in a
    /// sentence; a menu row and “you picked X but…” need the short one.
    var shortTitle: String {
        switch self {
        case .backup: return "恢复式"
        case .direct: return "直刷免注销"
        case .airlift: return "AirLift 直刷"
        case .worseQuery: return "本机直刷"
        }
    }

    var symbol: String {
        switch self {
        case .backup: return "externaldrive.fill"
        case .direct: return "arrow.down.circle.fill"
        case .airlift: return "bolt.horizontal.circle.fill"
        case .worseQuery: return "bolt.fill"
        }
    }

    /// What the apply will and will not do, in the user's terms.
    var summary: String {
        switch self {
        case .backup:
            return "先从设备获取商店数据库，再通过恢复式写入壁纸。适用于所有受支持的设备，最后会重启设备。"
        case .direct:
            return "通过配对隧道直写 PosterBoard 的容器，再只重启 PosterBoard 守护进程——不注销、不重启。支持 iOS 26.0–27.1 及 27.2 测试版 1/2；需要配对、隧道、LocalDevVPN，且设备保持解锁。"
        case .airlift:
            return "通过隧道直接写进 PosterBoard 的容器——不做备份，以注销代替重启。需要 iOS 26.2–27.1 或 27.2 测试版 1/2、LocalDevVPN，且设备保持解锁。"
        case .worseQuery:
            return "在本机直接写进 PosterBoard 的容器——不用配对文件、不用隧道。写完按当时的配对/隧道/Wi-Fi 情况决定免注销还是只提示；需要 iOS 26.0–26.7.2 或 27.0–27.2，且签名授予可用的 App Group。"
        }
    }

    /// Whether a reset can be honoured in this mode.
    ///
    /// A reset is a store operation: it clears what PosterBoard has indexed. Both
    /// direct paths only ever add a descriptor directory, so a reset selected
    /// there is not silently dropped — the apply says it cannot and stops before
    /// touching the device.
    var supportsReset: Bool {
        self == .backup
    }
}

/// The selected mode, persisted the same way `autoRefresh` is.
enum PosterBoardApplyModeSettings {
    static let key = "PosterBoardApplyMode"

    /// AirLift unless something says otherwise.
    ///
    /// The stored value is the only thing that can move this off AirLift, and a
    /// device that has never touched the picker has nothing stored — so the
    /// default is what such a device gets.
    /// Resolve saved AirLift selections against the actual target without erasing
    /// the user's preference for another, supported device.
    ///
    /// The fallback is the same for every saved pick — the automatic order
    /// (in-process, then direct, then AirLift) minus the pick itself — because
    /// the old per-mode special cases made a saved direct pick try a different
    /// chain than a saved AirLift pick. A saved restore pick is returned as-is:
    /// the session's funnel refuses it while the gate is closed, and this
    /// function has no business silently rewriting an explicit choice.
    static func resolved(deviceVersion: String, buildVersion: String) -> PosterBoardApplyMode {
        let pick = current
        if pick == .backup { return .backup }
        if isAvailable(pick, deviceVersion: deviceVersion, buildVersion: buildVersion) {
            return pick
        }
        for candidate in [PosterBoardApplyMode.worseQuery, .direct, .airlift]
        where isAvailable(candidate, deviceVersion: deviceVersion, buildVersion: buildVersion) {
            return candidate
        }
        return .backup
    }

    /// One availability rule for the saved-pick fallback, mirroring
    /// `DriftJudge`'s per-mode checks.
    private static func isAvailable(_ mode: PosterBoardApplyMode,
                                    deviceVersion: String,
                                    buildVersion: String) -> Bool {
        switch mode {
        case .backup:
            return DriftRestoreGate.isEnabled
        case .direct:
            return PosterBoardDirect.isAvailable(deviceVersion: deviceVersion,
                                                 buildVersion: buildVersion)
        case .worseQuery:
            return WorseQueryEscape.isAvailable(deviceVersion: deviceVersion)
        case .airlift:
            return Airlift.isSupported(deviceVersion: deviceVersion,
                                       buildVersion: buildVersion)
        }
    }

    static var current: PosterBoardApplyMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key) else { return .airlift }
            return PosterBoardApplyMode(rawValue: raw) ?? .airlift
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
