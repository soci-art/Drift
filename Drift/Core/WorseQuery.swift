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
/// It is not an entitlement bypass. The worse_query route needs an App Group
/// the process *actually carries*. The bridge asks the system for that list
/// with SecTask (the same way 3106 does) and uses the first group whose
/// container opens (`discoveredGroupIdentifier`); the embedded provisioning
/// profile is not consulted, because a re-sign can carry groups the profile on
/// disk does not list. No group means every worse_query call fails with `-1`
/// and `isAvailable` says no.
///
/// iOS 26.0–26.6.1 is the overlap segment: both backends cover it, so the
/// signing decides — a process carrying a usable App Group takes
/// `worse_query`, one without takes `bad_query`, which needs no App Group
/// at all. 26.7+ and 27.x take `worse_query` only.
///
/// ## Supported systems
///
/// Upstream states iOS 26.0 – 26.7.2 and 27.x up to 27.3; Drift admits less:
/// 27.2 stops at 27.2.1 and 27.3 is beta 1 only, by build number. An
/// unparsable or empty version is refused rather than guessed at: on an
/// unknown system the extension must not be attempted.
enum WorseQueryEscape {
    // MARK: - Configuration

    /// The App Group this process actually carries, discovered at runtime.
    ///
    /// 3106 reads the process's own entitlements with SecTask instead of
    /// trusting the embedded provisioning profile: a p12 / SideStore / AltStore
    /// re-sign carries whatever groups the signing certificate granted, and the
    /// profile on disk can be absent or list a different set. Every grant name
    /// is then tried in the entitlement's own order, and the first one whose
    /// container opens is used. No group, or none that opens, means the
    /// worse_query route is unavailable — there is deliberately no hard-coded
    /// fallback.
    static let discoveredGroupIdentifier: String? = {
        guard let raw = drift_app_group() else { return nil }
        defer { drift_app_group_free(raw) }
        let group = String(cString: raw)
        return group.isEmpty ? nil : group
    }()

