import Foundation

/// The one switch for the restore route (feedback #30 — emergency stop).
///
/// On 2026-11-10 a restore-route flash on iOS 27.2 beta 2 was confirmed
/// complete by the device (progress 100%, verdict 0), and after the
/// manual reboot the device came up factory-reset with all data lost.
/// Until the audit explains how a confirmed restore can end in an erase,
/// the whole route is closed: mode judgement, the wallpaper page, the
/// video page, the store reset and Settings' restore-backup all consult
/// this gate, and the session's run funnel refuses a restore run even if
/// a caller forgets to ask.
///
/// Since 2026-11-19 the route has a research line of its own (Grace:
/// 单独开一条 Alpha 的线): the gate now reads the build's channel
/// stamp and opens ONLY on Alpha builds. The release and nightly
/// workflows never stamp "alpha", so on every shipped line this flag
/// is false exactly as the literal was — the seal there is by
/// construction, not by a value someone could flip in a shared tree.
/// On Alpha the open gate is necessary but nowhere near sufficient:
/// the research switch (RestoreFlashPremise), the session premises
/// (tunnel trio + iOS 27 segment by build number), the in-package
/// dry-run gate and the fingerprint re-check all still stand in front
/// of any write-back, and a run on this line is a dry run until the
/// user confirms the write-back separately.
enum DriftRestoreGate {
    static var isEnabled: Bool { AppVersion.channel == .alpha }

    /// Blocked entry points answer with a plain 「暂不可用」 (Grace,
    /// 2026-11-19: every restore-route text and error came out of the
    /// app; the route itself stays sealed behind this flag).
}
