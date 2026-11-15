import Foundation
import Darwin

/// On-device PosterBoard descriptor writer for the iOS 17/18 3106 kernel backend.
///
/// The preflight proves create/write/read/delete access inside the real
/// PosterBoard store. This writer stages each descriptor beside its final
/// destination, verifies copied file and byte counts, fsyncs staged files,
/// then atomically renames the directory into place.
///
/// It intentionally does not call WorseQueryEscape, request an App Group,
/// use a pairing tunnel, or refresh PosterBoard.
enum KernelDirectWriter {
    struct Outcome {
        let verification: PosterStoreVerification
        let installedCount: Int
        /// What was placed, for the receipt journal (#334).
        let placed: [Placed]
    }

    private struct Source {
        let name: String
        let url: URL
        let defaultExtension: String
        let extract: (URL) throws -> Void
    }

    struct Placed {
        let extensionID: String
        let folderName: String
        let parent: String
        let key: String
        /// Source pack name and the randomized numeric id, kept for
        /// the receipt journal (#334).
        let pack: String
        let numericID: Int
    }

    private struct PreparedDescriptor {
        let pack: String
        let folder: URL
        let extensionID: String
        let numericID: Int
        let folderName: String
    }

    /// A copied and fsynced hidden folder, ready for one final atomic rename.
    private struct PendingDescriptor {
        let pack: String
        let extensionID: String
        let folderName: String
        let numericID: Int
        let parent: String
        let stagingPath: String
        let destination: String
        let files: Int
        let bytes: Int64

        var key: String { "\(extensionID)/\(folderName)" }
    }

