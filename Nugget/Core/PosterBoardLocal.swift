import Foundation
import Darwin
import Network

/// PosterBoard wallpapers written from inside the app, through `worse_query`.
///
/// ## Why a third route exists
///
/// AirLift writes the same descriptors, but only after opening an AirTraffic
/// tunnel to a paired device. That needs a pairing record, LocalDevVPN, an
/// unlocked phone and iOS 26.2+ (and it is refused from 27.2 beta 3 on). The
/// protected-backup route is currently suspended. `worse_query` gives this
/// process a sandbox extension for PosterBoard's own data container, so the
/// descriptors can be copied in directly: no pairing, no tunnel, no backup —
/// and the only thing left to do afterwards is a respring.
///
/// ## What it costs
///
/// The signing profile must grant a usable App Group
/// (`WorseQueryEscape.discoveredGroupIdentifier`, resolved at runtime from the
/// embedded provisioning profile); without one the route refuses itself and the
/// judgement falls back. It can add descriptors but not remove them, so a store
/// reset still needs the restore route. Everything it writes goes to the same
/// place AirLift writes to:
///
///     <PosterBoard container>/Library/Application Support/
///       PRBPosterExtensionDataStore/<structure version>/Extensions/
///       <provider>/descriptors/<random UUID>
///
/// ## How it takes effect
///
/// The write itself never needs a pairing record. What happens *after* the write
/// is decided by the device's state at that moment: when a saved RemotePairing
/// record, the LocalDevVPN interface and Wi-Fi are all present, the tunnel can
/// restart only the PosterBoard daemon (`PosterRefresh`) and the wallpaper
/// appears without a respring. When any of the three is missing, or the refresh
/// is not confirmed twice, the app stops at "written" and offers a manual
/// respring button — it never triggers a respring on its own.
///
/// ## Why it shares AirLift's discovery code
///
/// A pack is not a fixed layout — bare `descriptors/`, a store snapshot, a
/// root-level descriptor and video descriptors all occur. `PosterBoardAirlift`
/// already walks those shapes, counts them from the archive for the progress
/// bar, and randomizes the three identity fields on the way in. Doing it twice
/// would mean two opinions about what a pack contains; the only difference here
/// is that the copy is a local `FileManager` operation instead of an FFI one.
/// What a finished in-process write did about making the wallpaper visible.
///
/// The write succeeds whether or not anything afterwards can run, so this is
/// deliberately separate from the apply's success: a `.manualRespring` outcome is
/// still a successful write that the user has to make visible.
enum PosterBoardEffectKind: String, Sendable {
    /// PosterBoard was restarted over the tunnel; the wallpaper is visible now.
    case noRespring
    /// The wallpaper is written but not visible yet. The completion prompt
    /// carries a manual respring button.
    case manualRespring
}

struct PosterBoardEffect: Equatable, Sendable {
    let kind: PosterBoardEffectKind
    /// One line for the completion prompt and the history record.
    let headline: String
    /// Why, in the user's terms.
    let detail: String

    var needsManualRespring: Bool { kind == .manualRespring }

    /// The short text the apply history stores and the settings list shows.
    var historyLabel: String {
        switch kind {
        case .noRespring: return "免注销"
        case .manualRespring: return "写入后手动注销"
        }
    }
}

enum PosterBoardLocal {
    /// The bundle whose container holds the store.
    static let bundleID = "com.apple.PosterBoard"

    /// Where app data containers live.
    ///
    /// `/private/var` rather than `/var`: that is the canonical path
    /// containermanagerd and `fsgetpath` report, and the escape's link target
    /// has to be the path the kernel will resolve.
    private static let applicationsRoot = "/private/var/mobile/Containers/Data/Application"

    /// Cached container path.
    ///
    /// A cache, not a fact: the UUID changes on reinstall and on some updates.
    /// `openContainer` re-verifies it against the container's own identifier
    /// before trusting it, and every failed write clears it, so a stale path
    /// costs one extra scan rather than writing into the wrong container.
    private static let containerKey = "PosterBoardLocalContainer"

    static var cachedContainer: String {
        get { UserDefaults.standard.string(forKey: containerKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: containerKey) }
    }

    // MARK: - Apply

