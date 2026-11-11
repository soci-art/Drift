import Foundation
import Combine

/// Bounded metadata requests using the system TLS trust store. Cache is handled
/// by each service, so HTTP errors cannot overwrite the last valid rules/release.
enum RemoteMetadataError: LocalizedError {
    case httpStatus(Int)
    var errorDescription: String? {
        switch self { case .httpStatus(let code): return "服务器返回了 HTTP \(code)。" }
    }
}

enum RemoteMetadata {
    static func fetch(_ url: URL, session: URLSession = .shared) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Drift", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { throw RemoteMetadataError.httpStatus(http.statusCode) }
        let limit = 2 * 1024 * 1024
        guard response.expectedContentLength <= Int64(limit) else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            if data.count >= limit { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}

/// One coalesced check per foreground session, plus an explicit Settings check.
/// Failure retains the last release and its original check time and is shown as
/// a failure, never as "up to date". No release (404) is a separate state.
@MainActor
final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()
    @Published private(set) var release: AppRelease?
    @Published private(set) var noReleases = false
    @Published private(set) var checking = false
    @Published private(set) var checkedAt: Date?
    @Published private(set) var error: String?
    private var lastAttempt: Date?
    private let session: URLSession
    private let installedVersion: String

    init(session: URLSession = .shared,
         installedVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") {
        self.session = session
        self.installedVersion = installedVersion
    }

    var available: AppRelease? { release.flatMap { $0.isNewer(than: installedVersion) ? $0 : nil } }
    var releaseURL: URL { release?.pageURL ?? AppRelease.latestURL }

    func refresh(force: Bool = false) async {
        guard !checking, force || lastAttempt.map({ Date().timeIntervalSince($0) >= 3600 }) ?? true else { return }
        checking = true
        lastAttempt = Date()
        defer { checking = false }
        do {
            let data = try await RemoteMetadata.fetch(AppRelease.apiURL, session: session)
            let parsed = try AppRelease.parse(data)
            guard !Task.isCancelled else { return }
            release = parsed
            noReleases = false
            checkedAt = Date()
            error = nil
        } catch RemoteMetadataError.httpStatus(404) {
            release = nil
            noReleases = true
            checkedAt = Date()
            error = nil
        } catch is CancellationError { } catch {
            guard !Task.isCancelled else { return }
            self.error = "Could not check for updates. \(error.localizedDescription)"
        }
    }
}
