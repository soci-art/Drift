import Foundation

/// What the way this copy of Drift was installed means for the local
/// channel, in plain words.
///
/// Two facts are all this file states, because they are the two that can
/// actually be known:
///
/// * A copy nested inside another app (LiveContainer and friends) is not
///   installed under its own identity — that is visible from the bundle
///   path, and it blocks the local channel whatever the signature is.
/// * Everything else about the signature is *not* guessed here. Whether a
///   usable App Group exists is a functional fact the group discovery
///   itself establishes (it reads the profile and tries each group); when
///   it finds none, the reason says so in one unified wording that is true
///   for every no-group install — a free-ID signature, a store re-sign, or
///   a paid profile whose groups will not open.
///
/// An earlier version of this file parsed the provisioning profile itself
/// to classify the install, and got it wrong on a paid-certificate install
/// (it counted zero groups where the discovery found a working one), so
/// the classification — and the Settings row that displayed it — is gone.
/// Guessing wrong in the user's face is worse than not guessing.
enum InstallEnvironment {
    /// The app lives inside another app's data container instead of being
    /// installed on its own (LiveContainer and similar).
    case nested
    /// A normal install; nothing more is claimed.
    case standard

    static let current: InstallEnvironment = isNestedInstall ? .nested : .standard

    /// A system-installed app lives in the bundle container; a guest inside
    /// another app lives in that app's *data* container instead.
    private static var isNestedInstall: Bool {
        let path = Bundle.main.bundlePath
        return !path.contains("/containers/Bundle/Application/")
            && path.contains("/Containers/Data/Application/")
    }

    // MARK: - Wording

    /// The local channel's unavailable reason, with the install-method
    /// explanation swapped in when that is the actual blocker.
    static func localReason(version: String, build: String) -> String {
        let functional = WorseQueryEscape.unavailableReason(deviceVersion: version,
                                                            buildVersion: build)
        guard !functional.isEmpty else { return "" }
        // A system out of range is the first blocker, whatever the install.
        guard WorseQueryEscape.isSupported(deviceVersion: version, buildVersion: build)
        else { return functional }
        if current == .nested {
            return "这个 App 是套在另一个 App 里装的（比如 LiveContainer），不是正经装在手机上，本机直刷用不了；要用证书正常签名装到手机上才行。隧道那两种不受这个影响。"
        }
        // #332 (Grace, 2026-11-14): one line — header card and method
        // row both print this, and the named install methods were the
        // first thing she cut.
        return "签名没有能用的存储区，本机直刷用不了，证书签才行。"
    }
}