    static func apply(
        selection: PosterBoardSelection,
        containerPath: String,
        storePath: String,
        structureVersions: [Int],
        deviceVersion: String,
        log: @escaping @Sendable (String) -> Void,
        progress: @escaping (Double) -> Void
    ) throws -> Outcome {
        guard !selection.tendies.isEmpty else {
            throw DriftError("内核直刷需要先选择至少一个 .tendies 壁纸包。")
        }
        guard selection.video == nil,
              !selection.fullReset,
              selection.resetModes.isEmpty else {
            throw DriftError("内核直刷当前只处理已选的 .tendies 描述文件，不处理视频或重置任务。")
        }
        guard selection.tendies.allSatisfy({ !$0.isContainer && !$0.isUnsafeContainer }) else {
            throw DriftError("内核直刷当前只写入描述文件，不接受包含整个商店容器或数据库的包。")
        }

        // Keep the exact path spelling returned by the kernel probe.
        // URL.standardizedFileURL may strip the existing "/private" alias.
        let canonicalContainer = containerPath.hasSuffix("/")
            ? String(containerPath.dropLast())
            : containerPath
        let components = canonicalContainer.split(separator: "/", omittingEmptySubsequences: true)
        let hasSafeComponents = !components.contains(".") && !components.contains("..")
        let hasExpectedRoot = canonicalContainer.hasPrefix(
            "/private/var/mobile/Containers/Data/Application/"
        )
        let hasContainerUUID = UUID(
            uuidString: (canonicalContainer as NSString).lastPathComponent
        ) != nil
        let expectedStore = canonicalContainer + PosterBoard.storeRoot
        let storePathMatches = storePath == expectedStore
        var storeIsDirectory: ObjCBool = false
        let storeExists = FileManager.default.fileExists(
            atPath: storePath,
            isDirectory: &storeIsDirectory
        ) && storeIsDirectory.boolValue

        log("[内核写入] 路径校验：根路径=\(hasExpectedRoot)，容器 UUID=\(hasContainerUUID)，"
            + "路径组件安全=\(hasSafeComponents)，Store 路径匹配=\(storePathMatches)，"
            + "Store 目录存在=\(storeExists)")
        guard hasExpectedRoot, hasContainerUUID, hasSafeComponents,
              storePathMatches, storeExists else {
            throw DriftError(
                "PosterBoard 容器路径未通过校验，拒绝写入。"
                + "（根路径：\(hasExpectedRoot)，容器 UUID：\(hasContainerUUID)，"
                + "路径安全：\(hasSafeComponents)，Store 匹配：\(storePathMatches)，"
                + "目录存在：\(storeExists)）"
            )
        }

        let sources = selection.tendies.map { pack in
            Source(name: pack.name, url: pack.url,
                   defaultExtension: pack.posterType.extensionBundleID) { stage in
                try pack.extract(to: stage)
                if PosterBoard.shouldConvertLegacy(pack: pack,
                                                    deviceVersion: deviceVersion,
                                                    log: log) {
                    PosterBoard.convertLegacyPack(pack.name, at: stage, log: log)
                }
            }
        }

        let manager = FileManager.default
        var sourceStages: [URL] = []
        defer {
            for stage in sourceStages { try? manager.removeItem(at: stage) }
        }

        // Unpack first, then select a generation from the providers actually
        // declared by the descriptor trees, not from the pack's default type.
        let planned = max(1, sources.reduce(0) {
            $0 + PosterBoardAirlift.countDescriptors(inArchiveAt: $1.url)
        })
        log("[内核写入] 计划统计：\(sources.count) 个包，预计 \(planned) 个描述符")
        var prepared: [PreparedDescriptor] = []

        for (sourceIndex, source) in sources.enumerated() {
            log("[内核写入] [\(sourceIndex + 1)/\(sources.count)] \(source.name)")
            let stage = PosterBoard.workDirectory
                .appendingPathComponent("kernel-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: stage, withIntermediateDirectories: true)
            sourceStages.append(stage)

            let extractStarted = Date()
            log("[内核写入] 解包开始：\(source.name)")
            try source.extract(stage)
            log(String(format: "[内核写入] 解包完成：\(source.name)，耗时 %.2f 秒",
                       Date().timeIntervalSince(extractStarted)))

            let discoveryStarted = Date()
            let descriptors = PosterBoardAirlift.findDescriptors(
                in: stage,
                defaultExtension: source.defaultExtension,
                log: { log("[内核写入] " + $0) }
            )
            log(String(format: "[内核写入] 描述符枚举完成：\(source.name)，找到 %d 个，耗时 %.2f 秒",
                       descriptors.count, Date().timeIntervalSince(discoveryStarted)))
            guard !descriptors.isEmpty else {
                throw DriftError("在「\(source.name)」中没有找到壁纸描述文件。")
            }

            for (index, descriptor) in descriptors.enumerated() {
                guard PosterBoard.managedProviders.contains(descriptor.extensionID) else {
                    throw DriftError("不支持的 PosterBoard provider：\(descriptor.extensionID)")
                }
                let numericID = Int.random(in: PosterBoard.identifierRange)
                let folderName: String
                if descriptor.extensionID == PosterBoardLocal.mercuryExtensionID {
                    folderName = descriptor.url.lastPathComponent
                } else {
                    folderName = UUID().uuidString.uppercased()
                }
                guard !folderName.isEmpty,
                      folderName != "." && folderName != "..",
                      !folderName.hasPrefix(".") else {
                    throw DriftError("描述符目录名不安全，拒绝写入。")
                }

                try PosterBoardAirlift.randomizeIdentifiers(
                    in: descriptor.url,
                    numericID: numericID,
                    extensionID: descriptor.extensionID
                )
                try ensureRoleIdentifier(in: descriptor.url)
                prepared.append(PreparedDescriptor(
                    pack: source.name,
                    folder: descriptor.url,
                    extensionID: descriptor.extensionID,
                    numericID: numericID,
                    folderName: folderName
                ))
                log("[内核写入] 已准备描述符：\(index + 1)/\(descriptors.count) "
                    + "\(descriptor.extensionID)/\(folderName)")
            }
        }

        guard !prepared.isEmpty else {
            throw DriftError("没有找到可安装的 PosterBoard 描述符。")
        }

        let requiredProviders = Set(prepared.map(\.extensionID))
        let generations = (structureVersions.isEmpty
            ? generationDirectories(in: storePath)
            : structureVersions)
            .filter { $0 > 0 }
            .sorted(by: >)
        guard let generation = chooseGeneration(
            generations, required: requiredProviders, storePath: storePath
        ) else {
            throw DriftError("设备商店没有同时包含本轮所需 provider 的结构版本："
                + requiredProviders.sorted().joined(separator: "、")
                + "。拒绝创建虚假的 provider 目录。")
        }

        let databaseURL = URL(fileURLWithPath:
            storePath + "/\(generation)/" + PosterBoard.databaseFileName)
        var databaseIsDirectory: ObjCBool = false
        guard manager.fileExists(atPath: databaseURL.path, isDirectory: &databaseIsDirectory),
              !databaseIsDirectory.boolValue else {
            throw DriftError("结构版本 \(generation) 中不存在设备现有数据库：\(databaseURL.path)")
        }

        log("[内核写入] PosterBoard 容器：\(canonicalContainer)")
        log("[内核写入] 商店目录：\(storePath)")
        log("[内核写入] 采用结构版本：\(generation)")
        log("[内核写入] 实际 provider：\(requiredProviders.sorted().joined(separator: "、"))")
        log("[内核数据库] 目标：\(databaseURL.path)")

        // Copy and fsync hidden staging folders before opening the DB transaction.
        // The final UUID path is published only after BEGIN IMMEDIATE has locked
        // the current WAL database; COMMIT follows the last publish immediately.
        var pending: [PendingDescriptor] = []
        defer {
            for item in pending where manager.fileExists(atPath: item.stagingPath) {
                try? manager.removeItem(atPath: item.stagingPath)
                fsyncDirectory(item.parent)
            }
        }
        for item in prepared {
            let parent = PosterBoard.descriptorsParentPath(
                container: canonicalContainer,
                structureVersion: generation,
                extensionID: item.extensionID
            )
            let staged = try stageDescriptor(
                folder: item.folder, parent: parent, name: item.folderName,
                pack: item.pack, extensionID: item.extensionID,
                numericID: item.numericID
            )
            pending.append(staged)
        }
        log("[内核写入] 隐藏暂存完成：\(pending.count) 个目录，尚未发布最终 UUID 目录")

        // A kernel registration only adds the wallpaper to the picker. It must
        // never change the user's currently selected wallpaper.
        let registrationItems = pending.map {
            PosterBoardConfigItem(
                uuid: $0.folderName,
                extensionID: $0.extensionID,
                setSelected: false
            )
        }

        var placed: [Placed] = []
        var completed = 0
        let registration: PosterBoardStore.InPlaceRegistration
        do {
            registration = try PosterBoardStore.registerInPlace(
                database: databaseURL,
                items: registrationItems,
                backupRoot: PosterBoard.workDirectory.deletingLastPathComponent()
                    .appendingPathComponent("KernelDirectDatabaseBackups", isDirectory: true),
                installFiles: {
                    var lastPublishedAt = Date.distantPast
                    for item in pending {
                        lastPublishedAt = try publish(item, log: log)
                        placed.append(Placed(
                            extensionID: item.extensionID,
                            folderName: item.folderName,
                            parent: item.parent,
                            key: item.key,
                            pack: item.pack,
                            numericID: item.numericID
                        ))
                        completed += 1
                        progress(Double(completed) / Double(max(1, pending.count)) * 100)
                    }
                    return lastPublishedAt
                },
                log: { log("[内核数据库] " + $0) }
            )
        } catch {
            log("[内核写入] 文件发布/数据库事务失败：\(error.localizedDescription)")
            for item in placed.reversed() {
                try? manager.removeItem(atPath: item.parent + "/" + item.folderName)
                fsyncDirectory(item.parent)
            }
            throw error
        }

        log("[内核数据库] 原始数据库备份：\(registration.backupDirectory)")
        log("[内核数据库] COMMIT 后完整性：\(registration.integrityCheck)")
        log("[内核数据库] COMMIT 后立即行核验：\(registration.registeredKeys.count)/\(registrationItems.count)")
        if registration.integrityCheck != "ok" {
            throw DriftError("SQLite 已提交，但 integrity_check 异常：\(registration.integrityCheck)。"
                + "已保留文件与数据库现场，请勿重复刷入。")
        }

        log("[内核写入] 文件发布和数据库提交完成，5 秒后进行延迟复查")
        Thread.sleep(forTimeInterval: 5.0)

        let registered: Set<String>
        do {
            registered = try PosterBoardStore.verifyRegisteredItems(
                database: databaseURL,
                items: registrationItems,
                log: { log("[内核数据库] " + $0) }
            )
        } catch {
            log("[② 数据库事务/延迟复查失败] \(error.localizedDescription)")
            throw DriftError("② 数据库登记无法持续确认：\(error.localizedDescription)")
        }

        var directoriesPresent: Set<String> = []
        for item in pending {
            if let stats = try? treeStats(item.destination), stats.files > 0 {
                directoriesPresent.insert(item.key)
            }
        }

        let expected = Set(pending.map(\.key))
        let missingRegistration = expected.subtracting(registered)
        let missingDirectories = expected.subtracting(directoriesPresent)

        for key in missingRegistration.sorted() {
            if missingDirectories.contains(key) {
                log("[① 文件被系统清除且登记未确认] \(key)")
            } else {
                log("[② 数据库行未持续存在] \(key)")
            }
        }
        for key in missingDirectories.subtracting(missingRegistration).sorted() {
            log("[③ 数据库登记仍在、描述符目录已消失] \(key)")
        }

        guard missingRegistration.isEmpty, missingDirectories.isEmpty else {
            throw DriftError("5 秒延迟复查未通过：数据库登记 \(registered.count)/\(expected.count)，"
                + "描述符目录 \(directoriesPresent.count)/\(expected.count)。"
                + "请查看日志中的 ①/②/③ 分类；本次没有报告刷入成功。")
        }

        log("[④ 文件与登记均持续存在] 若系统壁纸列表仍不显示，再检查 descriptor/WallpaperKit 内容兼容。")

        let providers = Set(placed.map(\.extensionID))
        let verification = PosterStoreVerification(
            structureVersion: generation,
            structureVersionSource: "内核直刷：实际 provider 选取代际；SQLite 原位事务登记；5 秒后目录与数据库行复查",
            providersSeen: providers,
            expected: expected,
            confirmed: expected,
            enumeratedAfter: true
        )
        progress(100)
        return Outcome(
            verification: verification,
            installedCount: placed.count,
            placed: placed
        )
    }

    private static func generationDirectories(in storePath: String) -> [Int] {
        (try? FileManager.default.contentsOfDirectory(atPath: storePath))?
            .compactMap(Int.init)
            .filter { $0 > 0 }
            .sorted(by: >) ?? []
    }

    private static func chooseGeneration(_ generations: [Int],
                                         required: Set<String>,
                                         storePath: String) -> Int? {
        for generation in generations {
            let extensionRoot = storePath + "/\(generation)/Extensions"
            let hasProviders = required.allSatisfy {
                FileManager.default.fileExists(atPath: extensionRoot + "/\($0)")
            }
            if hasProviders { return generation }
        }
        return nil
    }

    private static func ensureRoleIdentifier(in folder: URL) throws {
        let roleURL = folder.appendingPathComponent("com.apple.posterkit.role.identifier")
        guard !FileManager.default.fileExists(atPath: roleURL.path) else { return }
        try Data("PRPosterRoleLockScreen".utf8).write(to: roleURL, options: .atomic)
    }

    private static func stageDescriptor(
        folder: URL,
        parent: String,
        name: String,
        pack: String,
        extensionID: String,
        numericID: Int
    ) throws -> PendingDescriptor {
        let manager = FileManager.default
        try manager.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let destination = parent + "/" + name
        guard !manager.fileExists(atPath: destination) else {
            throw DriftError("目标描述符目录已存在，拒绝覆盖：\(destination)")
        }
        let staging = parent + "/.drift-kernel-staging-\(UUID().uuidString)"
        do {
            try manager.copyItem(at: folder, to: URL(fileURLWithPath: staging))
            let sourceStats = try treeStats(folder.path)
            let stagedStats = try treeStats(staging)
            guard sourceStats.files == stagedStats.files,
                  sourceStats.bytes == stagedStats.bytes,
                  stagedStats.files > 0 else {
                throw DriftError("暂存校验失败：源文件与目标文件数或字节数不一致。")
            }
            try fsyncTree(staging)
            return PendingDescriptor(
                pack: pack,
                extensionID: extensionID,
                folderName: name,
                numericID: numericID,
                parent: parent,
                stagingPath: staging,
                destination: destination,
                files: stagedStats.files,
                bytes: stagedStats.bytes
            )
        } catch {
            try? manager.removeItem(atPath: staging)
            throw error
        }
    }

    /// This is the only final-path publication inside the DB transaction.
    private static func publish(
        _ item: PendingDescriptor,
        log: @escaping @Sendable (String) -> Void
    ) throws -> Date {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: item.destination) else {
            throw DriftError("目标描述符目录已存在，拒绝覆盖：\(item.destination)")
        }
        let result = item.stagingPath.withCString { source in
            item.destination.withCString { target in rename(source, target) }
        }
        guard result == 0 else {
            throw DriftError("原子改名失败：\(String(cString: strerror(errno)))")
        }
        let publishedAt = Date()
        fsyncDirectory(item.parent)

        let finalStats = try treeStats(item.destination)
        guard finalStats.files == item.files,
              finalStats.bytes == item.bytes else {
            try? manager.removeItem(atPath: item.destination)
            fsyncDirectory(item.parent)
            throw DriftError("落盘后复核失败：目标目录与暂存内容不一致。")
        }
        log("[内核写入] 发布：\(item.key)（\(finalStats.files) 个文件 / \(finalStats.bytes) 字节）")
        return publishedAt
    }

