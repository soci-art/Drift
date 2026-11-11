import Foundation
import Darwin
import WorseQuery

/// In-process access to the sandbox escape from
/// [forcequitOS/worse_query](https://github.com/forcequitOS/worse_query).
///
/// ## What this is
///
/// `worse_query` turns a symlink inside the app's **own App Group container**
/// into a sandbox extension for any path on the device. It resolves
/// containermanagerd's private query functions at runtime, points the group's
/// `Library/Caches` at the target, asks for an app-group container query (class
/// 7, part 3) and consumes the extension the query is issued for. The symlink is
/// deleted again before the call returns; the extension stays until it is
/// released.
///
/// Drift uses that for exactly one thing: writing wallpaper descriptors into
/// PosterBoard's data container without a pairing record or a tunnel. See
/// `PosterBoardLocal`.
///
/// ## What it is not
///
/// It is not an entitlement bypass. The App Group has to be real and has to be
/// granted by the signing profile the app was installed with
/// (`com.apple.security.application-groups` in its embedded
/// `.mobileprovision`). The bridge discovers which groups that profile grants at
/// runtime and uses the first whose container opens
/// (`discoveredGroupIdentifier`); without one every call fails with `-1` and
/// `isAvailable` says no, so a free "personal team" install simply keeps using
/// the tunnel routes.
///
/// ## Supported systems
///
/// Upstream states iOS 26.0 – 26.7.2 and 27.x up to 27.2. An unparsable or empty
/// version is refused rather than guessed at: on an unknown system the extension
/// must not be attempted.
enum WorseQueryEscape {
    // MARK: - Configuration

