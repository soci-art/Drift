import Foundation

/// The one switch for the restore route (feedback #30 — emergency stop).
///
/// History: on 2026-11-10 a restore-route flash on iOS 27.2 beta 2 was
/// confirmed complete by the device (progress 100%, verdict 0), and
/// after the manual reboot the device came up factory-reset with all
/// data lost. The route was sealed the same day, and the cause was
/// found soon after: the package written back had been synthesised
/// locally instead of pulled from the device. The synthesised path
/// stays abandoned for good.
///
/// The route reopened on the Alpha research line (2026-11-19) in its
/// device-pulled shape — pull the device's own backup, keep only the
/// PosterBoard domain, swap the wallpaper, write it back — and proved
/// itself on a spare device across 3.3.6 build 8 and the 3.3.7 line
/// (device verdict 0, wallpaper live after reboot, apps and data
/// intact). On 2026-11-22 Grace ordered the route opened on the
/// formal line as a regular feature: no channel condition, no
/// experimental-features switch. Whether a given device can use it is
/// judged per device in the session premises (iOS 27 segment by
/// version and build number, the tunnel trio, a readable build
/// number); this gate is only the emergency stop, and it is open.
///
/// If the route ever has to be stopped again in a hurry, flip this one
/// literal back to `false`: mode judgement, the wallpaper page, the
/// video page, the store reset and Settings' restore-backup all
/// consult it, and the session's run funnel refuses a restore run
/// while it is closed.
enum DriftRestoreGate {
    static let isEnabled = true

    /// The one suspension notice every blocked entry point shows while
    /// the gate is closed, so the wording cannot drift between pages.
    /// Unreachable while the gate is open; kept for the day the
    /// emergency stop is used again.
    static let notice = "恢复刷已暂停：请改用其他刷入方式。"

    /// The pre-start confirmation every restore flash shows — on the
    /// wallpaper page and on the video picker alike (Grace,
    /// 2026-11-22): it pops the moment a restore flash is tapped,
    /// before anything is pulled, and only 「确定刷入」 starts the
    /// run. It shows every time; there is no "don't ask again". The
    /// four points are the standing write-back warnings: a full
    /// backup and Find My off first (the device refuses a restore
    /// with error 211 while Find My is on), the setup walk after the
    /// reboot, profiles possibly being cleared by the write-back
    /// (seen in the field, cause undetermined — check and reinstall),
    /// and keeping the app and the tunnel alive through the run.
    static let confirmationTitle = "恢复刷入前请确认"
    static var confirmationMessage: String {
        let spaceNotice = ProtectiveBackup.preflightSpaceNotice()
        return """
            1. 先把手机整机备份到电脑，并确认备份可用；同时关掉「查找」，否则设备可能拒绝恢复。
            2. 本版本入口按 iOS 27.x 和可读取的构建号放行；这不代表每个 iOS 27 构建都已完成真机验证。
            3. 恢复协议可能影响设备数据、App 或设置。即使本流程只准备壁纸相关变更，也无法保证设备端绝不会影响其他数据；电脑整机备份是必要保障，不是零风险保证。
            4. 刷完重启后可能需要完成设置流程；描述文件也可能被清除，请刷完检查并按需重新安装。
            5. 刷入过程中不要划掉 App，也不要断开 Wi-Fi 和 LocalDevVPN。
            6. \(spaceNotice)
            """
    }
}
