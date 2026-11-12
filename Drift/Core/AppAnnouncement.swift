import Foundation

/// Collection #178 (Grace, 2026-11-11): the update announcement ships
/// INSIDE the build — no network fetch, the items below are the release
/// notes in reader voice. It shows exactly once per build: right after
/// the first-run guide for new installs, and on the first launch after
/// updating for everyone else. Remembering the seen build in
/// UserDefaults is the whole mechanism.
///
/// #192 (Grace, 2026-11-11): the presentation is a proper announcement
/// page — icon, version and date in the header, one titled entry per
/// change. `date` is the release date of the build and is updated with
/// the items on every release, like the release notes file.
enum AppAnnouncement {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// One id per shipped build: "3.0.7 (20)".
    static var id: String { "\(version) (\(build))" }

    static let date = "2026年11月12日"

    static var versionLine: String { "版本 \(version)（构建 \(build)）· \(date)" }

    private static let seenKey = "DriftAnnouncementSeenID"

    static var shouldShow: Bool {
        UserDefaults.standard.string(forKey: seenKey) != id
    }

    static func markSeen() {
        UserDefaults.standard.set(id, forKey: seenKey)
    }

    static let title = "Drift 更新公告"

    struct Item {
        let icon: String
        let title: String
        let body: String
    }

    static let items: [Item] = [
        Item(icon: "wrench.and.screwdriver.fill", title: "细节修复",
             body: "修复了一些细节问题"),
    ]
}
