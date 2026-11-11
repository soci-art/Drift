import Foundation

/// How this copy of Drift was installed, worked out from the app itself —
/// and what that means for the local channel, in plain words.
///
/// The local channel needs two things: a system in range, and an App Group
/// the signature actually grants. When the second one fails, the cause is
/// usually *how the app was installed*: a free-ID signature grants no group
/// at all, and a copy nested inside another app (LiveContainer and friends)
/// is not installed under its own identity. Naming that cause beats the
/// generic "no usable group" line, so the judgement surfaces use the
/// explanation from here when it applies.
///
/// This is an explanation layer only. The functional checks stay in charge:
/// a channel is usable exactly when its own checks pass, whatever this file
/// guesses about the install. Detection that is not sure says `.unknown`,
/// and the plain functional wording is used instead.
enum InstallEnvironment {
    /// The signature grants at least one App Group (paid certificate, or a
    /// store re-sign that adds groups).
    case withGroups
    /// A signature is embedded but it grants no App Group at all — what a
    /// free Apple ID signature looks like.
    case withoutGroups
    /// The app lives inside another app's data container instead of being
    /// installed on its own (LiveContainer and similar).
    case nested
    /// Nothing sure can be said.
    case unknown

    static let current = detect()

    // MARK: - Detection

    private static func detect() -> InstallEnvironment {
        if isNestedInstall { return .nested }
        guard let count = provisionedGroupCount else { return .unknown }
        return count > 0 ? .withGroups : .withoutGroups
    }

    /// A system-installed app lives in the bundle container; a guest inside
    /// another app lives in that app's *data* container instead.
    private static var isNestedInstall: Bool {
        let path = Bundle.main.bundlePath
        return !path.contains("/containers/Bundle/Application/")
            && path.contains("/Containers/Data/Application/")
    }

    /// How many App Groups the embedded provisioning profile grants, or nil
    /// when there is no readable profile to ask.
    private static var provisionedGroupCount: Int? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let slice = plistSlice(data),
              let root = try? PropertyListSerialization.propertyList(from: slice, format: nil) as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any]
        else { return nil }
        return (entitlements["application-groups"] as? [String])?.count ?? 0
    }

    /// A .mobileprovision is a signed blob with a plist inside; cut out the
    /// `<?xml … </plist>` span, the same way the group discovery does.
    private static func plistSlice(_ data: Data) -> Data? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        return data[start.lowerBound..<end.upperBound]
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
        switch current {
        case .nested:
            return "这个 App 是套在另一个 App 里装的（比如 LiveContainer），不是正经装在手机上，本机直刷用不了；要用付费证书正常签名装到手机上才行。隧道那两种不受这个影响。"
        case .withoutGroups:
            return "你这个签名没带能用的存储区，本机直刷用不了。本机直刷只有付费证书签的才行——免费 ID 签、SideStore / AltStore 改签都给不了能用的存储区。"
        case .withGroups:
            return "你这份签名里的存储区都打不开，本机直刷用不了。重新用付费证书签一次再试；还不行就把日志包发出来排查。"
        case .unknown:
            return "本机直刷要用到签名里的存储区，你这份签名没有能打开的，所以用不了。本机直刷只有付费证书签的才行——免费 ID 签、SideStore / AltStore 改签都用不了。"
        }
    }

    /// One short line for Settings, or nil when nothing sure can be said.
    var settingsLabel: String? {
        switch self {
        case .withGroups: return "付费证书签名（带存储区）"
        case .withoutGroups: return "签名没带存储区（免费 ID 签或商店改签）"
        case .nested: return "套在另一个 App 里装的"
        case .unknown: return nil
        }
    }
}
