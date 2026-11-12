import Foundation

/// Full-form display names for system versions (collection #229 / #240 /
/// #241, Grace 2026-11-12): wherever the app shows a system version to the
/// user it writes the full name — “iOS 27.2 正式版” or “iOS 27.2 beta 2” —
/// never a bare number, and never the word 测试版.
///
/// A version number alone cannot tell a beta from a release (both report
/// “27.2”), so the name is decided by the BUILD number against the known
/// lists below. A build that is not on a list is not guessed at: the
/// display falls back to “iOS 27.2（构建 xxxx）”, which says plainly that
/// the build is one the app does not know by name.
///
/// Both identifications use this one formatter — the in-process read
/// (本机识别, the app's own system) and the tunnel read (隧道设备识别,
/// `DeviceIdentity`) — so the same phone is named the same way everywhere.
enum SystemVersionName {
    /// Known beta builds: build → (version it belongs to, spoken label).
    private static let betaBuilds: [String: (version: String, label: String)] = [
        "24B5084k": ("27.2", "beta 1"),   // iOS 27.2 beta 1
        "24B5089g": ("27.2", "beta 2"),   // iOS 27.2 beta 2
        "24C5037i": ("27.3", "beta 1"),   // iOS 27.3 beta 1
    ]

    /// Known release builds: build → version it belongs to.
    private static let releaseBuilds: [String: String] = [
        "24B119": "27.2",                 // iOS 27.2 正式版
    ]

    /// The full display name for a (version, build) pair, e.g.
    /// “iOS 27.2 beta 2”. An empty version yields an empty string.
    static func display(version: String, build: String) -> String {
        let version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = build.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return "" }
        if let beta = betaBuilds[build], beta.version == version {
            return "iOS \(version) \(beta.label)"
        }
        if let release = releaseBuilds[build], release == version {
            return "iOS \(version) 正式版"
        }
        if !build.isEmpty {
            return "iOS \(version)（构建 \(build)）"
        }
        return "iOS \(version)"
    }
}