    /// Inject the selected packs, then decide how they take effect.
    ///
    /// - Parameters:
    ///   - selection: the page's selection. Packs are honoured; the video stage
    ///     and a store reset are refused by the engine before this runs.
    ///   - templates: PosterBoard templates, which ride the same descriptor
    ///     copy as the packs.
    ///   - deviceVersion: the system version the legacy-conversion gate should
    ///     use. The judgement supplies the app's own version, because this route
    ///     never reads the device over a tunnel.
    @discardableResult
    static func apply(
        selection: PosterBoardSelection,
        templates: [TemplateFile] = [],
        deviceVersion: String,
        log: @escaping @Sendable (String) -> Void,
        progress: @escaping (Double) -> Void
    ) async throws -> PosterBoardEffect {
        // Unpacking and copying are blocking file work and a pack can be large,
        // so they run off the caller (which is the main actor when the page's
        // apply is tapped). Progress is marshalled back to the main queue
        // because the engine publishes it as view state.
        let reported: (Double) -> Void = { value in
            DispatchQueue.main.async { progress(value) }
        }
        let injected = try await offMainActor {
            try inject(selection: selection, templates: templates,
                       deviceVersion: deviceVersion, log: log, progress: reported)
        }

        // The writes are the queue, so the bar is full before the effect step;
        // a bar that sits at 100% through a refresh reads as finished.
        progress(99)
        let effect = await determineEffect(log: log)
        progress(100)
        log("Injected \(injected) descriptor(s) locally. Effect: \(effect.headline)")
        return effect
    }

