import Foundation
import Darwin

/// PosterBoard wallpapers written from inside the app, through `worse_query`.
///
/// ## Why a separate channel exists
///
/// The two tunnel channels need a pairing record, LocalDevVPN, an unlocked
/// phone and a system in their range. `worse_query` gives this process a
/// sandbox extension for PosterBoard's own data container, so descriptors can
/// be copied in directly: no pairing, no tunnel, no backup. This channel owns
/// its whole flow — container discovery, layout scan, transactional write,
/// identifier rewrite and the receipt — and never calls the tunnel channels'
/// write or effect code.
///
/// ## How the write lands
///
/// Ported from the 3106 on-device installer's approach:
///
///  * find PosterBoard's data container (runtime App Group discovery, the
///    same rule 1.3.0 introduced);
///  * scan the store's **real** numeric generation directories and prefer the
///    one that already contains every provider this pack needs, with the
///    newest generation as the fallback;
///  * take the destination from the descriptor's own self-reported
///    `extensionBundleIdentifier` — there is no remap table;
///  * stage the folder beside its destination, verify file count and byte
///    count, fsync, then atomically rename it into place;
///  * rewrite the numeric identifier in its three places (the identifier
///    sidecar, `wallpaperRepresentingIdentifier` in the contents userInfo,
///    and `Wallpaper.plist`). Mercury keeps its own folder name and its
///    identifiers, as 3106 measured.
///
/// It deliberately does **not** write preferences, `PendingDescriptorUpdates`
/// or sqlite, exactly like the reference: the bet is "real directory +
/// self-consistent identifiers → the system ingests it".
///
/// ## How it takes effect
///
/// Nothing automatic. After the write this channel tells the user to open the
/// app switcher and swipe PosterBoard closed; when the system relaunches
/// PosterBoard it re-reads the store and the wallpaper appears. It never
/// borrows the tunnel to restart PosterBoard and never resprings.
enum PosterBoardEffectKind: String, Sendable {
    /// PosterBoard was restarted over the tunnel; the wallpaper is visible now.
    case noRespring
    /// The wallpaper is written but not visible yet. The completion prompt
    /// carries a manual respring button.
    case manualRespring
    /// The local channel wrote the wallpaper; the user closes PosterBoard from
    /// the app switcher to make the system re-read the store.
    case closePosterBoard
    /// The write was followed by a respring (注销直刷).
    case respring
}

struct PosterBoardEffect: Equatable, Sendable {
    let kind: PosterBoardEffectKind
    /// One line for the completion prompt and the history record.
    let headline: String
    /// Why, in the user's terms.
    let detail: String

    /// Whether the completion prompt should offer the manual respring button.
    var needsManualRespring: Bool { kind == .manualRespring }

    /// The short text the apply history stores and the settings list shows.
    var historyLabel: String {
        switch kind {
        case .noRespring: return "免注销"
        case .manualRespring: return "写入后手动注销"
        case .closePosterBoard: return "写入后关闭 PosterBoard"
        case .respring: return "注销"
        }
    }
}

/// What one finished local write produced: the store read-back and the effect
/// the user has to perform.
struct PosterBoardLocalOutcome {
    let verification: PosterStoreVerification
    let effect: PosterBoardEffect
}

enum PosterBoardLocal {
    /// The bundle whose container holds the store.
    static let bundleID = "com.apple.PosterBoard"

    /// Mercury descriptors keep their own folder name and identifiers.
    static let mercuryExtensionID = "com.apple.MercuryPoster"

    /// Where app data containers live.
    ///
    /// `/private/var` rather than `/var`: that is the canonical path
    /// containermanagerd and `fsgetpath` report, and the escape's link target
    /// has to be the path the kernel will resolve.
    private static let applicationsRoot = "/private/var/mobile/Containers/Data/Application"

    /// The same root the normal path enumerates, exposed only to the
    /// probe build's timing page.
    static var pathleakProbeDirectory: String { applicationsRoot }

    /// Cached container path. A cache, not a fact: re-verified against the
    /// container's own identifier before it is trusted, and cleared on failure.
    private static let containerKey = "PosterBoardLocalContainer"

    static var cachedContainer: String {
        get { UserDefaults.standard.string(forKey: containerKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: containerKey) }
    }

    // MARK: - Apply

