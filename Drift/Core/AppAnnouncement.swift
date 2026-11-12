import CryptoKit
import Foundation

/// The update announcement (collection #178). It shows exactly once
/// per build: right after the first-run guide for new installs, and on
/// the first launch after updating for everyone else. Remembering the
/// seen build in UserDefaults is the whole mechanism.
///
/// Collection #222 (Grace, 2026-11-12): the content no longer ships
/// inside the build as hand-written items — the page shows the GitHub
/// release notes of the release matching this build's version, fetched
/// from the same releases API the update checker uses, so writing the
/// release notes IS writing the announcement. The last fetched notes
/// are cached per version: the page still opens offline after one
/// successful fetch, and with neither cache nor network the launch
/// flow simply does not present it (Settings' manual entry says so in
/// words instead).
///
/// Collection #264 (Grace, 2026-11-12): "seen" is keyed to the CONTENT,
/// not the build. The old key was the version+build string, so editing
/// a release's notes after shipping never re-showed the announcement —
/// the page kept serving the cached old text and the launch flow
/// considered it read. The seen key is now the version plus a hash of
/// the notes body: any edit to the release notes makes it a new
/// announcement that pops once more.
enum AppAnnouncement {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// One id per shipped build: "3.0.9 (25)".
    static var id: String { "\(version) (\(build))" }

    private static let seenKey = "DriftAnnouncementSeenID"

    /// The identity the seen-check actually compares (#264): version +
    /// a hash of the notes body. Editing the release notes changes the
    /// hash, so the announcement counts as new even on the same build.
    static func contentKey(for body: String) -> String {
        let digest = SHA256.hash(data: Data(body.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(version)|\(hex.prefix(16))"
    }

    static var shouldShow: Bool {
        let seen = UserDefaults.standard.string(forKey: seenKey)
        guard let cached = cachedNotes() else {
            // Nothing cached: a pre-#264 seen value still suppresses the
            // launch presentation until a fetch lands and the content
            // key can be compared — the root view presents only when a
            // fetch succeeds in that state, and by then the cache (and
            // therefore the key) exists.
            return seen != id
        }
        return seen != contentKey(for: cached.body)
    }

    static func markSeen() {
        if let cached = cachedNotes() {
            UserDefaults.standard.set(contentKey(for: cached.body), forKey: seenKey)
        } else {
            UserDefaults.standard.set(id, forKey: seenKey)
        }
    }

    static let title = "Drift 更新公告"

    static func versionLine(dateLine: String?) -> String {
        if let dateLine { return "版本 \(version)（构建 \(build)）· \(dateLine)" }
        return "版本 \(version)（构建 \(build)）"
    }

    struct Notes: Equatable {
        let body: String
        /// The release's publish date, "2026年11月12日", when known.
        let dateLine: String?
    }

    private static var cacheBodyKey: String { "DriftAnnouncementNotesBody-\(version)" }
    private static var cacheDateKey: String { "DriftAnnouncementNotesDate-\(version)" }

    static func cachedNotes() -> Notes? {
        guard let body = UserDefaults.standard.string(forKey: cacheBodyKey),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return Notes(body: body,
                     dateLine: UserDefaults.standard.string(forKey: cacheDateKey))
    }

    /// Fetch this version's release notes: the API through the
    /// accelerator first, then direct — the same order the update
    /// checker uses since #225. A success refreshes the cache.
    static func fetchNotes() async -> Notes? {
        let api = "https://api.github.com/repos/soci-art/Drift/releases/tags/v\(version)"
        for base in [AppUpdateChecker.mirrorPrefix, ""] {
            if let notes = try? await fetchNotes(base: base, api: api) {
                UserDefaults.standard.set(notes.body, forKey: cacheBodyKey)
                if let date = notes.dateLine {
                    UserDefaults.standard.set(date, forKey: cacheDateKey)
                }
                AppLog.info("公告：取到 \(version) 的发行说明，内容标识 \(contentKey(for: notes.body))")
                return notes
            }
        }
        AppLog.warn("公告：\(version) 的发行说明没取到（加速和直连都不通）")
        return nil
    }

    private static func fetchNotes(base: String, api: String) async throws -> Notes {
        guard let url = URL(string: base + api) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let body = object?["body"] as? String,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw URLError(.cannotParseResponse) }
        let date = (object?["published_at"] as? String).flatMap(Self.formatDate)
        return Notes(body: body, dateLine: date)
    }

    private static func formatDate(iso: String) -> String? {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }
}