    /// Decide, from the state *after* the write, how the wallpaper takes effect.
    ///
    /// Three things have to be true for the tunnel refresh: a saved
    /// RemotePairing record, the LocalDevVPN interface, and Wi-Fi (the loopback
    /// tunnel runs over it; cellular alone cannot carry it). When they are, the
    /// refresh is attempted twice — the first attempt can lose a race with a
    /// device that is still writing, and the second is the retry the checklist
    /// asks for. If neither is confirmed the wallpaper is still written, so the
    /// outcome is a prompt with a manual respring button, never an automatic
    /// respring.
    private static func determineEffect(log: @escaping @Sendable (String) -> Void) async -> PosterBoardEffect {
        var missing: [String] = []
        let record = (try? String(contentsOf: AppPaths.pairingFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !PairingRecord.hasRemotePairingCredentials(record) {
            missing.append("配对文件（含 Remote Pairing 凭据）")
        }
        let tunnelUp = await MainActor.run { TunnelMonitor.shared.status != .down }
        if !tunnelUp { missing.append("LocalDevVPN") }
        if !(await wifiIsOn()) { missing.append("Wi-Fi") }

        guard missing.isEmpty else {
            let reason = missing.joined(separator: "、")
            log("PosterBoard written; no automatic refresh because \(reason) is missing")
            return PosterBoardEffect(
                kind: .manualRespring,
                headline: "壁纸已写入",
                detail: "当前缺少\(reason)，所以没有自动刷新。壁纸已经在商店里，点「手动注销」"
                    + "让 PosterBoard 读到它们。App 不会自动注销。")
        }

        log("Tunnel prerequisites complete — restarting only the PosterBoard daemon…")
        var refresh = await PosterRefresh.attempt(pairingPath: AppPaths.pairingFile.path)
        if !refresh.confirmed {
            log("PosterBoard refresh not confirmed (\(refresh.status.explanation)) — retrying once")
            refresh = await PosterRefresh.attempt(pairingPath: AppPaths.pairingFile.path)
        }
        if refresh.confirmed {
            log("✅ \(refresh.status.explanation) — 免注销生效。")
            return PosterBoardEffect(
                kind: .noRespring,
                headline: "刷入完成，免注销生效",
                detail: "只重启了 PosterBoard，壁纸已经可见，其他 App 不受影响。")
        }
        log("⚠️ PosterBoard refresh not confirmed twice (\(refresh.status.explanation)); "
            + "leaving the wallpaper written and offering a manual respring")
        return PosterBoardEffect(
            kind: .manualRespring,
            headline: "壁纸已写入（免注销未确认）",
            detail: "两次刷新都没有确认（\(refresh.status.explanation)）。壁纸已经在商店里，"
                + "点「手动注销」让 PosterBoard 读到它们。App 不会自动注销。")
    }

    /// Whether Wi-Fi is currently usable.
    ///
    /// `NWPathMonitor` reports its first path asynchronously after `start`, so
    /// this waits for a settled path (bounded) instead of reading an
    /// all-default snapshot. Uses a Wi-Fi-required monitor: a satisfied cellular
    /// path is not enough for the loopback tunnel.
    private static func wifiIsOn() async -> Bool {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.start(queue: DispatchQueue(label: "com.sociart.drift.wifi-probe"))
        defer { monitor.cancel() }
        for _ in 0..<10 {
            if monitor.currentPath.status == .satisfied { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// The synchronous half: stage each source, then copy its descriptors into
    /// PosterBoard's container. Returns how many were injected.
    private static func inject(
        selection: PosterBoardSelection,
        templates: [TemplateFile],
        deviceVersion: String,
        log: @escaping @Sendable (String) -> Void,
        progress: @escaping (Double) -> Void
    ) throws -> Int {
        struct Source {
            let name: String
            let url: URL
            let defaultExtension: String
            let extract: (URL) throws -> Void
        }
        var sources = selection.tendies.map { pack in
            Source(name: pack.name, url: pack.url,
                   defaultExtension: pack.posterType.extensionBundleID) { stage in
                try pack.extract(to: stage)
                if PosterBoard.shouldConvertLegacy(pack: pack, deviceVersion: deviceVersion, log: log) {
                    PosterBoard.convertLegacyPack(pack.name, at: stage, log: log)
                }
            }
        }
        sources += templates.map { template in
            Source(name: template.title, url: template.url,
                   defaultExtension: PosterBoardPosterType.collections.extensionBundleID) { stage in
                try template.extract(to: stage)
                PosterBoard.convertLegacyPack(template.title, at: stage, log: log)
            }
        }
        guard !sources.isEmpty else { throw GoldenNuggetError("没有可注入的 PosterBoard 包或模板。") }

        // The handle is held for the whole run. One query for the container
        // beats one per descriptor, and every copy below needs the extension
        // live; `defer` is what makes the release unconditional.
        let opened = try openContainer(log: log)
        defer { WorseQueryEscape.release(opened.handle) }
        let container = opened.path
        log("PosterBoard container (local): \(container)")

        let structureVersion = structureVersion(in: container)
        log("Store version directory: \(structureVersion)")

        // Counted from the archives, like the AirLift route, so the bar has a
        // denominator before the first pack is unpacked.
        let planned = sources.reduce(0) {
            $0 + PosterBoardAirlift.countDescriptors(inArchiveAt: $1.url)
        }
        var done = 0
        let overall = { (completed: Int) -> Double in
            guard planned > 0 else { return 0 }
            return min(100, Double(completed) / Double(planned) * 100)
        }
        progress(overall(done))

        var injected = 0
        for (index, source) in sources.enumerated() {
            log("[\(index + 1)/\(sources.count)] \(source.name)")
            // A `do` block scopes the `defer`: each pack's staging directory is
            // removed when that pack is done, not when the whole run is.
            do {
                let stage = PosterBoard.workDirectory
                    .appendingPathComponent("local-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: stage) }

                try source.extract(stage)
                let descriptors = PosterBoardAirlift.findDescriptors(
                    in: stage, defaultExtension: source.defaultExtension, log: log)
                guard !descriptors.isEmpty else {
                    throw GoldenNuggetError("在 \(source.name) 中没有找到壁纸描述文件。"
                        + "对于交付容器文件的模板，请改用「恢复式」。")
                }
                log("  \(descriptors.count) descriptor(s)")

                for (position, descriptor) in descriptors.enumerated() {
                    let target = UUID().uuidString.uppercased()
                    let numericID = Int.random(in: PosterBoard.identifierRange)
                    // Same reason as the AirLift route: a descriptor that keeps
                    // the pack's own identifier collides with every other copy
                    // of that pack already on the device. The directory name and
                    // the plist values have to be rewritten together, or
                    // PosterBoard indexes a wallpaper it cannot find.
                    let currentExtension = descriptor.extensionID == PosterBoardPosterType.collections.extensionBundleID
                        ? "com.apple.Posters.CollectionsPosterApp" : descriptor.extensionID
                    let parent = container + PosterBoard.storeRoot + "/\(structureVersion)/Extensions/"
                        + currentExtension + "/descriptors"
                    do {
                        try PosterBoardAirlift.randomizeIdentifiers(
                            in: descriptor.url, numericID: numericID,
                            extensionID: descriptor.extensionID)
                        try copy(descriptor.url, into: parent, named: target)
                        injected += 1
                        done += 1
                        log("  ✅ \(position + 1)/\(descriptors.count) → \(currentExtension)")
                        progress(overall(done))
                    } catch {
                        // Most likely a container UUID that changed under the
                        // run. Drop the cache so the next attempt rescans; the
                        // failure itself is reported and the rest of the queue
                        // still runs, exactly like the tunnel route.
                        cachedContainer = ""
                        done += 1
                        progress(overall(done))
                        log("  ❌ \(descriptor.extensionID): \(error.localizedDescription)")
                    }
                }
            }
        }

        guard injected > 0 else {
            throw GoldenNuggetError("没有写入任何 PosterBoard 描述文件。请确认签名授予了可用的 App Group，"
                + "并且设备系统在本机直刷的支持范围内；缓存已过期的话，下一次会重新查找容器。")
        }
        return injected
    }

    // MARK: - Container

    /// Consume an extension for PosterBoard's container and return both.
    ///
    /// The cached path is verified against the container's own
    /// `com.apple.containermanager.identifier` xattr before it is trusted — a
    /// stale cache that now belongs to another app must not receive wallpaper
    /// descriptors. A miss scans the application container directory once.
    private static func openContainer(log: @escaping @Sendable (String) -> Void) throws -> (path: String, handle: Int64) {
        let cached = cachedContainer
        if !cached.isEmpty {
            // `createDirectory: true` skips worse_query's `lstat` of the target.
            // The target is another app's container, which this process may not
            // be allowed to stat yet — that permission is the thing the escape
            // is about to obtain. The xattr read below is the real check.
            if let handle = try? WorseQueryEscape.consume(path: cached, createDirectory: true) {
                if containerIdentifier(atPath: cached) == bundleID {
                    log("PosterBoard container: cached path verified")
                    return (cached, handle)
                }
                WorseQueryEscape.release(handle)
                log("cached PosterBoard container no longer belongs to PosterBoard — rescanning")
                cachedContainer = ""
            } else {
                cachedContainer = ""
            }
        }

        // One extension on the parent is enough to list the containers and read
        // each child's identifier xattr; it is released before the container's
        // own extension is taken. `createDirectory: true` applies here too: the
        // Application directory exists, but this process cannot stat it from
        // inside the sandbox.
        let found: String? = try WorseQueryEscape.withAccess(to: applicationsRoot, createDirectory: true) {
            let names = (try? FileManager.default.contentsOfDirectory(
                atPath: applicationsRoot).sorted()) ?? []
            let listed = names.map { applicationsRoot + "/" + $0 }
            if let match = firstPosterBoardContainer(among: listed) { return match }

            // The escape's own fallback for a directory that cannot be listed
            // even with the parent extension: brute-force the inode numbers and
            // try each path it returns.
            log("application container listing found no PosterBoard — falling back to pathleak")
            return firstPosterBoardContainer(
                among: WorseQueryEscape.leakedChildren(of: applicationsRoot))
        }
        guard let path = found else {
            throw GoldenNuggetError("找不到 PosterBoard 的容器。这个系统可能还没有壁纸商店的数据目录；"
                + "先添加一张系统壁纸，或者改用 AirLift。")
        }
        let handle = try WorseQueryEscape.consume(path: path, createDirectory: true)
        cachedContainer = path
        log("PosterBoard container resolved by scanning \(applicationsRoot)")
        return (path, handle)
    }

    /// The first candidate whose container identifier is PosterBoard's.
    private static func firstPosterBoardContainer(among candidates: [String]) -> String? {
        for candidate in candidates {
            guard isDirectory(candidate) else { continue }
            if containerIdentifier(atPath: candidate) == bundleID { return candidate }
        }
        return nil
    }

    /// The container's bundle identifier, from the xattr containermanagerd
    /// writes into every data container.
    private static func containerIdentifier(atPath path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 512)
        let length = buffer.withUnsafeMutableBytes { raw -> Int in
            getxattr(path, "com.apple.containermanager.identifier",
                     raw.baseAddress, raw.count - 1, 0, 0)
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The store's structure version, read from the live directory.
    ///
    /// Unlike the AirLift route, this one can see the directory, so it does not
    /// have to guess 61 and hope: the numeric folder with the highest number is
    /// the one PosterBoard is using. A container whose store has never been
    /// created falls back to the same constant the backup compiler uses.
    private static func structureVersion(in container: String) -> Int {
        let versions = (try? FileManager.default.contentsOfDirectory(
            atPath: container + PosterBoard.storeRoot))?
            .compactMap { Int($0) }
            .filter { $0 > 0 } ?? []
        return versions.max() ?? PosterBoard.fallbackStructureVersion
    }

    // MARK: - Files

    /// Copy one staged descriptor folder to its destination.
    ///
    /// Destination parent directories are created if PosterBoard has not made
    /// them yet (a fresh store, or the first descriptor for a provider).
    private static func copy(_ folder: URL, into parent: String, named name: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let destination = parent + "/" + name
        if manager.fileExists(atPath: destination) {
            try manager.removeItem(atPath: destination)
        }
        try manager.copyItem(at: folder, to: URL(fileURLWithPath: destination))
    }

    private static func isDirectory(_ path: String) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &flag) && flag.boolValue
    }

    // MARK: - Threading

    /// Run blocking file work off the caller, the same shape `Airlift` uses for
    /// its FFI calls: a continuation over a global queue, rethrowing what the
    /// body threw.
    private static func offMainActor<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
