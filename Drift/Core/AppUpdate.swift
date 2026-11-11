import Foundation

/// In-app update check against this repo's GitHub releases
/// (collection #170/#171, Grace's design):
///
/// - The app checks on its own: silently at launch, and any time from
///   设置 → 检查更新. Only a found update is surfaced; a failed check
///   stays quiet unless the user asked.
/// - ONE download button. The app picks the route that works: direct
///   GitHub first, the domestic accelerator as fallback, for both the
///   check and the download. The user never chooses a line.
/// - The accelerator prefix is a single constant, re-verified by hand
///   at every release and baked into that build (this build's was
///   verified working on 2026-11-11). Old builds keep their prefix;
///   when it dies, the direct route still carries them, and the next
///   build they install carries a fresh prefix.
/// - The downloaded file is the same unsigned IPA the release ships;
///   the page hands it to the system share sheet so the user saves it
///   to Files or sends it to their signing app. Nothing is installed
///   by Drift itself.
@MainActor
final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()

    struct ReleaseInfo {
        let version: String
        let notes: String
        let assetName: String
        let assetSize: Int
        let directURL: URL
    }

    enum DownloadPhase {
        case idle
        case working(Double)
        case done(URL)
        case failed(String)
    }

    @Published var latest: ReleaseInfo?
    @Published var checking = false
    @Published var checkError: String?
    @Published var downloadPhase: DownloadPhase = .idle
    @Published var routeNote = ""

    private var didAutoCheck = false

    static let releasesAPI = "https://api.github.com/repos/soci-art/Drift/releases/latest"
    static let latestPage = "https://github.com/soci-art/Drift/releases/latest"
    /// Domestic accelerator prefix — verified working 2026-11-11.
    /// RE-VERIFY AND REPLACE AT EVERY RELEASE (Grace's rule).
    static let mirrorPrefix = "https://gh-proxy.com/"

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var updateAvailable: Bool {
        guard let latest else { return false }
        return (PosterBoard.compareVersion(latest.version, currentVersion) ?? 0) > 0
    }

    func autoCheck() async {
        guard !didAutoCheck else { return }
        didAutoCheck = true
        await refresh()
    }

    func refresh() async {
        checking = true
        defer { checking = false }
        do {
            latest = try await Self.fetchLatest()
            checkError = nil
        } catch {
            checkError = "没查到更新信息：网络不通，或者发行页暂时不可用。"
        }
    }

    // MARK: - Check

    private static func fetchLatest() async throws -> ReleaseInfo {
        // Route 1: direct API. Route 2: the same API through the
        // accelerator. Route 3: the accelerator on the release page —
        // its redirect target carries the tag, and the asset name is
        // deterministic, so a ReleaseInfo can still be built (without
        // notes or size).
        if let info = try? await fetchViaAPI(base: "") { return info }
        if let info = try? await fetchViaAPI(base: mirrorPrefix) { return info }
        return try await fetchViaPage()
    }

    private static func fetchViaAPI(base: String) async throws -> ReleaseInfo {
        guard let url = URL(string: base + releasesAPI) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let tag = object?["tag_name"] as? String else { throw URLError(.cannotParseResponse) }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let notes = object?["body"] as? String ?? ""
        let assets = object?["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: {
            ($0["name"] as? String)?.hasPrefix("Drift-") == true
                && ($0["name"] as? String)?.hasSuffix("-unsigned.ipa") == true
        }), let name = asset["name"] as? String,
           let download = asset["browser_download_url"] as? String,
           let assetURL = URL(string: download) else {
            throw URLError(.cannotParseResponse)
        }
        return ReleaseInfo(version: version, notes: notes, assetName: name,
                           assetSize: asset["size"] as? Int ?? 0, directURL: assetURL)
    }

    private static func fetchViaPage() async throws -> ReleaseInfo {
        guard let url = URL(string: mirrorPrefix + latestPage) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let final = response.url?.absoluteString,
              let tagRange = final.range(of: "/releases/tag/v") else {
            throw URLError(.cannotParseResponse)
        }
        let version = String(final[tagRange.upperBound...])
        guard !version.isEmpty, version.allSatisfy({ $0.isNumber || $0 == "." }) else {
            throw URLError(.cannotParseResponse)
        }
        let name = "Drift-\(version)-unsigned.ipa"
        guard let assetURL = URL(string: "https://github.com/soci-art/Drift/releases/download/v\(version)/\(name)") else {
            throw URLError(.badURL)
        }
        return ReleaseInfo(version: version, notes: "", assetName: name,
                           assetSize: 0, directURL: assetURL)
    }

    // MARK: - Download

    func startDownload() {
        guard let latest, updateAvailable else { return }
        if case .working = downloadPhase { return }
        downloadPhase = .working(0)
        routeNote = ""
        Task { await download(latest) }
    }

    private func download(_ info: ReleaseInfo) async {
        // Direct first; any failure retries once through the accelerator.
        do {
            let file = try await downloadOnce(from: info.directURL, info: info)
            downloadPhase = .done(file)
        } catch {
            routeNote = "直连不通，正在换国内加速线重试…"
            do {
                guard let mirrorURL = URL(string: Self.mirrorPrefix + info.directURL.absoluteString) else {
                    throw URLError(.badURL)
                }
                let file = try await downloadOnce(from: mirrorURL, info: info)
                downloadPhase = .done(file)
            } catch {
                downloadPhase = .failed("下载失败：两条线都没走通。检查网络后再试一次。")
            }
        }
    }

    private func downloadOnce(from url: URL, info: ReleaseInfo) async throws -> URL {
        let bridge = DownloadBridge { [weak self] fraction in
            Task { @MainActor in
                if case .working = self?.downloadPhase ?? .idle {
                    self?.downloadPhase = .working(fraction)
                }
            }
        }
        let session = URLSession(configuration: .default, delegate: bridge, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (tempURL, response) = try await session.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        if info.assetSize > 0,
           let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
           let size = attrs[.size] as? Int, size != info.assetSize {
            throw URLError(.cannotDecodeContentData)
        }
        let downloads = URL.documents.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let destination = downloads.appendingPathComponent(info.assetName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }
}

/// Bridges URLSessionDownloadDelegate progress into a closure; the
/// async `download(for:)` resumes on completion or error by itself.
private final class DownloadBridge: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}