    private static func treeStats(_ root: String) throws -> (files: Int, bytes: Int64) {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root, isDirectory: &isDirectory) else {
            throw DriftError("待写入目录不存在：\(root)")
        }
        guard isDirectory.boolValue else {
            let attributes = try manager.attributesOfItem(atPath: root)
            return (1, (attributes[.size] as? NSNumber)?.int64Value ?? 0)
        }
        guard let enumerator = manager.enumerator(
            at: URL(fileURLWithPath: root, isDirectory: true),
            includingPropertiesForKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw DriftError("无法枚举待写入目录：\(root)")
        }
        var files = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            guard values.isSymbolicLink != true else {
                throw DriftError("描述文件包含符号链接，拒绝写入：\(url.path)")
            }
            if values.isRegularFile == true {
                files += 1
                bytes += Int64(values.fileSize ?? 0)
            } else if values.isDirectory != true {
                throw DriftError("描述文件包含不支持的文件类型：\(url.path)")
            }
        }
        return (files, bytes)
    }

    private static func fsyncTree(_ root: String) throws {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: URL(fileURLWithPath: root, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw DriftError("无法同步暂存目录：\(root)")
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey
            ])
            guard values.isSymbolicLink != true else {
                throw DriftError("暂存目录包含符号链接：\(url.path)")
            }
            guard values.isRegularFile == true else { continue }
            let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else {
                throw DriftError("无法打开暂存文件进行同步：\(url.path)")
            }
            let result = fsync(fd)
            close(fd)
            guard result == 0 else {
                throw DriftError("暂存文件 fsync 失败：\(url.path)")
            }
        }
        fsyncDirectory(root)
    }

    private static func fsyncDirectory(_ path: String) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }
}
