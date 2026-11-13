import Foundation

/// In-app update check against this repo's GitHub releases
/// (collection #170/#171, Grace's design):
///
/// - The app checks on its own: silently at launch, and any time from
///   设置 → 检查更新. Only a found update is surfaced; a failed check
///   stays quiet unless the user asked.
/// - ONE download button. The app picks the route that works: the
///   domestic accelerator first, direct GitHub as fallback, for both
///   the check and the download (collection #225, Grace, 2026-11-12 —
///   the order was the other way round up to 3.0.9). The user never
///   chooses a line.
/// - The accelerator prefix is a single constant, re-verified by hand
///   at every release and baked into that build (this build's was
///   verified working on 2026-11-12). Old builds keep their prefix;
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
        /// The release's build number, read out of the asset name
        /// (`Drift-<version>-<build>-unsigned.ipa`, collection #224).
        /// nil for releases published before the name carried one.
        let build: Int?
        let notes: String
        let assetName: String
        let assetSize: Int
        let directURL: URL

        /// "3.0.9（构建 26）" when the build is known, else "3.0.9".
        var displayVersion: String {
            if let build { return "\(version)（构建 \(build)）" }
            return version
        }
    }

    enum DownloadPhase {
        case idle
        /// fraction is nil when neither the response nor the release
        /// metadata can say how big the file is; the byte counts are
        /// always real, so the page can still show live progress
        /// (collection #226 — through the accelerator the response
        /// often carries no Content-Length, and a bare percentage
        /// sat at 0% for the whole download).
        case working(fraction: Double?, downloadedBytes: Int64, totalBytes: Int64)
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
    static let mirrorPrefix = "https://gh.86419753.xyz/"

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    /// "3.0.9（构建 25）" — what the update page shows as 本机版本.
    var currentDisplay: String { "\(currentVersion)（构建 \(currentBuild)）" }

    var updateAvailable: Bool {
        guard let latest else { return false }
        let order = PosterBoard.compareVersion(latest.version, currentVersion) ?? 0
        if order != 0 { return order > 0 }
        // Collection #224 (Grace, 2026-11-12): same version — a release
        // whose asset was replaced in place is still an update when its
        // build is newer than this install's.
        guard let latestBuild = latest.build else { return false }
        return latestBuild > currentBuild
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
        // Route 1: the API through the domestic accelerator. Route 2:
        // the direct API. Route 3: the release page (accelerator,
        // then direct) — its redirect target carries the tag, and the
        // asset list page carries the real asset name, so a
        // ReleaseInfo can still be built (without notes or size).
        // Accelerator first since #225; up to 3.0.9 direct went first.
        if let info = try? await fetchViaAPI(base: mirrorPrefix) { return info }
        if let info = try? await fetchViaAPI(base: "") { return info }
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
        return ReleaseInfo(version: version,
                           build: Self.buildNumber(fromAssetName: name, version: version),
                           notes: notes, assetName: name,
                           assetSize: asset["size"] as? Int ?? 0, directURL: assetURL)
    }

    /// The build segment of `Drift-<version>-<build>-unsigned.ipa`;
    /// nil for the older `Drift-<version>-unsigned.ipa` shape.
    static func buildNumber(fromAssetName name: String, version: String) -> Int? {
        let prefix = "Drift-\(version)-"
        guard name.hasPrefix(prefix), name.hasSuffix("-unsigned.ipa") else { return nil }
        let middle = name.dropFirst(prefix.count).dropLast("-unsigned.ipa".count)
        return Int(middle)
    }

    private static func fetchViaPage() async throws -> ReleaseInfo {
        // The page route goes through the accelerator first like
        // every other route (#225), direct as its own fallback.
        if let info = try? await fetchViaPage(base: mirrorPrefix) { return info }
        return try await fetchViaPage(base: "")
    }

    private static func fetchViaPage(base: String) async throws -> ReleaseInfo {
        guard let url = URL(string: base + latestPage) else { throw URLError(.badURL) }
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
        // The asset name carries the build (#224), so it is no longer
        // deterministic: read the release's asset list page and take
        // the real name out of it.
        let name = try await fetchAssetName(version: version)
        guard let assetURL = URL(string: "https://github.com/soci-art/Drift/releases/download/v\(version)/\(name)") else {
            throw URLError(.badURL)
        }
        return ReleaseInfo(version: version,
                           build: buildNumber(fromAssetName: name, version: version),
                           notes: "", assetName: name,
                           assetSize: 0, directURL: assetURL)
    }

    private static func fetchAssetName(version: String) async throws -> String {
        // Accelerator first, direct as fallback (#225), like the
        // other routes.
        if let name = try? await fetchAssetName(base: mirrorPrefix, version: version) { return name }
        return try await fetchAssetName(base: "", version: version)
    }

    private static func fetchAssetName(base: String, version: String) async throws -> String {
        let page = "https://github.com/soci-art/Drift/releases/expanded_assets/v\(version)"
        guard let url = URL(string: base + page) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8),
              let start = html.range(of: "Drift-\(version)"),
              let end = html.range(of: "-unsigned.ipa", range: start.lowerBound..<html.endIndex)
        else { throw URLError(.cannotParseResponse) }
        return String(html[start.lowerBound..<end.upperBound])
    }

    // MARK: - Download

    func startDownload() {
        guard let latest, updateAvailable else { return }
        if case .working = downloadPhase { return }
        downloadPhase = .working(fraction: latest.assetSize > 0 ? 0 : nil,
                                 downloadedBytes: 0,
                                 totalBytes: Int64(latest.assetSize))
        routeNote = ""
        Task { await download(latest) }
    }

    private func download(_ info: ReleaseInfo) async {
        // The accelerator first (#225); any failure retries once direct.
        do {
            guard let mirrorURL = URL(string: Self.mirrorPrefix + info.directURL.absoluteString) else {
                throw URLError(.badURL)
            }
            let file = try await downloadOnce(from: mirrorURL, info: info)
            downloadPhase = .done(file)
        } catch {
            routeNote = "加速线不通，正在换直连重试…"
            do {
                let file = try await downloadOnce(from: info.directURL, info: info)
                downloadPhase = .done(file)
            } catch {
                downloadPhase = .failed("下载失败：两条线都没走通。检查网络后再试一次。")
            }
        }
    }

    private func downloadOnce(from url: URL, info: ReleaseInfo) async throws -> URL {
        // The release metadata's size stands in for the total when the
        // response carries no Content-Length (#226) — through the
        // accelerator it usually doesn't, and without a total the
        // progress never moved.
        // Coalesced (cleanup round, 2026-11-13): the delegate fires
        // per chunk; the page reads at most ten updates a second.
        let progress = ProgressCoalescer<DownloadSample>(interval: 0.1) { [weak self] sample in
            guard let self, case .working = self.downloadPhase else { return }
            let fraction = sample.total > 0
                ? min(Double(sample.downloaded) / Double(sample.total), 1)
                : nil
            self.downloadPhase = .working(fraction: fraction,
                                          downloadedBytes: sample.downloaded,
                                          totalBytes: sample.total)
        }
        let bridge = DownloadBridge(fallbackTotal: Int64(info.assetSize)) { downloaded, total in
            Task { @MainActor in
                progress.offer(DownloadSample(downloaded: downloaded, total: total))
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
/// Reports raw byte counts rather than a fraction (#226): when the
/// response has no expected length — the accelerator's usual shape —
/// the caller's fallback total (the release metadata's asset size)
/// stands in, and with neither, the page shows bytes alone.
/// One download-progress reading, the coalescer's unit.
private struct DownloadSample: Equatable {
    let downloaded: Int64
    let total: Int64
}

private final class DownloadBridge: NSObject, URLSessionDownloadDelegate {
    let fallbackTotal: Int64
    let onProgress: (Int64, Int64) -> Void
    init(fallbackTotal: Int64, onProgress: @escaping (Int64, Int64) -> Void) {
        self.fallbackTotal = fallbackTotal
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : fallbackTotal
        onProgress(totalBytesWritten, total)
    }
}