    /// Inject the selected packs, then hand the user the activation step.
    @discardableResult
    static func apply(
        selection: PosterBoardSelection,
        templates: [TemplateFile] = [],
        deviceVersion: String,
        log: @escaping @Sendable (String) -> Void,
        progress: @escaping (Double) -> Void
    ) async throws -> PosterBoardLocalOutcome {
        let reported: (Double) -> Void = { value in
            DispatchQueue.main.async { progress(value) }
        }
        let write = try await offMainActor {
            try inject(selection: selection, templates: templates,
                       deviceVersion: deviceVersion, log: log, progress: reported)
        }
        progress(99)
        let verification = verify(write, log: log)
        progress(100)
        let effect = PosterBoardEffect(
            kind: .closePosterBoard,
            headline: "刷入完成，壁纸已写入",
            detail: "打开应用切换器，向上轻扫关闭 PosterBoard——系统重新拉起它时会重读商店，壁纸就生效了。")
        log("Injected \(write.placed.count) descriptor(s) locally. Effect: \(effect.headline)")
        return PosterBoardLocalOutcome(verification: verification, effect: effect)
    }

    /// Delete one descriptor this channel wrote, then read the store back to
    /// confirm it is gone. Driven by the receipt list in Settings.
    static func delete(receipt: PosterBoardLocalReceipt,
                       log: @escaping @Sendable (String) -> Void) async throws {
        try await offMainActor {
            let opened = try openContainer(log: log)
            defer { WorseQueryEscape.release(opened.handle) }
            let container = opened.path
            guard receipt.path.hasPrefix(container + "/"),
                  receipt.path.contains(PosterBoard.storeDirectoryName) else {
                throw DriftError("回执路径不在 PosterBoard 的商店目录里，拒绝删除。")
            }
            let manager = FileManager.default
            guard manager.fileExists(atPath: receipt.path) else {
                PosterBoardLocalReceipts.forget(id: receipt.id)
                log("回执 \(receipt.id)：目录已经不在商店里，记录已清理。")
                return
            }
            log("按回执删除：\(receipt.extensionID)/\(receipt.folderName)（代际 \(receipt.generation)）")
            try manager.removeItem(atPath: receipt.path)
            fsyncDirectory((receipt.path as NSString).deletingLastPathComponent)
            if manager.fileExists(atPath: receipt.path) {
                throw DriftError("删除后仍然能看到这个目录，没有确认删除。")
            }
            PosterBoardLocalReceipts.forget(id: receipt.id)
            log("删除后核验：该描述符已不在商店里。")
        }
    }

    /// Which of these receipts still have their descriptor directory in the
    /// store. Opens the container once; throws when the local store cannot be
    /// read, so the caller can say "未核对" instead of guessing.
    static func existingReceiptIDs(_ receipts: [PosterBoardLocalReceipt],
                                   log: @escaping @Sendable (String) -> Void) async throws -> Set<String> {
        try await offMainActor {
            let opened = try openContainer(log: log)
            defer { WorseQueryEscape.release(opened.handle) }
            let manager = FileManager.default
            let found = receipts.filter { manager.fileExists(atPath: $0.path) }
            log("本机对账：\(found.count)/\(receipts.count) 条回执的描述符仍在商店目录里。")
            return Set(found.map(\.id))
        }
    }

    /// Enumerate the descriptors currently in the local store, scoped to the
    /// managed providers. Returns the container path plus one row per folder.
    static func enumerateLocalStore(
        log: @escaping @Sendable (String) -> Void
    ) async throws -> (container: String,
                      items: [(provider: String, uuid: String, name: String,
                               packageName: String, generation: Int, path: String)]) {
        try await offMainActor {
            let opened = try openContainer(log: log)
            defer { WorseQueryEscape.release(opened.handle) }
            let container = opened.path
            let root = container + PosterBoard.storeRoot
            let manager = FileManager.default
            var items: [(String, String, String, String, Int, String)] = []
            for generation in generationDirectories(in: root) {
                let extRoot = root + "/\(generation)/Extensions"
                guard let providers = try? manager.contentsOfDirectory(atPath: extRoot) else { continue }
                for provider in providers where PosterBoard.managedProviders.contains(provider) {
                    let descDir = extRoot + "/\(provider)/descriptors"
                    guard let uuids = try? manager.contentsOfDirectory(atPath: descDir) else { continue }
                    for uuid in uuids {
                        let full = descDir + "/\(uuid)"
                        var isDir: ObjCBool = false
                        guard manager.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
                        var packageName = ""
                        let versionsDir = full + "/versions"
                        if let versions = try? manager.contentsOfDirectory(atPath: versionsDir) {
                            for version in versions {
                                let contentsDir = versionsDir + "/\(version)/contents"
                                if let contents = try? manager.contentsOfDirectory(atPath: contentsDir),
                                   let pkg = contents.first(where: { $0.hasSuffix(".wallpaper") }) {
                                    packageName = String(pkg.dropLast(".wallpaper".count))
                                    break
                                }
                            }
                        }
                        let name = packageName.isEmpty ? String(uuid.prefix(8)) : packageName
                        items.append((provider, uuid, name, packageName, generation, full))
                    }
                }
            }
            log("本机商店扫描：\(items.count) 个描述符。")
            return (container, items)
        }
    }

