import Foundation

/// The app's own version numbers, read from the bundle in exactly
/// one place (#315 cleanup: the assembly used to be written out in
/// four places — the update checker, the announcement, diagnostics
/// and the About page — each with a different fallback for a missing
/// key, so the same screen could disagree with itself in the edge
/// case and every reader had to re-derive the same two values).
///
/// The keys are always present in a built app; the "0" fallbacks only
/// keep a malformed bundle from crashing a reader.
enum AppVersion {
    /// "3.2.0"
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// "51"
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var buildNumber: Int { Int(build) ?? 0 }

    /// "3.2.0（构建 51）" — the user-facing form.
    static var display: String { "\(marketing)（构建 \(buildNumber)）" }

    /// "3.2.0 (51)" — the compact id form (announcement seen-keys).
    static var id: String { "\(marketing) (\(build))" }

    /// Which release line this build belongs to (Grace, 2026-11-16:
    /// the two lines check for updates separately, each on its own
    /// line). Stamped at build time — the workflow sets DRIFT_CHANNEL
    /// from the commit markers and project.yml defaults it to the
    /// release line — and read back from the bundle's DriftChannel
    /// key. Anything that is not exactly "nightly" is the release
    /// line, so unstamped and older builds keep the historical
    /// behaviour of watching the formal releases only.
    enum Channel { case release, nightly }

    static var channel: Channel {
        (Bundle.main.object(forInfoDictionaryKey: "DriftChannel") as? String) == "nightly"
            ? .nightly : .release
    }
}
