import Foundation

/// One-tap log upload (Grace, 2026-11-12): the user taps「上传日志」in
/// Settings, sees what the package holds, confirms, and the same zip the
/// share flow builds is posted to the developer inbox
/// (log.86419753.xyz, a Cloudflare Worker + KV store, 7-day expiry).
///
/// The standing rules for this feature, set when the inbox was built:
///   * upload only on an explicit tap — never automatic, never silent;
///   * the app carries NO key or token: the upload door is open by
///     design (it accepts only zip files, size-capped), the key only
///     guards the pickup side, which the app never touches;
///   * no name field, no note field, and no tracking code comes back —
///     the user just sees that it went through.
enum LogUpload {
    /// The inbox's upload door. The bare domain answers on `/` as well;
    /// `/upload` is the documented path.
    static let endpoint = URL(string: "https://log.86419753.xyz/upload")!

    /// The inbox's per-package cap (20 MB; its store's own ceiling is
    /// 25 MB). Checked before sending so an oversized package fails
    /// here with a plain explanation instead of a server rejection.
    static let maxBytes = 20 * 1024 * 1024

    /// Post a packaged log zip. Throws a plain-language DriftError for
    /// every failure the user can act on.
    static func upload(package: URL) async throws {
        let data = try Data(contentsOf: package)
        guard !data.isEmpty else {
            throw DriftError("日志包是空的")
        }
        guard data.count <= maxBytes else {
            throw DriftError("日志包太大了（超过 20 MB）")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        // The inbox list shows this name. Header values travel as
        // Latin-1 at best, so the name is reduced to its ASCII skeleton
        // first ("Drift记录-20261112-093000.zip" becomes
        // "Drift-20261112-093000.zip") — the inbox's own sanitiser
        // would have replaced the rest with underscores anyway.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_ "))
        let headerName = package.lastPathComponent.unicodeScalars
            .filter { $0.isASCII && allowed.contains($0) }
            .map { String($0) }.joined()
        request.setValue(headerName.isEmpty ? "drift-log.zip" : headerName,
                         forHTTPHeaderField: "X-File-Name")
        request.httpBody = data
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DriftError("网络不好")
        }
        guard let http = response as? HTTPURLResponse else {
            throw DriftError("服务器没回应")
        }
        switch http.statusCode {
        case 200:
            // The door answers {"ok": true}; anything else on a 200 is
            // not a success we can claim.
            let ok = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
            guard (ok?["ok"] as? Bool) == true else {
                throw DriftError("服务器回应不对")
            }
        case 413:
            throw DriftError("日志包太大了（超过 20 MB）")
        case 429:
            throw DriftError("上传太频繁了，过一会儿再试")
        default:
            throw DriftError("服务器出问题了")
        }
    }
}