    /// The App Group's container, or nil when the profile grants none this
    /// process can open. Resolved once per process.
    private static let resolvedGroupContainer: URL? =
        discoveredGroupIdentifier.flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }

    /// The sandbox backend the running system takes, split the way 3106 does.
    enum Backend: String {
        case badQuery
        case worseQuery
        case unsupported
    }

    static func backend(deviceVersion: String, buildVersion: String = "") -> Backend {
        let parts = deviceVersion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]) else { return .unsupported }
        let patch = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        // 3106 keeps bad_query as the primitive backend on the builds it was
        // verified for; 26.7+ and 27.x take worse_query. Drift's own ceiling
        // is narrower than upstream's stated range: 27.2 stops at 27.2.1 and
        // 27.3 is admitted only as beta 1, identified by its build number.
        // The overlap segment (Grace, 2026-11-18): the version picks the
        // segment, the group picks the backend inside it — a usable group
        // (what a certificate signature grants) takes worse_query, no
        // group takes bad_query. The group is resolved once per process,
        // so consume / release / describe all derive the same answer.
        if major == 26, minor < 6 || (minor == 6 && patch <= 1) {
            return groupContainer != nil ? .worseQuery : .badQuery
        }
        if major == 26, minor == 7, patch <= 2 { return .worseQuery }
        if major == 27 {
            if minor < 2 { return .worseQuery }
            if minor == 2, patch <= 1 { return .worseQuery }
            if minor == 3, patch == 0,
               buildVersion.trimmingCharacters(in: .whitespacesAndNewlines) == "24C5037i" {
                return .worseQuery
            }
        }
        return .unsupported
    }

    // MARK: - Failures

    enum Failure: LocalizedError {
        /// The system is outside the range upstream supports.
        case unsupportedSystem(String)
        /// No App Group container the process can open (worse_query only).
        case groupUnavailable
        /// The selected backend itself: target missing, symbols missing,
        /// query refused…
        case refused(code: Int64)

        var errorDescription: String? {
            switch self {
            case .unsupportedSystem(let version):
                return "本机直刷只支持 iOS 26.0–26.7.2、27.0–27.2.1，以及 iOS 27.3 beta 1（构建 24C5037i）；"
                    + "这台设备报告的是 \(version.isEmpty ? "未知系统" : "iOS \(version)")。"
            case .groupUnavailable:
                return "当前进程没有可用的 App Group，worse_query 用不了。"
                    + "App 会向系统查询本进程实际带着的组并逐个试开；列表为空或一个都打不开时才会报这一条。"
            case .refused(let code):
                return WorseQueryEscape.describe(code: code)
            }
        }
    }

    /// The error code the selected backend returned, in the words the user
    /// needs. The two backends share the negative-number style but not the
    /// meanings, so the mapping is per backend.
    private static func describe(code: Int64) -> String {
        switch backend(deviceVersion: processVersion,
                       buildVersion: processBuildVersion) {
        case .badQuery:
            switch code {
            case -1:
                return "这台系统上找不到 bad_query 需要的私有接口（系统可能已不在支持范围内）。"
            case -2:
                return "containermanagerd 查询创建失败。"
            case -3:
                return "containermanagerd 拒绝了查询（目标路径不存在或不可查询）。"
            case -4:
                return "沙盒扩展签发结果里没有 token。"
            case -5:
                return "构造查询的相对路径失败。"
            case -254:
                return "目标路径不存在（授权前的只读检查失败）。"
            case -255:
                return "目标路径不存在。"
            default:
                return "本机直刷写入失败（bad_query 代码 \(code)）。"
            }
        case .worseQuery, .unsupported:
            switch code {
            case -1:
                return "拿不到 App Group 容器：当前进程没有授予可用的 App Group。"
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
            case -254:
                return "目标路径不存在（授权前的只读检查失败）。"
            case -255:
                return "目标路径不存在。"
            default:
                return "本机直刷写入失败（worse_query 代码 \(code)）。"
            }
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
    /// bad_query on 26.0–26.6.1; worse_query on 26.7–26.7.2, 27.0–27.2.1 and
    /// 27.3 beta 1 (build 24C5037i) — Drift's own ceiling, narrower than
    /// upstream's stated range. Everything else fails closed.
    static func isSupported(deviceVersion: String, buildVersion: String = "") -> Bool {
        backend(deviceVersion: deviceVersion, buildVersion: buildVersion) != .unsupported
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
        switch backend(deviceVersion: deviceVersion, buildVersion: buildVersion) {
        case .badQuery:
            // The bad_query route needs no App Group at all.
            return true
        case .worseQuery:
            return groupContainer != nil
        case .unsupported:
            return false
        }
    }

    /// Why the route is unavailable, or `""` when it is available.
    ///
    /// One wording for the judgement card, the engine's pre-run check and the
    /// menu item's disabled state, so the three cannot drift apart.
    static func unavailableReason(deviceVersion: String, buildVersion: String = "") -> String {
        if !isSupported(deviceVersion: deviceVersion, buildVersion: buildVersion) {
            return "本机直刷只支持 iOS 26.0–26.7.2、27.0–27.2.1，以及 iOS 27.3 beta 1（构建 24C5037i）；"
                + "这台设备报告的是 \(deviceVersion.isEmpty ? "未知系统" : "iOS \(deviceVersion)")"
                + (buildVersion.isEmpty ? "。" : "（\(buildVersion)）。")
        }
        if backend(deviceVersion: deviceVersion, buildVersion: buildVersion) == .worseQuery,
           groupContainer == nil {
            return "worse_query 需要进程实际带着可用的 App Group，但这个进程没有可打开的组。"
                + "App 会向系统查询进程自己带着的组（SecTask），逐个试开，第一个能打开的才用。"
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
        let route = backend(deviceVersion: processVersion, buildVersion: processBuildVersion)
        guard route != .unsupported else { throw Failure.unsupportedSystem(processVersion) }

        var cPath = Array(path.utf8CString)
        let handle: Int64
        switch route {
        case .badQuery:
            handle = bad_query(&cPath, true, nil, false)
            AppLog.write("bad_query: consume path=\(path) → "
                + (handle > 0 ? "handle \(handle)" : "error \(handle)"))
        case .worseQuery:
            guard groupContainer != nil else { throw Failure.groupUnavailable }
            // The reference's own rule: iOS 26.x needs the alternate flag set
            // when the target is itself an App Group path. PosterBoard's
            // container is an app container, so this is false for the calls
            // this app makes today — kept so a future target is handled the
            // way upstream handles it.
            let alternate = path.contains("/var/mobile/Containers/Shared/AppGroup")
                && ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
            guard let group = discoveredGroupIdentifier else { throw Failure.groupUnavailable }
            handle = worse_query(path, group, alternate, createDirectory)
            AppLog.write("worse_query: consume path=\(path) group=\(group) "
                + "createDirectory=\(createDirectory) → "
                + (handle > 0 ? "handle \(handle)" : "error \(handle)"))
        case .unsupported:
            throw Failure.unsupportedSystem(processVersion)
        }
        guard handle > 0 else { throw Failure.refused(code: handle) }
        return handle
    }

    /// Release a handle returned by `consume(path:)`.
    static func release(_ handle: Int64) {
        switch backend(deviceVersion: processVersion, buildVersion: processBuildVersion) {
        case .badQuery:
            bad_query_release(handle)
        case .worseQuery:
            worse_query_release(handle)
        case .unsupported:
            break
        }
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

    /// One inclusive inode range, same prefix and direct-child rules as the
    /// full `pathleak` call above. The cold-location pipeline uses this to
    /// stop as soon as a segment identifies PosterBoard.
    static func leakedChildren(in directory: String, from start: UInt64, to end: UInt64) -> [String] {
        pathleak_range(directory, start, end) as? [String] ?? []
    }

    /// The upper bound and cleanup for the segmented scan.
    ///
    /// Kept next to `leakedChildren(of:)` so the temp-file rule is not
    /// duplicated: the file is created once, read for its inode, and removed
    /// when the whole location attempt is over.
    static func pathleakScanLimit() -> (maxInode: UInt64, cleanup: () -> Void)? {
        pathleakInodeUpperBound()
    }

    // MARK: - Enumeration probe

    /// One timed parallel enumeration. `paths` is the merged, inode-ordered
    /// result; `milliseconds` is measured around the C call only.
    struct PathleakProbeMeasurement {
        let paths: [String]
        let milliseconds: Double
    }

    /// The directory the probe walks (the same applications root as the
    /// normal leak fallback).
    static var pathleakProbeDirectory: String { PosterBoardLocal.pathleakProbeDirectory }

    /// Create the probe's upper-bound file once and return its inode.
    ///
    /// The caller must invoke `cleanup` when the whole probe run is over; the
    /// file is deliberately kept for every round so 1/4, full and cross-check
    /// all use the same `max_inode`.
    static func pathleakInodeUpperBound() -> (maxInode: UInt64, cleanup: () -> Void)? {
        let manager = FileManager.default
        let probe = manager.temporaryDirectory
            .appendingPathComponent(".drift-enum-probe-\(UUID().uuidString)")
        guard (try? Data("x".utf8).write(to: probe)) != nil else { return nil }
        guard let attributes = try? manager.attributesOfItem(atPath: probe.path),
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            try? manager.removeItem(at: probe)
            return nil
        }
        return (inode.uint64Value, { try? manager.removeItem(at: probe) })
    }

    /// Run `pathleak_parallel` over `1...limit` and time it.
    static func measurePathleak(threads: Int, limit: UInt64) -> PathleakProbeMeasurement {
        let started = Date()
        let paths = pathleak_parallel(pathleakProbeDirectory, limit, UInt(max(1, threads))) as? [String] ?? []
        return PathleakProbeMeasurement(paths: paths,
                                        milliseconds: Date().timeIntervalSince(started) * 1000)
    }
}