    /// Delete one descriptor folder the local channel can reach, with the
    /// same path guard as the receipt-based delete.
    static func deleteManagedDescriptor(provider: String,
                                        uuid: String,
                                        generation: Int,
                                        log: @escaping @Sendable (String) -> Void) async throws {
        try await offMainActor {
            let opened = try openContainer(log: log)
            defer { WorseQueryEscape.release(opened.handle) }
            let container = opened.path
            let root = container + PosterBoard.storeRoot
            let path = root + "/\(generation)/Extensions/\(provider)/descriptors/\(uuid)"
            guard path.hasPrefix(container + "/"),
                  path.contains(PosterBoard.storeDirectoryName) else {
                throw DriftError("路径不在 PosterBoard 的商店目录里，拒绝删除。")
            }
            let manager = FileManager.default
            guard manager.fileExists(atPath: path) else {
                log("描述符已经不在商店里。")
                return
            }
            try manager.removeItem(atPath: path)
            fsyncDirectory((path as NSString).deletingLastPathComponent)
            if manager.fileExists(atPath: path) {
                throw DriftError("删除后仍然能看到这个目录，没有确认删除。")
            }
            log("本机删除后核验：目录已不在商店。")
        }
    }
    // MARK: - Write

    /// What one local write produced, for the read-back and the receipts.
    struct LocalWrite {
        let container: String
        let storeVersion: Int
        let placed: [Placed]
        let providers: Set<String>
    }

    struct Placed {
        let parent: String
        let folderName: String
        let extensionID: String
        let numericID: Int
        let pack: String
        var path: String { parent + "/" + folderName }
        var key: String { "\(extensionID)/\(folderName)" }
    }

