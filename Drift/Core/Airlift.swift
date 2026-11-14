import Foundation
import AirliftFFI

/// AirLift's AirTraffic sandbox escape, as a thin Swift face over the vendored C FFI.
///
/// ## What this is for
///
/// Everything else in this app writes preferences through a *backup*:
/// `ProtectiveBackup` → prune → inject → restore, so the device's own files are
/// what gets replaced and iOS reads them on its terms. That cannot reach inside
/// an app's container. Apple Wallet's card artwork lives in Passbook's caches
/// under the Wallet data container, and the passcode dialer's themes live in
/// `TelephonyUI`'s — there is no manifest domain for either, so there is nothing
/// to put in a backup and no way to make `mobilebackup2` carry it. AirLift is
/// the AirTraffic sandbox escape: it opens a tunnel over a pairing record and
/// writes files straight into those containers.
///
/// ## Why it is a separate connection, not a Minimuxer gateway
///
/// `AirliftFFI` takes a *pairing file path* and opens its own RSD tunnel. This
/// app already has a tunnel (minimuxer, via LocalDevVPN) for lockdown, AFC and
/// mobilebackup2. They are deliberately not unified: minimuxer holds a long-lived
/// lockdownd session that the whole app depends on, and every `al_exploit_*` call
/// blocks for as long as the operation takes. Sharing one connection would mean a
/// Wallet write can stall the backup the rest of the app is in the middle of.
/// Two tunnels, one pairing file, no shared state.
///
/// ## Availability
///
/// iOS 17.0 and newer — the floor the same-origin product ships at, decided
/// 2026-11-11. The vendored Rust carries no version check of its own, so this
/// application-layer bound is the only one: nothing in `exploit.rs` or `idevice`
/// ever looks at `ProductVersion`. It used to be 26.2 (GoldenNugget's
/// `is_supported_by_fork`); that history no longer describes this app's range.
///
/// The linkage is unconditional, so a device that never opens these pages pays
/// for the code and nothing else (the linker pulls only the objects whose
/// symbols are referenced, and this file references all of them).
enum Airlift {
    // MARK: - Availability

    /// The oldest iOS the escape is attempted on, as a version string.
    ///
    /// 17.0 is the floor the same-origin product ships at (2026-11-11).
    static let minimumVersion = "17.0"

    /// The inclusive comparison floor. Kept as its own constant because the
    /// rule is `>=` rather than `>`: 17.0 itself must pass.
    private static let referenceFloor = "17.0"

    /// Whether the exploit may be attempted, for a device reporting `deviceVersion`.
    ///
    /// Not a floor the library states — see the note above. What it buys is
    /// permission to try: a device below it is refused before a call that would
    /// only fail, and an unparsable or empty version is refused with it,
    /// because "unknown" must never be read as "new enough" — the same
    /// reasoning `DeviceIdentity` records for an empty version disabling the
    /// registry's bounds in the other direction.
    ///
    /// Within the supported range the attempt can still fail, and it fails
    /// loudly: the write reports why, and an injection that wrote nothing is an
    /// error rather than a quiet no-op.
    static func isSupported(deviceVersion: String, buildVersion: String = "") -> Bool {
        guard !AirliftAvailability.isHidden(deviceVersion: deviceVersion, buildVersion: buildVersion) else { return false }
        // `nil` from the comparison is an unorderable version string, which is
        // the same "unknown" case the empty one is refused as.
        guard let cmp = TweakVersion.compare(deviceVersion, referenceFloor) else { return false }
        return cmp >= 0
    }

    /// The reason to refuse, for the UI.
    static func unsupportedReason(deviceVersion: String, buildVersion: String = "") -> String {
        if deviceVersion.isEmpty { return "还没有读到设备系统版本，暂时判断不了这个通道能不能用。" }
        if AirliftAvailability.isHidden(deviceVersion: deviceVersion, buildVersion: buildVersion) {
            return "注销直刷在 iOS 27.2 测试版 3 起不可用；"
                + "iOS 27.2 只支持已验证的测试版 1 / 2 构建。"
        }
        return isSupported(deviceVersion: deviceVersion, buildVersion: buildVersion) ? ""
            : "注销直刷需要 iOS \(minimumVersion) 或更高版本——这台设备读到的是 "
            + (deviceVersion.isEmpty ? "没有版本号" : "iOS \(deviceVersion)") + "。"
    }

