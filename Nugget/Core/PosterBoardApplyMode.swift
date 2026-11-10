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
///    single AirTraffic/Books snapshot-restore cycle, then only PosterBoard is
///    restarted (DVT ProcessControl) so the wallpaper appears without a
///    respring. It works from iOS 26.0 to 27.1, needs a pairing record and
///    LocalDevVPN, and cannot reset the store.
///  - `.worseQuery` is the in-process path: `worse_query` consumes a sandbox
///    extension for PosterBoard's container from inside this app, so the copy
///    needs neither a pairing record nor a tunnel. No backup, a respring only —
///    but the signing profile must grant an App Group, and the system has to be
///    in worse_query's range (26.0–26.7.2 / 27.0–27.2). Like AirLift, it can add
///    descriptors but not reset the store.
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
        case .backup: return String(localized: "Protective backup")
        case .direct: return "直刷（回环配对 · 免注销）"
        case .airlift: return String(localized: "AirLift (AirTraffic)")
        // Chinese-first, like the rest of Drift's own UI: `shortTitle` is what
        // the mode menu shows, and a String Catalog key added here would ship
        // untranslated until the catalog is regenerated on macOS.
        case .worseQuery: return "本机直刷（worse_query）"
        }
    }

    /// The two- or three-word name the mode menu and the override note use.
    ///
    /// `title` is the long form (`AirLift (AirTraffic)`) and belongs in a
    /// sentence; a menu row and “you picked X but…” need the short one.
    var shortTitle: String {
        switch self {
        case .backup: return "恢复式"
        case .direct: return "直刷（免注销）"
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
            return "先从设备获取商店数据库，再通过保护性备份送入壁纸。适用于所有受支持的设备，最后会重启设备。"
        case .direct:
            return "通过配对隧道直写 PosterBoard 的容器，再只重启 PosterBoard 守护进程——不注销、不重启。需要 iOS 26.0–27.1、LocalDevVPN，且设备保持解锁。"
        case .airlift:
            return "通过隧道直接写进 PosterBoard 的容器——不做备份，以注销代替重启。需要 iOS 26.2 或更高版本、LocalDevVPN，且设备保持解锁。"
        case .worseQuery:
            return "在本机直接写进 PosterBoard 的容器——不用配对文件、不用隧道，以注销代替重启。需要 iOS 26.0–26.7.2 或 27.0–27.2，且签名里带 App Group 权限。"
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
    static func resolved(deviceVersion: String, buildVersion: String) -> PosterBoardApplyMode {
        switch current {
        case .backup:
            return .backup
        case .direct:
            // A saved direct pick survives for a supported system; on one that
            // is not, prefer the in-process route, then AirLift, then the
            // (currently suspended) backup route.
            if PosterBoardDirect.isAvailable(deviceVersion: deviceVersion) { return .direct }
            if WorseQueryEscape.isAvailable(deviceVersion: deviceVersion) { return .worseQuery }
            return AirliftAvailability.isHidden(deviceVersion: deviceVersion, buildVersion: buildVersion)
                ? .backup : .airlift
        case .worseQuery:
            // A saved in-process pick survives for a device that supports it;
            // on one that does not, fall back the same way a saved AirLift pick
            // does instead of failing the run at the injection.
            if WorseQueryEscape.isAvailable(deviceVersion: deviceVersion) { return .worseQuery }
            return AirliftAvailability.isHidden(deviceVersion: deviceVersion, buildVersion: buildVersion)
                ? .backup : .airlift
        case .airlift:
            return AirliftAvailability.isHidden(deviceVersion: deviceVersion, buildVersion: buildVersion)
                ? .backup : .airlift
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
