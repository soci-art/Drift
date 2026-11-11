import Foundation

/// Collection #178 (Grace, 2026-11-11): the update announcement ships
/// INSIDE the build — no network fetch, the text below is the release
/// notes in reader voice. It shows exactly once per build: right after
/// the first-run guide for new installs, and on the first launch after
/// updating for everyone else. Remembering the seen build in
/// UserDefaults is the whole mechanism.
enum AppAnnouncement {
    /// One id per shipped build: "3.0.7 (19)".
    static var id: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static let seenKey = "DriftAnnouncementSeenID"

    static var shouldShow: Bool {
        UserDefaults.standard.string(forKey: seenKey) != id
    }

    static func markSeen() {
        UserDefaults.standard.set(id, forKey: seenKey)
    }

    static let title = "本次更新"

    static let lines: [String] = [
        "更新说明现在直接在 App 里显示：更新后第一次打开就能看到这一页。",
        "第一次打开 App 时，会把需要的权限一次问清，之后不再反复弹。",
        "无线配对的验证码会通过通知弹出来，在系统设置里确认配对时也能看到。",
        "设置里的记录列表和删除确认变简洁了：只显示壁纸名字、刷入方式和时间。",
    ]
}
