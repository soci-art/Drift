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
/// a caller forgets to ask. The restore machinery underneath is NOT
/// touched — the audit still needs it, and reopening the route is meant
/// to be this one flag flipping back, plus the copy that describes the
/// route as available being restored with it.
///
/// Feedback #31's research build does NOT open this gate either — that
/// was considered and explicitly rejected for the first diagnosis round:
/// the round runs on Grace's main device (the original pull-silence
/// scene, iOS 27.2 beta 2) because the list-dir hypothesis is most
/// falsifiable there, and the write-back path must never reach that
/// device. The research flag (see `DriftResearchBuild`) opens only the
/// diagnostic-pull entry and the banner; this literal stays `false` in
/// every build this stage produces. A gate-open variant for the spare
/// device (iOS 27.3) end-to-end stage, if it is ever built, is a
/// separate build decided separately — it is not a mode of this one.
enum DriftRestoreGate {
    static let isEnabled = false

    /// The one suspension notice every blocked entry point shows, so the
    /// wording cannot drift between pages. Plain and factual on purpose:
    /// it says the route is off, why, and what still works.
    static let notice = "恢复式暂时停用：查明一次重启后设备被抹除的原因之前，恢复式刷入、重置和恢复备份都先停用。直刷不受影响。"
}