    /// Refuse unless the device is new enough, re-reading it first.
    ///
    /// Fresh read, not the polled value, for the reason `applyTweaks` re-reads at
    /// the start of a run rather than trusting what a page was drawn with: every
    /// call here writes into a container, and the polled copy is a UI convenience
    /// that is up to thirty seconds stale. Falls back to the polled value when
    /// lockdown does not answer, so a slow-but-alive tunnel still gets through.
    private static func requireSupported() async throws {
        // 2.0.0: the hot-load tweak-policy gate that used to run here is
        // gone with the tweak system — this check is now purely the
        // version window below.
        var identity = await DeviceIdentity.read()
        if identity.version.isEmpty {
            identity = await MainActor.run { DeviceIdentityMonitor.shared.current }
        }
        guard isSupported(deviceVersion: identity.version, buildVersion: identity.buildVersion) else {
            throw DriftError(unsupportedReason(deviceVersion: identity.version, buildVersion: identity.buildVersion))
        }
    }

    // MARK: - Logging

    /// Install the library's log sink, so its lines land in the run log.
    ///
    /// `al_log_init` returns 1 when a subscriber is already installed, which is
    /// not worth surfacing: it means the library is already logging somewhere, and
    /// the only sink we have is the one just installed.
    @discardableResult
    static func install() -> Bool {
        al_log_init(logTrampoline, nil) == 0
    }

    /// Whether this process can hand `airlift_ffi` a Grappa token.
    ///
    /// `airlift_ffi` resolves `ALGetGrappaToken` with `dlsym(RTLD_DEFAULT, …)`
    /// at write time, so a build that merely *defines* the function is not
    /// enough: the linker dead-strips any symbol nothing references, and the
    /// lookup then fails at runtime with
    /// `airlift: grappa: ALGetGrappaToken symbol not found` followed by an
    /// `ATC` `SyncFailed`. Calling it here is what pins the symbol into the
    /// export table, and running it at launch means a device that cannot produce
    /// a token says so in the log before a user presses Apply.
    @discardableResult
    static func installGrappaTokenProvider() -> Int32 {
        let status = GrappaToken.status()
        AppLog.write(status == 0
                     ? "airlift: Grappa token provider ready (\(GrappaToken.previewLength()) bytes)"
                     : "airlift: Grappa token provider unavailable (code \(status))")
        return status
    }

    /// The per-call sink, passed as `log_cb` with a `nil` context.
    ///
    /// The `ctx` slot exists in the FFI for callers that need to carry state into
    /// a C function pointer, which cannot capture. Nothing here does — the sink
    /// appends to `AppLog`'s singleton — so `nil` is passed rather than a
    /// fabricated global whose only purpose would be to be ignored.
    private static let logTrampoline: ALLogCallback = { _, msg in
        guard let msg else { return }
        AppLog.write(String(cString: msg))
    }

