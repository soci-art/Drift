import Foundation
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
/// granted by the signing profile (`com.apple.security.application-groups` in
/// `entitlements.plist`). Without it `containerURL(forSecurityApplicationGroupIdentifier:)`
/// returns nil, every call fails with `-1`, and `isAvailable` says no — so a
/// free "personal team" install simply keeps using AirLift or the backup route.
///
/// ## Supported systems
///
/// Upstream states iOS 26.0 – 26.7.2 and 27.x up to 27.2. An unparsable or empty
/// version is refused rather than guessed at: on an unknown system the extension
/// must not be attempted.
enum WorseQueryEscape {
    // MARK: - Configuration

    /// The App Group the escape stages its symlink in.
    ///
    /// This is not a free choice: it has to be a group the signing profile
    /// grants. It is written once here and once in `entitlements.plist`, and the
    /// two must stay in step — a profile that grants a different group makes
    /// this mode report itself unavailable rather than fail a run half-way.
    static let groupIdentifier = "group.com.sociart.drift"

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
                return "本机直刷需要签名里带 App Group \(WorseQueryEscape.groupIdentifier)，"
                    + "当前签名没有这个权限。免费 Apple ID 签不了 App Group，需要付费证书。"
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
            return "拿不到 App Group 容器：签名里没有 \(groupIdentifier) 权限。"
        case -2:
            return "这台系统上找不到 worse_query 需要的私有接口（系统可能已不在支持范围内）。"
        case -3:
            return "containermanagerd 查询创建失败。"
        case -4:
            return "无法在 App Group 里创建临时符号链接。"
        case -5:
            return "containermanagerd 拒绝了查询（目标路径不存在或不可查询）。"
        case -6:
            return "内核拒绝签发沙盒扩展。"
        case -255:
            return "目标路径不存在。"
        default:
            return "worse_query 失败（代码 \(code)）。"
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

    /// Whether upstream supports the running system.
    ///
    /// Accepts 26.0 through 26.7.2, and 27.0 through 27.2. The upper bounds are
    /// upstream's; a 26.7.3 or 27.3 device fails closed here rather than trying
    /// an escape that was never verified there.
    static func isSupported(deviceVersion: String) -> Bool {
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
            return minor <= 2
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
    private static let resolvedGroupContainer: URL? =
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier)

    static var groupContainer: URL? { resolvedGroupContainer }

    /// Whether a run may use this route right now.
    ///
    /// Both halves matter and both are cheap: the version bound, and the
    /// entitlement the escape cannot work without.
    static func isAvailable(deviceVersion: String) -> Bool {
        isSupported(deviceVersion: deviceVersion) && groupContainer != nil
    }

    /// Why the route is unavailable, or `""` when it is available.
    ///
    /// One wording for the judgement card, the engine's pre-run check and the
    /// menu item's disabled state, so the three cannot drift apart.
    static func unavailableReason(deviceVersion: String) -> String {
        if !isSupported(deviceVersion: deviceVersion) {
            return "本机直刷只支持 iOS 26.0–26.7.2 和 27.0–27.2；"
                + "这台设备报告的是 \(deviceVersion.isEmpty ? "未知系统" : "iOS \(deviceVersion)")。"
        }
        if groupContainer == nil {
            return "本机直刷需要签名里带 App Group \(groupIdentifier)（付费证书），"
                + "当前签名没有这个权限。"
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
        if !isSupported(deviceVersion: processVersion) {
            throw Failure.unsupportedSystem(processVersion)
        }
        guard groupContainer != nil else { throw Failure.groupUnavailable }

        // The reference's own rule: iOS 26.x needs the alternate flag set when
        // the target is itself an App Group path. PosterBoard's container is an
        // app container, so this is false for the calls this app makes today —
        // kept so a future target is handled the way upstream handles it.
        let alternate = path.contains("/var/mobile/Containers/Shared/AppGroup")
            && ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26

        let handle = worse_query(path, groupIdentifier, alternate, createDirectory)
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
