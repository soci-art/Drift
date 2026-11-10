import Foundation
import AirliftFFI

/// Make a written wallpaper visible without respringing the whole device.
///
/// PosterBoard owns the wallpaper store and re-reads it on launch. A full
/// `NeoSpring` respring restarts every userspace process to get there; this
/// path asks the device to restart only the `PosterBoard` daemon over the RSD
/// tunnel, via DVT ProcessControl. Launchd relaunches it, it re-reads the
/// store, and the new wallpaper appears while the rest of the phone keeps
/// running.
///
/// The tunnel is the same RSD connection the AirLift writes use, so this needs
/// a pairing record and LocalDevVPN. When the refresh cannot be confirmed the
/// caller still has a working wallpaper — it is just not visible yet — and
/// falls back to a respring rather than claiming success.
enum PosterRefresh {
    /// Machine-readable outcomes from the Rust core.
    enum Status: String {
        case confirmed
        case connectFailed
        case serviceUnavailable
        case pidNotFound
        case killFailed
        case verifyConnectFailed
        case verifyTimeout
        case unknown

        /// Whether the daemon was restarted and its old pid is gone.
        var isConfirmed: Bool { self == .confirmed }

        /// A short line for the run log, in the user's terms.
        var explanation: String {
            switch self {
            case .confirmed:
                return "PosterBoard 已重启并重新读取壁纸"
            case .connectFailed:
                return "连不上设备（确认已配对、设备解锁、LocalDevVPN 已连接）"
            case .serviceUnavailable:
                return "设备的调试服务不可用"
            case .pidNotFound:
                return "没找到 PosterBoard 进程"
            case .killFailed:
                return "设备拒绝重启 PosterBoard"
            case .verifyConnectFailed:
                return "重启后无法复查 PosterBoard 状态"
            case .verifyTimeout:
                return "PosterBoard 重启后没有及时回来"
            case .unknown:
                return "刷新结果未知"
            }
        }
    }

    /// Restart only PosterBoard. Blocks on the calling thread, so it runs off
    /// the main actor. Safe to call after any write path that has a pairing
    /// record.
    static func attempt(pairingPath: String) async -> (confirmed: Bool, status: Status) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(confirmed: Bool, status: Status), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var outStatus: UnsafeMutablePointer<CChar>?
                var outError: UnsafeMutablePointer<CChar>?
                let rc = al_poster_refresh(pairingPath, nil, nil, &outStatus, &outError)

                let statusText = outStatus.map { String(cString: $0) }
                let errorText = outError.map { String(cString: $0) }
                if let outStatus { al_string_free(outStatus) }
                if let outError { al_string_free(outError) }

                let status = statusText.flatMap { Status(rawValue: $0) } ?? .unknown
                if let errorText, !errorText.isEmpty {
                    AppLog.write("poster refresh: \(errorText)")
                }
                continuation.resume(returning: (rc == 0 && status.isConfirmed, status))
            }
        }
    }
}
