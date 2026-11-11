import Foundation

/// How a PosterBoard selection reaches the device.
///
/// Since 3.0.0 there are three independent write channels, plus the sealed
/// restore route. They are not three implementations of one thing: each has
/// its own write path and its own way of making the wallpaper visible, and a
/// failure in one never borrows another.
///
///  - `.worseQuery` — 本机直刷. Writes through `worse_query` inside this app:
///    no pairing record and no tunnel. It needs a usable App Group and a
///    system in its own range. After the write it does nothing automatic; the
///    user closes PosterBoard from the app switcher and the system re-reads
///    the store.
///  - `.direct` — 免注销直刷. One AirTraffic/Books transaction over the pairing
///    tunnel, with the reload preferences merged into that transaction, then
///    only PosterBoard is restarted. If the restart is not confirmed the user
///    gets the written notice and a manual respring button — never an
///    automatic fall-through to the other tunnel channel.
///  - `.airlift` — 注销直刷. The upstream AirCard write: descriptors injected
///    one by one over the pairing tunnel, then a normal respring.
///  - `.backup` — 恢复刷. Sealed; no executable code.
///
/// The user picks a *method* (auto or one of the three channels). Auto runs
/// the channels in 本机直刷 → 免注销直刷 → 注销直刷 order; a manual pick is
/// used as-is and is unavailable — not substituted — when its premise fails.
enum PosterBoardApplyMode: String, CaseIterable, Identifiable, Hashable {
    case backup
    case direct
    case airlift
    case worseQuery

    var id: String { rawValue }

    /// The full user-facing name. These four names are fixed.
    var title: String {
        switch self {
        case .backup:
            return DriftRestoreGate.isEnabled ? "恢复刷" : "恢复刷（封存）"
        case .direct: return "免注销直刷"
        case .airlift: return "注销直刷"
        case .worseQuery: return "本机直刷"
        }
    }

    /// The short label the judgement card and the history use.
    var shortTitle: String { title }

    var symbol: String {
        switch self {
        case .backup: return "externaldrive.fill"
        case .direct: return "arrow.down.circle.fill"
        case .airlift: return "arrow.clockwise.circle.fill"
        case .worseQuery: return "bolt.fill"
        }
    }

    /// What the apply will and will not do, in the user's terms.
    var summary: String {
        switch self {
        case .backup:
            return "通过恢复刷写入壁纸。适用于所有受支持的设备，最后会重启设备。恢复刷已封存，暂时不可用。"
        case .direct:
            return "通过配对隧道直写 PosterBoard 的容器，再只重启 PosterBoard 守护进程——不注销、不重启。支持 iOS 26.0–27.1 及 27.2 测试版 1/2；需要配对、隧道、LocalDevVPN，且设备保持解锁。刷新未确认时只提示，可手动注销。"
        case .airlift:
            return "通过配对隧道逐张写入 PosterBoard 的容器——写完统一注销生效。支持 iOS 26.0–27.1 及 27.2 测试版 1/2；需要配对、隧道、LocalDevVPN，且设备保持解锁。"
        case .worseQuery:
            return "在本机直接写进 PosterBoard 的容器——不用配对文件、不用隧道。刷完提示你上滑关闭 PosterBoard，系统重新拉起时生效；需要 iOS 26.0–26.7.2、27.0–27.2、27.2.1，或 27.3 测试版 1（实验），且是证书签名（带能用的 App Group）。"
        }
    }

    /// Whether a reset can be honoured in this mode.
    var supportsReset: Bool { self == .backup }
}