    private static func inject(
        selection: PosterBoardSelection,
        templates: [TemplateFile],
        deviceVersion: String,
        log: @escaping @Sendable (String) -> Void,
        progress: @escaping (Double) -> Void
    ) throws -> LocalWrite {
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
        guard !sources.isEmpty else { throw DriftError("没有可注入的 PosterBoard 包或模板。") }

        // One extension for the whole run: every copy below needs it live.
        let opened = try openContainer(log: log)
        defer { WorseQueryEscape.release(opened.handle) }
        let container = opened.path
        log("PosterBoard container (local): \(container)")

        let root = container + PosterBoard.storeRoot
        let generations = generationDirectories(in: root)
        log("商店代际目录：\(generations.isEmpty ? "(无，按 \(PosterBoard.fallbackStructureVersion) 新建)" : generations.map(String.init).joined(separator: "、"))")

        let planned = sources.reduce(0) {
            $0 + PosterBoardAirlift.countDescriptors(inArchiveAt: $1.url)
        }
        var done = 0
        let overall = { (completed: Int) -> Double in
            guard planned > 0 else { return 0 }
            return min(100, Double(completed) / Double(planned) * 100)
        }
        progress(overall(done))

        var placed: [Placed] = []
        var storeVersion = generations.first ?? PosterBoard.fallbackStructureVersion

        for (index, source) in sources.enumerated() {
            log("[\(index + 1)/\(sources.count)] \(source.name)")
            do {
                let stage = PosterBoard.workDirectory
                    .appendingPathComponent("local-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: stage) }

                try source.extract(stage)
                let descriptors = PosterBoardAirlift.findDescriptors(
                    in: stage, defaultExtension: source.defaultExtension, log: log)
                guard !descriptors.isEmpty else {
                    throw DriftError("在 \(source.name) 中没有找到壁纸描述文件。"
                        + "对于交付容器文件的模板，需要走「恢复刷」。"
                        + DriftRestoreGate.unavailableSuffix)
                }
                log("  \(descriptors.count) descriptor(s)")

                // Prefer the generation that already holds every provider this
                // pack needs; the newest one is the fallback.
                let required = Set(descriptors.map(\.extensionID))
                let generation = chooseGeneration(generations, required: required, root: root)
                storeVersion = generation
                log("  写入代际：\(generation)")

                for (position, descriptor) in descriptors.enumerated() {
                    let numericID = Int.random(in: PosterBoard.identifierRange)
                    let parent = root + "/\(generation)/Extensions/\(descriptor.extensionID)/descriptors"
                    let folderName = targetFolderName(for: descriptor, in: parent)
                    do {
                        try PosterBoardAirlift.randomizeIdentifiers(
                            in: descriptor.url, numericID: numericID,
                            extensionID: descriptor.extensionID)
                        try install(folder: descriptor.url, parent: parent,
                                    name: folderName, log: log)
                        let entry = Placed(parent: parent, folderName: folderName,
                                           extensionID: descriptor.extensionID,
                                           numericID: numericID, pack: source.name)
                        placed.append(entry)
                        PosterBoardLocalReceipts.remember(entry)
                        done += 1
                        log("  ✅ \(position + 1)/\(descriptors.count) → \(descriptor.extensionID)")
                        progress(overall(done))
                    } catch {
                        // Most likely a container UUID that changed under the
                        // run. Drop the cache so the next attempt rescans; the
                        // failure is reported and the rest of the queue runs.
                        cachedContainer = ""
                        done += 1
                        progress(overall(done))
                        log("  ❌ \(descriptor.extensionID): \(error.localizedDescription)")
                    }
                }
            }
        }

        guard !placed.isEmpty else {
            throw DriftError("没有写入任何 PosterBoard 描述文件。请确认签名授予了可用的 App Group，"
                + "并且设备系统在本机直刷的支持范围内；缓存已过期的话，下一次会重新查找容器。")
        }
        let providers = Set(placed.map(\.extensionID))
        return LocalWrite(container: container, storeVersion: storeVersion,
                          placed: placed, providers: providers)
    }

    /// The store read-back for the local channel: the exact directories this
    /// run renamed into place, checked on disk afterwards.
    private static func verify(_ write: LocalWrite,
                               log: @escaping @Sendable (String) -> Void) -> PosterStoreVerification {
        let manager = FileManager.default
        let expected = Set(write.placed.map(\.key))
        var confirmed: Set<String> = []
        for entry in write.placed where manager.fileExists(atPath: entry.path) {
            confirmed.insert(entry.key)
        }
        log("写后核验（本机枚举）：在册 \(confirmed.count)/\(expected.count)。")
        for missing in expected.subtracting(confirmed).sorted() {
            log("写后核验：\(missing) 不在商店目录里——文件写了，但目录没有留下它。")
        }
        return PosterStoreVerification(
            structureVersion: write.storeVersion,
            structureVersionSource: "结构版本 \(write.storeVersion)：本机通道直接读取商店的实际代际目录",
            providersSeen: write.providers,
            expected: expected, confirmed: confirmed, enumeratedAfter: true)
    }

    // MARK: - Layout

    /// The store's real numeric generation directories, newest first.
    private static func generationDirectories(in root: String) -> [Int] {
        (try? FileManager.default.contentsOfDirectory(atPath: root))?
            .compactMap { Int($0) }
            .filter { $0 > 0 }
            .sorted(by: >) ?? []
    }

    /// The generation a pack should land in: the newest one that already holds
    /// every provider the pack needs, else the newest at all, else a new
    /// `fallbackStructureVersion` directory.
    private static func chooseGeneration(_ generations: [Int],
                                         required: Set<String>,
                                         root: String) -> Int {
        let manager = FileManager.default
        for generation in generations {
            let holdsAll = required.allSatisfy {
                manager.fileExists(atPath: root + "/\(generation)/Extensions/\($0)")
            }
            if holdsAll { return generation }
        }
        return generations.first ?? PosterBoard.fallbackStructureVersion
    }

    /// Mercury keeps the folder name it shipped with; everything else gets a
    /// fresh uppercase UUID, avoiding a collision with an existing folder.
    private static func targetFolderName(for descriptor: PosterBoardAirlift.Descriptor,
                                         in parent: String) -> String {
        if descriptor.extensionID == mercuryExtensionID {
            return descriptor.url.lastPathComponent
        }
        let manager = FileManager.default
        var name = UUID().uuidString.uppercased()
        while manager.fileExists(atPath: parent + "/" + name) {
            name = UUID().uuidString.uppercased()
        }
        return name
    }

    // MARK: - Files

    /// Stage one descriptor folder beside its destination, verify it, fsync it
    /// and atomically rename it into place.
    private static func install(folder: URL, parent: String, name: String,
                                log: @escaping @Sendable (String) -> Void) throws {
        let manager = FileManager.default
        try manager.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let staging = parent + "/.drift-staging-\(UUID().uuidString)"
        try? manager.removeItem(atPath: staging)
        try manager.copyItem(at: folder, to: URL(fileURLWithPath: staging))
        defer { try? manager.removeItem(atPath: staging) }

        let staged = try treeStats(staging)
        let original = try treeStats(folder.path)
        guard staged.files == original.files, staged.bytes == original.bytes else {
            throw DriftError("暂存校验不通过：文件数/字节数与源不一致，已放弃写入。")
        }
        try fsyncTree(staging)

        let destination = parent + "/" + name
        if manager.fileExists(atPath: destination) {
            try manager.removeItem(atPath: destination)
        }
        let renamed = staging.withCString { source in
            destination.withCString { target in rename(source, target) }
        }
        guard renamed == 0 else {
            throw DriftError("原子改名失败：\(String(cString: strerror(errno)))")
        }
        fsyncDirectory(parent)
        log("  落点：\(name)（\(staged.files) 个文件 / \(staged.bytes) 字节，原子改名 + fsync）")
    }

    /// File count and byte count of a file or directory tree.
    private static func treeStats(_ path: String) throws -> (files: Int, bytes: Int) {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw DriftError("找不到待写入的描述文件：\(path)")
        }
        if !isDirectory.boolValue {
            let size = (try manager.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            return (1, size)
        }
        var files = 0
        var bytes = 0
        let walker = manager.enumerator(atPath: path)
        while let relative = walker?.nextObject() as? String {
            let full = path + "/" + relative
            var childIsDirectory: ObjCBool = false
            guard manager.fileExists(atPath: full, isDirectory: &childIsDirectory),
                  !childIsDirectory.boolValue else { continue }
            files += 1
            bytes += ((try? manager.attributesOfItem(atPath: full))?[.size] as? Int) ?? 0
        }
        return (files, bytes)
    }

    private static func fsyncTree(_ path: String) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
        if !isDirectory.boolValue {
            fsyncFile(path)
            return
        }
        let walker = manager.enumerator(atPath: path)
        while let relative = walker?.nextObject() as? String {
            let full = path + "/" + relative
            var childIsDirectory: ObjCBool = false
            if manager.fileExists(atPath: full, isDirectory: &childIsDirectory), !childIsDirectory.boolValue {
                fsyncFile(full)
            }
        }
        fsyncDirectory(path)
    }