    /// The App Group the escape stages its symlink in, discovered at runtime.
    ///
    /// A group name is not a free choice: it has to be one the *installed*
    /// signing profile actually grants. The hard-coded name this used to carry
    /// (`group.com.sociart.drift`) only matches some paid profiles — a p12
    /// certificate often gets `group.<hash>.1`, and SideStore / AltStore re-sign
    /// with their own prefix — and a mismatch made
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` return nil, so the
    /// whole in-process route reported "no App Group" on a build that had one.
    ///
    /// The bridge therefore reads the entitlements of the provisioning profile
    /// embedded in the installed app (`embedded.mobileprovision`), asks the
    /// system to open each granted group in order, and keeps the first that
    /// opens. The container resolution and every `worse_query` call use that
    /// discovered name. No group, or none that opens, means the route is
    /// unavailable — there is deliberately no hard-coded fallback.
    static let discoveredGroupIdentifier: String? = discoverGroupIdentifier()

    /// The App Group's container, or nil when the profile grants none this
    /// process can open. Resolved once per process.
    private static let resolvedGroupContainer: URL? =
        discoveredGroupIdentifier.flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }

    /// The entitlement that carries the granted App Group list.
    private static let applicationGroupsKey = "com.apple.security.application-groups"

    /// The profile the installed app was signed with, if the bundle has one.
    ///
    /// Read from the app bundle rather than from the build's entitlements: the
    /// profile that matters is the one the installer actually used, which is
    /// exactly what a reset (SideStore / AltStore / a p12) rewrites.
    private static func embeddedProvisioningProfile() -> Data? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// The first granted group whose container opens, or nil.
    ///
    /// Order is the profile's own: the first entry is the one the signing tool
    /// put there first, and any of them is enough for the escape.
    static func discoverGroupIdentifier(profileData: Data? = WorseQueryEscape.embeddedProvisioningProfile()) -> String? {
        guard let profileData else { return nil }
        for group in applicationGroups(inProvisioningProfile: profileData) {
            if FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group) != nil {
                return group
            }
        }
        return nil
    }

    /// The `application-groups` list from a provisioning profile.
    ///
    /// A `.mobileprovision` is a CMS signature wrapped around the plist; the
    /// plist is the `<?xml … </plist>` slice inside it, so the bytes are cut at
    /// those markers and parsed as XML rather than fed to
    /// `PropertyListSerialization` whole (which only accepts the CMS blob as an
    /// opaque signature and finds no entitlements in it).
    static func applicationGroups(inProvisioningProfile data: Data) -> [String] {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8),
                                   options: [],
                                   in: start.lowerBound..<data.endIndex) else { return [] }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements[applicationGroupsKey] as? [String] else { return [] }
        return groups
    }

    // MARK: - Failures

    enum Failure: LocalizedError {
        /// The system is outside the range upstream supports.
        case unsupportedSystem(String)
        /// No App Group container — wrong profile, or no entitlement at all.
        case groupUnavailable
        /// `worse_query` itself: target missing, symbols missing, query refused…
        case refused(code: Int64)

        var errorDescription: String? {
            switch self {
            case .unsupportedSystem(let version):
                return "本机直刷只支持 iOS 26.0–26.7.2 和 27.0–27.2；"
                    + "这台设备报告的是 \(version.isEmpty ? "未知系统" : "iOS \(version)")。"
            case .groupUnavailable:
                return "当前签名没有授予可用的 App Group，本机直刷用不了。"
                    + "App 会读取安装包签名里实际授予的组；组名单为空或一个都打不开时才会报这一条。"
            case .refused(let code):
                return WorseQueryEscape.describe(code: code)
            }
        }
    }

    /// The error code `worse_query` returned, in the words the user needs.
    ///
    /// The numbers are the reference implementation's contract
    /// (`worse_query.m`), not a Drift invention; `-255` is its "target does not
    /// exist", which for this app means the cached PosterBoard container is
    /// stale.
    private static func describe(code: Int64) -> String {
        switch code {
        case -1:
            return "拿不到 App Group 容器：当前签名没有授予可用的 App Group。"
        case -2:
            return "这台系统上找不到本机直刷需要的私有接口（系统可能已不在支持范围内）。"
        case -3:
            return "containermanagerd 查询创建失败。"
        case -4:
            return "无法在 App Group 里创建临时符号链接。"
        case -5:
            return "containermanagerd 拒绝了查询（目标路径不存在或不可查询）。"
        case -6:
            return "内核拒绝签发沙盒扩展（返回码 -6）。"
        case -255:
            return "目标路径不存在。"
        default:
            return "本机直刷写入失败（代码 \(code)）。"
        }
    }

    // MARK: - System checks

    /// The app's own iOS version, e.g. `26.1` or `27.2`.
    ///
    /// The jailbreak-free route needs no device read: the app *is* the device.
    /// This is what the mode judgement uses when no pairing record is present,
    /// which is the whole point of the mode.
    static var processVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// The running system's build (for example `24C5037i`).
    ///
    /// `ProcessInfo` only exposes the version, and the one range extension
    /// this build makes — 27.3 beta 1 — is identified by build, not by the
    /// three-part version every 27.3 build shares.
    static var processBuildVersion: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the running system is in the channel's range.
    ///
    /// Accepts 26.0 through 26.7.2, 27.0 through 27.2.1, and 27.3 beta 1
    /// (`24C5037i`, marked experimental in the UI). The 27.2.1 and 27.3 beta 1
    /// extensions were decided on 2026-11-11; the 27.3 one rests on Erosion's
    /// public claim and has not been verified on a device here, so it is not
    /// treated as a stable range. Everything else fails closed.
    static func isSupported(deviceVersion: String, buildVersion: String = "") -> Bool {
        let parts = deviceVersion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]) else { return false }
        let patch = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        switch major {
        case 26:
            return minor < 7 || (minor == 7 && patch <= 2)
        case 27:
            if minor < 2 { return true }
            if minor == 2 { return patch <= 1 }
            if minor == 3 {
                return patch == 0 && buildVersion
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "24C5037i"
            }
            return false
        default:
            return false
        }
    }

    /// The App Group's container, or nil when the profile does not grant it.
    ///
    /// Resolved once per process. The container path does not change while the
    /// app runs, and this is read from a view body (the mode menu, the
    /// judgement card and the apply button all consult it), which must not ask
    /// containermanagerd on every redraw.
    static var groupContainer: URL? { resolvedGroupContainer }

    /// Whether a run may use this route right now.
    ///
    /// Both halves matter and both are cheap: the version bound, and the
    /// entitlement the escape cannot work without.
    static func isAvailable(deviceVersion: String, buildVersion: String = "") -> Bool {
        isSupported(deviceVersion: deviceVersion, buildVersion: buildVersion)
            && groupContainer != nil
    }

    /// Why the route is unavailable, or `""` when it is available.
    ///
    /// One wording for the judgement card, the engine's pre-run check and the
    /// menu item's disabled state, so the three cannot drift apart.
    static func unavailableReason(deviceVersion: String, buildVersion: String = "") -> String {
        if !isSupported(deviceVersion: deviceVersion, buildVersion: buildVersion) {
            return "本机直刷只支持 iOS 26.0–26.7.2、27.0–27.2.1，以及 27.3 测试版 1（24C5037i，实验）；"
                + "这台设备报告的是 \(deviceVersion.isEmpty ? "未知系统" : "iOS \(deviceVersion)")"
                + (buildVersion.isEmpty ? "。" : "（\(buildVersion)）。")
        }
        if groupContainer == nil {
            return "本机直刷需要签名授予可用的 App Group，但这份签名没有可用的组。"
                + "App 会读取安装包里签名授予的组名单并逐个试开；付费证书、SideStore / AltStore 改签都可以。"
        }
        return ""
    }

    // MARK: - Extension handles

    /// Consume an extension for `path` and return its handle.
    ///
    /// - Parameters:
    ///   - path: an absolute, canonical path (`/private/var/…`; the
    ///     `/var` symlink form is not what containermanagerd resolves).
    ///   - createDirectory: skip the existence check for a path the caller is
    ///     about to create.
    /// - Returns: a positive handle. Every successful call must be paired with
    ///   `release(_:)`.
    static func consume(path: String, createDirectory: Bool = false) throws -> Int64 {
        if !isSupported(deviceVersion: processVersion, buildVersion: processBuildVersion) {
            throw Failure.unsupportedSystem(processVersion)
        }
        guard groupContainer != nil else { throw Failure.groupUnavailable }

        // The reference's own rule: iOS 26.x needs the alternate flag set when
        // the target is itself an App Group path. PosterBoard's container is an
        // app container, so this is false for the calls this app makes today —
        // kept so a future target is handled the way upstream handles it.
        let alternate = path.contains("/var/mobile/Containers/Shared/AppGroup")
            && ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26

        guard let group = discoveredGroupIdentifier else { throw Failure.groupUnavailable }
        let handle = worse_query(path, group, alternate, createDirectory)
        AppLog.write("worse_query: consume path=\(path) group=\(group) "
            + "createDirectory=\(createDirectory) → "
            + (handle > 0 ? "handle \(handle)" : "error \(handle)"))
        guard handle > 0 else { throw Failure.refused(code: handle) }
        return handle
    }

    /// Release a handle returned by `consume(path:)`.
    static func release(_ handle: Int64) {
        worse_query_release(handle)
    }

    /// Run `body` with a consumed extension for `path`, releasing it afterwards
    /// even when the body throws.
    ///
    /// Every caller that writes through the escape needs this shape: the handle
    /// is only valid until it is released, and a `defer` at the call site is easy
    /// to lose on one of several early returns. The extension is process-wide
    /// once consumed, so `body` does not receive it.
    static func withAccess<T>(to path: String, createDirectory: Bool = false,
                              _ body: () throws -> T) throws -> T {
        let handle = try consume(path: path, createDirectory: createDirectory)
        defer { release(handle) }
        return try body()
    }

    /// Immediate children of `directory`, enumerated by brute-forcing inodes
    /// when a directory listing is not available.
    ///
    /// This is upstream's `pathleak`: the app cannot list an app-container
    /// directory until it already holds an extension for it, so the fallback
    /// finds the paths first and lets the caller try each one. The bound is a
    /// file the app just created on the same volume, which is how upstream's
    /// demo derives it; the walk is then linear in that inode number, so this
    /// is a last resort, not the normal path.
    ///
    /// Call it while an extension for `directory` is held: `pathleak` starts
    /// with `statfs`, which is itself subject to the sandbox.
    static func leakedChildren(of directory: String) -> [String] {
        let manager = FileManager.default
        let probe = manager.temporaryDirectory
            .appendingPathComponent(".drift-inode-\(UUID().uuidString)")
        guard (try? Data("x".utf8).write(to: probe)) != nil else { return [] }
        defer { try? manager.removeItem(at: probe) }

        guard let attributes = try? manager.attributesOfItem(atPath: probe.path),
              let inode = attributes[.systemFileNumber] as? NSNumber else { return [] }
        return pathleak(directory, inode.uint64Value) ?? []
    }
}