    /// Copy a heap string the FFI handed back, free it, and return the copy.
    ///
    /// Both `out_json` and `out_error` are malloc'd by the library and owned by
    /// the caller. The `String` is made *before* the free — reading freed memory
    /// is the bug this helper exists to make impossible to write twice.
    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { al_string_free(pointer) }
        return String(cString: pointer)
    }

    // MARK: - Exploit

    /// Write every file in `sourceDir` into `targetDir` on the device.
    static func writeDir(pairingPath: String,
                         sourceDir: String,
                         targetDir: String) async throws {
        try await requireSupported()
        try await offMainActor {
            var outError: UnsafeMutablePointer<CChar>?
            let rc = al_exploit_write_dir(pairingPath, sourceDir, targetDir,
                                          logTrampoline, nil, &outError)
            guard rc == 0 else {
                throw DriftError(take(outError) ?? "AirLift 目录写入返回了 \(rc)。")
            }
        }
    }

    /// Copy a whole local directory into `targetParentDir/destName`, keeping the
    /// internal tree — one AirTraffic operation rather than a file walk.
    static func injectFolder(pairingPath: String,
                             folderPath: String,
                             targetParentDir: String,
                             destName: String) async throws {
        try await requireSupported()
        try await offMainActor {
            var outError: UnsafeMutablePointer<CChar>?
            let rc = al_exploit_inject_folder(pairingPath, folderPath, targetParentDir, destName,
                                              logTrampoline, nil, &outError)
            guard rc == 0 else {
                throw DriftError(take(outError) ?? "AirLift 文件夹注入返回了 \(rc)。")
            }
        }
    }

    /// Copy one descriptor folder into `targetParentDir/destName` and write the
    /// reload-preferences file to both targets in the *same* AirTraffic sync —
    /// one tunnel, one Books snapshot/restore cycle. The transaction is faster
    /// than a folder injection followed by a separate preferences write, and it
    /// is the shape Walllive uses for a single-wallpaper install.
    static func flashTransaction(pairingPath: String,
                                 folderPath: String,
                                 targetParentDir: String,
                                 destName: String,
                                 preferenceFile: String,
                                 preferenceTargetA: String,
                                 preferenceTargetB: String) async throws {
        // No AirLift version gate here: the transaction is the older
        // AirTraffic/Books pipeline, and the direct route judges its own
        // range. The caller has already judged whether it is supported.
        try await offMainActor {
            var outError: UnsafeMutablePointer<CChar>?
            let rc = al_exploit_flash_transaction(
                pairingPath, folderPath, targetParentDir, destName,
                preferenceFile, preferenceTargetA, preferenceTargetB,
                logTrampoline, nil, &outError)
            guard rc == 0 else {
                throw DriftError(take(outError) ?? "AirLift 写入事务返回了 \(rc)。")
            }
        }
    }

    /// Resolve an app's Data Application Container by bundle id.
    ///
    /// This is the lookup Wallet and PosterBoard both need, and the reason it is
    /// not hardcoded anywhere: the UUID changes on every reinstall and on some
    /// OS updates, so a stored path is a path to nothing.
    static func appContainer(pairingPath: String, bundleID: String,
                             allowUnsupportedVersion: Bool = false) async throws -> String {
        if !allowUnsupportedVersion {
            try await requireSupported()
        }
        return try await offMainActor {
            var outContainer: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = al_find_app_container(pairingPath, bundleID, logTrampoline, nil,
                                           &outContainer, &outError)
            let container = take(outContainer)
            let message = take(outError)
            guard rc == 0, let container else {
                throw DriftError(message ?? "找不到 \(bundleID) 的容器（代码 \(rc)）。")
            }
            return container
        }
    }

    /// Respring, so an injected descriptor is live without a reboot.
    ///
    /// NeoSpring — a full-screen `WKWebView` running upstream's compositor
    /// payload, attached to our own key window, which restarts the userspace
    /// under us. See `NeoSpring` for why that is here instead of a command over
    /// the tunnel.
    ///
    /// No pairing record and no tunnel: by the time this is called the writes
    /// are already in the container, and the restart is entirely on this side.
    /// That is also why it works on any supported device rather than only
    /// through AirLift's connection.
    static func respring() async throws {
        let attached = await MainActor.run { NeoSpring.trigger() }
        guard attached else {
            throw DriftError("没有可用来注销的窗口。请把应用留在"
                + "foreground and run it again.")
        }
        // Give WebKit the moment it needs to load the payload. Returning
        // earlier would let the run report a respring that had not started yet.
        try? await Task.sleep(for: .milliseconds(800))
    }

    /// Reboot the device, over Diagnostics Relay.
    ///
    /// Not what a wallpaper change needs — `respring` is, and is much quicker.
    /// Kept because a failed injection can leave the store in a state only a full
    /// restart clears, and the user is the one who has to agree to that.
    ///
    /// This is Diagnostics Relay's `Restart`, and it reboots the *device*: the
    /// name is a trap when reading the FFI next to the respring beside it.
    static func reboot(pairingPath: String) async throws {
        try await requireSupported()
        try await offMainActor {
            var outError: UnsafeMutablePointer<CChar>?
            let rc = al_device_respring(pairingPath, logTrampoline, nil, &outError)
            guard rc == 0 else {
                throw DriftError(take(outError) ?? "重启返回了 \(rc)。")
            }
        }
    }

    // MARK: - Syslog

    /// Stream device syslog over the tunnel, and return the stop function.
    ///
    /// This is how an Apple Pay card is *identified*: bringing up Wallet makes
    /// Passbook log the card's identifier, and there is no other way to learn
    /// which card is in the reader. The FFI's own `al_syslog_stream_start` blocks
    /// until stopped, so it lives on its own thread and this returns immediately
    /// with the handle that stops it.
    static func streamSyslog(pairingPath: String,
                             onLine: @escaping (String) -> Void) async throws -> () -> Void {
        try await requireSupported()
        let token = UInt.random(in: UInt.min...UInt.max)
        // Registered before the thread starts, so the first line cannot arrive
        // before there is somewhere to put it.
        SyslogRegistry.shared.put(token, onLine)

        DispatchQueue.global(qos: .utility).async {
            var outError: UnsafeMutablePointer<CChar>?
            let rc = al_syslog_stream_start(pairingPath, { ctx, line in
                guard let ctx, let line else { return }
                SyslogRegistry.shared.handler(UInt(bitPattern: ctx))?(String(cString: line))
            }, UnsafeMutableRawPointer(bitPattern: token), &outError)
            if let message = take(outError) {
                AppLog.write("AirLift syslog stream ended (code \(rc)): \(message)")
            }
            SyslogRegistry.shared.remove(token)
        }

        return {
            SyslogRegistry.shared.remove(token)
            al_syslog_stream_stop()
        }
    }

    /// Handlers for `streamSyslog`, keyed by the token their callback carries.
    ///
    /// A lock rather than a `@MainActor` dictionary: the callback arrives on
    /// whatever thread the library's reader is on, while the registry is touched
    /// by the UI when a stream starts and stops.
    private final class SyslogRegistry: @unchecked Sendable {
        static let shared = SyslogRegistry()
        private let lock = NSLock()
        private var handlers: [UInt: (String) -> Void] = [:]

        func put(_ token: UInt, _ handler: @escaping (String) -> Void) {
            lock.lock(); defer { lock.unlock() }
            handlers[token] = handler
        }
        func remove(_ token: UInt) {
            lock.lock(); defer { lock.unlock() }
            handlers[token] = nil
        }
        func handler(_ token: UInt) -> ((String) -> Void)? {
            lock.lock(); defer { lock.unlock() }
            return handlers[token]
        }
    }

    // MARK: - Local archives

    /// Unpack a `.passthm` card-art archive locally — no device involved.
    ///
    /// A `.passthm` is what Passbook itself calls a card theme: a zip of scaled
    /// artwork for one card. Unpacking it on this side rather than on the device
    /// is what lets the Wallet page preview a card before anything is written.
    @discardableResult
    static func extractPassthm(archivePath: String, destDir: String) async throws -> String {
        try await offMainActor {
            let rc = al_passthm_extract(archivePath, destDir)
            guard rc == 0 else { throw DriftError("无法解包 \(archivePath)（代码 \(rc)）。") }
        }
        return destDir
    }

    /// Unpack a zip locally. Thin wrapper, kept so callers do not have to know
    /// which extractor a given extension maps to.
    @discardableResult
    static func extractZip(archivePath: String, destDir: String) async throws -> String {
        try await offMainActor {
            let rc = al_zip_extract_all(archivePath, destDir)
            guard rc == 0 else { throw DriftError("无法解包 \(archivePath)（代码 \(rc)）。") }
        }
        return destDir
    }

    // MARK: - Poster store enumeration (poster_store.rs, transplanted in stage 1)

    /// One descriptor in the device store, as `al_poster_store_list` reports
    /// it: the provider folder it lives under and its descriptor (folder) id.
    struct PosterStoreItem: Decodable {
        let `extension`: String
        let uuid: String
        let identifier: String?
        let packageName: String?
        let name: String?
    }

    private struct PosterStoreListReply: Decodable {
        let items: [PosterStoreItem]
    }

    private struct PosterStoreGenerationsReply: Decodable {
        let generations: [Int]
    }

    /// Read the generation directories present under the PosterBoard store root.
    /// A missing store root is represented as an empty generation list.
    static func posterStoreGenerations(pairingPath: String,
                                       containerPath: String) async throws -> [Int] {
        try await offMainActor {
            var outJSON: UnsafeMutablePointer<CChar>?
            var outStatus: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = al_poster_store_generations(pairingPath, containerPath,
                                                 logTrampoline, nil,
                                                 &outJSON, &outStatus, &outError)
            let json = take(outJSON)
            _ = take(outStatus)
            let message = take(outError)
            guard rc == 0 else {
                throw DriftError(message ?? "商店根目录枚举返回了 \(rc)。")
            }
            guard let json,
                  let reply = try? JSONDecoder().decode(PosterStoreGenerationsReply.self,
                                                        from: Data(json.utf8)) else {
                throw DriftError("商店根目录枚举的返回无法解析。")
            }
            return reply.generations
        }
    }

    /// Enumerate the descriptors actually present in the device's PosterBoard
    /// store — the read side of the chassis rule that store state is read,
    /// not guessed. Scoped by the Rust side to the CollectionsPoster
    /// providers; it goes over DVT directory listings on the pairing tunnel.
    static func posterStoreList(pairingPath: String,
                                containerPath: String,
                                structureVersion: Int) async throws -> [PosterStoreItem] {
        try await offMainActor {
            var outJSON: UnsafeMutablePointer<CChar>?
            var outStatus: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = al_poster_store_list(pairingPath, containerPath, Int64(structureVersion),
                                          logTrampoline, nil, &outJSON, &outStatus, &outError)
            let json = take(outJSON)
            _ = take(outStatus)
            let message = take(outError)
            guard rc == 0 else {
                throw DriftError(message ?? "商店枚举返回了 \(rc)。")
            }
            guard let json,
                  let reply = try? JSONDecoder().decode(PosterStoreListReply.self,
                                                        from: Data(json.utf8)) else {
                throw DriftError("商店枚举的返回无法解析。")
            }
            return reply.items
        }
    }

    /// Remove descriptors from the device store by id
    /// (`al_poster_store_delete`). The Rust side moves them out through an
    /// AirTraffic/Books sync into a quarantined copy under the container's
    /// Media directory and re-audits their absence on a fresh connection.
    /// Returns the per-target status JSON. No 2.0.0 surface calls this yet —
    /// it is the store-management primitive an enumeration-based reset will
    /// be built on.
    @discardableResult
    static func posterStoreDelete(pairingPath: String,
                                  containerPath: String,
                                  structureVersion: Int,
                                  descriptorIDs: [String]) async throws -> String {
        try await offMainActor {
            var outJSON: UnsafeMutablePointer<CChar>?
            var outStatus: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = al_poster_store_delete(pairingPath, containerPath, Int64(structureVersion),
                                            descriptorIDs.joined(separator: ","),
                                            logTrampoline, nil, &outJSON, &outStatus, &outError)
            let json = take(outJSON)
            _ = take(outStatus)
            let message = take(outError)
            guard rc == 0 else {
                throw DriftError(message ?? "商店删除返回了 \(rc)。")
            }
            return json ?? ""
        }
    }

    // MARK: - Plumbing

    /// Run a blocking FFI call off the main actor and rethrow what it threw.
    ///
    /// Every `al_*` call blocks on its own RSD tunnel — a handshake, a write, a
    /// response — so none of them may run on the main thread. One helper rather
    /// than a `DispatchQueue.async` plus a continuation per call, because the
    /// continuation is what made each of them look different when they are the
    /// same shape.
    private static func offMainActor<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}