    private static func fsyncFile(_ path: String) {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return }
        fsync(descriptor)
        close(descriptor)
    }

    /// fsync a directory so the rename itself is durable. Best-effort: some
    /// filesystems reject `fsync` on a directory descriptor.
    private static func fsyncDirectory(_ path: String) {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return }
        fsync(descriptor)
        close(descriptor)
    }

    // MARK: - Container

    /// How many candidate probes may be in flight at once. The probes are
    /// independent (one containermanagerd query + one kernel grant each), but
    /// concurrent grants have no prior evidence on these devices; 6 is the
    /// conservative middle of the 4–8 range and one constant so a device that
    /// refuses them can fall back by changing only this number.
    private static let probeConcurrency = 6

    private static func millis(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    /// Consume an extension for PosterBoard's container and return both.
    ///
    /// Order is chosen for the common cold-start case: a cached path, then the
    /// exact paths already known from the tunnel or old receipts, then a
    /// pathleak scan, and only then the root extension (an optional
    /// accelerator, never a gate). Locating must not depend on an extension for
    /// the applications root: on a real 27.2 device the kernel refuses it with
    /// -6, and the old order let that refusal kill the run before pathleak was
    /// reached (feedback #77–81).
    private static func openContainer(log: @escaping @Sendable (String) -> Void) throws -> (path: String, handle: Int64) {
        log("本机通道 App Group：\(WorseQueryEscape.discoveredGroupIdentifier ?? "没有可用的组")")
        let locateStart = DispatchTime.now()
        log("正在定位壁纸商店，第一次会慢一些")

        // 0. The cache is a precise address and the identity check is the
        // authority. A consume failure is often transient, so the cache is
        // kept; it is cleared only when consume succeeds and the content is
        // not PosterBoard.
        let cached = cachedContainer
        if !cached.isEmpty {
            log("consume 容器缓存：\(cached)（createDirectory: false，探测）")
            do {
                let handle = try WorseQueryEscape.consume(path: cached, createDirectory: false)
                if isPosterBoardContainer(atPath: cached) {
                    log(String(format: "PosterBoard container: cached path verified（总定位 %.0f ms）",
                               millis(since: locateStart)))
                    return (cached, handle)
                }
                WorseQueryEscape.release(handle)
                log("缓存 consume 成功但内容核对不是 PosterBoard——清掉缓存换路")
                cachedContainer = ""
            } catch {
                log("consume 缓存失败：\(cached) → \(error.localizedDescription)；保留缓存，下次仍先试它（内容核对兜底）")
            }
        }

        // 1. Exact paths already known: the tunnel's cached container and the
        // containers in old receipts. One or two probes instead of a scan.
        var known: [String] = []
        let tunnel = PosterBoardAirlift.cachedContainer
        if !tunnel.isEmpty {
            known.append(tunnel.hasSuffix("/") ? String(tunnel.dropLast()) : tunnel)
        }
        for receipt in PosterBoardLocalReceipts.load() {
            guard let container = PosterBoardManagement.containerPath(from: receipt.parent) else { continue }
            let trimmed = container.hasSuffix("/") ? String(container.dropLast()) : container
            if !known.contains(trimmed) { known.append(trimmed) }
        }
        if !known.isEmpty {
            log("已知容器路径：\(known.count) 个（隧道缓存 / 旧回执）")
            if let path = tryConsumePosterBoard(among: known, label: "已知路径", log: log) {
                let handle = try WorseQueryEscape.consume(path: path, createDirectory: true)
                cachedContainer = path
                log(String(format: "PosterBoard container resolved from a known path: %@（handle %lld，总定位 %.0f ms）",
                           path, handle, millis(since: locateStart)))
                return (path, handle)
            }
            log("已知容器路径核对失败：商店目录不存在或不是目录（已知路径本应正确，此行诊断价值最高）")
        }

        // 2. pathleak: walks inodes and names the children of the applications
        // root without asking for an extension on the root.
        let leakStart = DispatchTime.now()
        let leaked = WorseQueryEscape.leakedChildren(of: applicationsRoot)
        log(String(format: "pathleak：在 %@ 下枚举到 %d 个路径（枚举耗时 %.0f ms）",
                   applicationsRoot, leaked.count, millis(since: leakStart)))
        if let path = tryConsumePosterBoard(among: leaked, label: "pathleak", log: log) {
            let handle = try WorseQueryEscape.consume(path: path, createDirectory: true)
            cachedContainer = path
            log(String(format: "PosterBoard container resolved by pathleak: %@（handle %lld，总定位 %.0f ms）",
                       path, handle, millis(since: locateStart)))
            return (path, handle)
        }

        // 3. The root extension is an optional accelerator, never a gate.
        // Getting -6 here is expected on the systems this fix targets; the
        // pathleak route above is the one that has to work.
        var rootFailure = ""
        do {
            let listed: [String] = try WorseQueryEscape.withAccess(
                to: applicationsRoot, createDirectory: true) {
                let names = (try? FileManager.default.contentsOfDirectory(
                    atPath: applicationsRoot).sorted()) ?? []
                return names.map { applicationsRoot + "/" + $0 }
            }
            log("根目录扩展可用，\(listed.count) 个应用容器路径")
            if let path = firstPosterBoardContainer(among: listed) {
                let handle = try WorseQueryEscape.consume(path: path, createDirectory: true)
                cachedContainer = path
                log(String(format: "PosterBoard container resolved by root listing: %@（handle %lld，总定位 %.0f ms）",
                           path, handle, millis(since: locateStart)))
                return (path, handle)
            }
        } catch {
            rootFailure = error.localizedDescription
            log("根目录扩展不可用（\(rootFailure)）——pathleak 结果仍可继续使用")
        }

        log(String(format: "容器定位失败：总耗时 %.0f ms", millis(since: locateStart)))
        throw DriftError("找不到 PosterBoard 的容器：pathleak 没有枚举到可用的应用容器"
            + (rootFailure.isEmpty ? "。" : "，根目录扩展也被拒绝（\(rootFailure)）。")
            + "这个系统可能还没有壁纸商店的数据目录；先添加一张系统壁纸，或者改用隧道通道。")
    }

    /// Try each candidate as a container with a bounded parallel scan. A probe
    /// consumes without creating anything, checks the store directory by
    /// content (the only acceptance rule), then releases; the first pass wins
    /// and the rest are cancelled. A candidate the kernel will not extend is
    /// skipped, not fatal.
    private static func tryConsumePosterBoard(among candidates: [String],
                                              label: String,
                                              log: @escaping @Sendable (String) -> Void) -> String? {
        let started = DispatchTime.now()
        var unique: [String] = []
        var seen = Set<String>()
        for candidate in candidates where isDirectory(candidate) {
            if seen.insert(candidate).inserted { unique.append(candidate) }
        }

        let lock = NSLock()
        var found: String?
        var cancelled = false
        var consumed = 0
        var refused = 0
        var identified = 0
        var probed = 0
        let semaphore = DispatchSemaphore(value: probeConcurrency)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "drift.posterboard.probe",
                                  qos: .userInitiated, attributes: .concurrent)

        for candidate in unique {
            semaphore.wait()
            lock.lock()
            let stop = cancelled
            lock.unlock()
            if stop {
                semaphore.signal()
                continue
            }
            group.enter()
            queue.async {
                defer {
                    semaphore.signal()
                    group.leave()
                }
                lock.lock()
                let stopNow = cancelled
                if !stopNow { probed += 1 }
                lock.unlock()
                if stopNow { return }
                do {
                    let handle = try WorseQueryEscape.consume(path: candidate, createDirectory: false)
                    lock.lock(); consumed += 1; lock.unlock()
                    let ok = isPosterBoardContainer(atPath: candidate)
                    WorseQueryEscape.release(handle)
                    if ok {
                        lock.lock()
                        identified += 1
                        if found == nil {
                            found = candidate
                            cancelled = true
                        }
                        lock.unlock()
                    }
                } catch {
                    lock.lock(); refused += 1; lock.unlock()
                }
            }
        }
        group.wait()

        let elapsed = millis(since: started)
        let average = probed > 0 ? elapsed / Double(probed) : 0
        log(String(format: "%@：候选 %d 个，探测 %d 次（并发 %d），consume 成功 %d 个，身份核对通过 %d 个，扩展被拒 %d 个；平均 %.1f ms/次，探测耗时 %.0f ms",
                   label, unique.count, probed, probeConcurrency, consumed, identified, refused,
                   average, elapsed))
        if refused > 0 {
            log("\(label)：\(refused) 个候选容器扩展被拒绝，继续尝试其余路径")
        }
        // Every probe was refused: that is the one pattern concurrency itself
        // could cause (containermanagerd throttling), so retry once serially.
        // A normal scan that simply found nothing does not take this path.
        if found == nil, !unique.isEmpty, refused == probed {
            log("\(label)：并发探测全部被拒，退回串行重试一次")
            for candidate in unique {
                do {
                    let handle = try WorseQueryEscape.consume(path: candidate, createDirectory: false)
                    let ok = isPosterBoardContainer(atPath: candidate)
                    WorseQueryEscape.release(handle)
                    if ok { return candidate }
                } catch {
                    continue
                }
            }
        }
        return found
    }

    private static func firstPosterBoardContainer(among candidates: [String]) -> String? {
        for candidate in candidates {
            guard isDirectory(candidate) else { continue }
            if isPosterBoardContainer(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Content-based identity check: a PosterBoard container is the one that
    /// holds the `Library/Application Support/PRBPosterExtensionDataStore`
    /// store directory. The old getxattr-based check (`com.apple.
    /// containermanager.identifier`) never succeeds on a real 27.2 device,
    /// so every candidate — including the known-good tunnel container —
    /// was rejected. We never use getxattr again.
    private static func isPosterBoardContainer(atPath path: String) -> Bool {
        let storePath = path + "/Library/Application Support/" + PosterBoard.storeDirectoryName
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: storePath, isDirectory: &isDir) && isDir.boolValue
    }

    private static func isDirectory(_ path: String) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &flag) && flag.boolValue
    }

    // MARK: - Threading

    private static func offMainActor<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
