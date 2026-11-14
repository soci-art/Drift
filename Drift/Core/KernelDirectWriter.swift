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
    }

    private struct Source {
        let name: String
        let url: URL
        let defaultExtension: String
        let extract: (URL) throws -> Void
    }

    private struct Placed {
        let extensionID: String
        let folderName: String
        let parent: String
        let key: String
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

        let canonicalContainer = URL(fileURLWithPath: containerPath).standardizedFileURL.path
        let expectedStore = canonicalContainer + PosterBoard.storeRoot
        guard canonicalContainer.hasPrefix("/private/var/mobile/Containers/Data/Application/"),
              UUID(uuidString: URL(fileURLWithPath: canonicalContainer).lastPathComponent) != nil,
              storePath == expectedStore,
              FileManager.default.fileExists(atPath: storePath) else {
            throw DriftError("PosterBoard 容器路径未通过校验，拒绝写入。")
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
        let generations = structureVersions.isEmpty
            ? generationDirectories(in: storePath)
            : structureVersions.sorted(by: >)
        let requiredProviders = Set(sources.map(\.defaultExtension))
        let generation = chooseGeneration(generations,
                                          required: requiredProviders,
                                          storePath: storePath)
        log("[内核写入] PosterBoard 容器：\(canonicalContainer)")
        log("[内核写入] 商店目录：\(storePath)")
        log("[内核写入] 采用结构版本：\(generation)")

        log("[内核写入] 计划统计开始：\(sources.count) 个包")
        let planningStarted = Date()
        let planned = max(1, sources.reduce(0) {
            $0 + PosterBoardAirlift.countDescriptors(inArchiveAt: $1.url)
        })
        log(String(format: "[内核写入] 计划统计完成：预计 %d 个描述符，耗时 %.2f 秒",
                   planned, Date().timeIntervalSince(planningStarted)))
        var completed = 0
        var placed: [Placed] = []

        do {
            for (sourceIndex, source) in sources.enumerated() {
                log("[内核写入] [\(sourceIndex + 1)/\(sources.count)] \(source.name)")
                let stage = PosterBoard.workDirectory
                    .appendingPathComponent("kernel-\(UUID().uuidString)",
                                            isDirectory: true)
                try manager.createDirectory(at: stage,
                                            withIntermediateDirectories: true)
                defer { try? manager.removeItem(at: stage) }

                let extractStarted = Date()
                log("[内核写入] 解包开始：\(source.name)")
                try source.extract(stage)
                log(String(format: "[内核写入] 解包完成：\(source.name)，耗时 %.2f 秒",
                           Date().timeIntervalSince(extractStarted)))
                let discoveryStarted = Date()
                log("[内核写入] 描述符枚举开始：\(source.name)")
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

                for (descriptorIndex, descriptor) in descriptors.enumerated() {
                    guard PosterBoard.managedProviders.contains(descriptor.extensionID) else {
                        throw DriftError("不支持的 PosterBoard provider：\(descriptor.extensionID)")
                    }
                    let numericID = Int.random(in: PosterBoard.identifierRange)
                    let parent = PosterBoard.descriptorsParentPath(
                        container: canonicalContainer,
                        structureVersion: generation,
                        extensionID: descriptor.extensionID
                    )
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
                    let destination = parent + "/" + folderName
                    guard !manager.fileExists(atPath: destination) else {
                        throw DriftError("目标描述符目录已存在，拒绝覆盖：\(destination)")
                    }

                    try PosterBoardAirlift.randomizeIdentifiers(
                        in: descriptor.url,
                        numericID: numericID,
                        extensionID: descriptor.extensionID
                    )
                    let installStarted = Date()
                    log("[内核写入] 落盘开始：\(descriptor.extensionID)/\(folderName)")
                    try install(folder: descriptor.url,
                                parent: parent,
                                name: folderName,
                                log: log)
                    log(String(format: "[内核写入] 落盘完成：\(descriptor.extensionID)/\(folderName)，耗时 %.2f 秒",
                               Date().timeIntervalSince(installStarted)))

                    placed.append(Placed(
                        extensionID: descriptor.extensionID,
                        folderName: folderName,
                        parent: parent,
                        key: "\(descriptor.extensionID)/\(folderName)"
                    ))
                    completed += 1
                    progress(Double(completed) / Double(planned) * 100)
                    log("[内核写入] ✅ \(descriptorIndex + 1)/\(descriptors.count) → \(descriptor.extensionID)/\(folderName)")
                }
            }
        } catch {
            log("[内核写入] 事务失败，回滚本轮已落盘的 \(placed.count) 个描述符")
            for item in placed.reversed() {
                try? manager.removeItem(atPath: item.parent + "/" + item.folderName)
                fsyncDirectory(item.parent)
            }
            throw error
        }

        guard !placed.isEmpty else {
            throw DriftError("没有写入任何 PosterBoard 描述文件。")
        }

        log("[内核写入] 写后核验开始：\(placed.count) 个目标目录")
        let verificationStarted = Date()
        var confirmed: Set<String> = []
        for item in placed {
            let destination = item.parent + "/" + item.folderName
            guard let stats = try? treeStats(destination), stats.files > 0 else {
                log("[内核写入] 写后核验缺失或不可读：\(item.key)")
                continue
            }
            confirmed.insert(item.key)
        }
        log(String(format: "[内核写入] 写后核验结束：在册 %d/%d，耗时 %.2f 秒",
                   confirmed.count, placed.count,
                   Date().timeIntervalSince(verificationStarted)))

        let providers = Set(placed.map(\.extensionID))
        let verification = PosterStoreVerification(
            structureVersion: generation,
            structureVersionSource: "内核直刷：从 PosterBoard 容器实际读取结构版本",
            providersSeen: providers,
            expected: Set(placed.map(\.key)),
            confirmed: confirmed,
            enumeratedAfter: true
        )
        progress(100)
        return Outcome(verification: verification, installedCount: placed.count)
    }

    private static func generationDirectories(in storePath: String) -> [Int] {
        (try? FileManager.default.contentsOfDirectory(atPath: storePath))?
            .compactMap(Int.init)
            .filter { $0 > 0 }
            .sorted(by: >) ?? []
    }

    private static func chooseGeneration(_ generations: [Int],
                                         required: Set<String>,
                                         storePath: String) -> Int {
        let manager = FileManager.default
        for generation in generations {
            let extensionRoot = storePath + "/\(generation)/Extensions"
            let providers = Set((try? manager.contentsOfDirectory(
                atPath: extensionRoot
            )) ?? [])
            if required.isSubset(of: providers) { return generation }
        }
        return generations.first ?? PosterBoard.fallbackStructureVersion
    }

    private static func install(folder: URL,
                                parent: String,
                                name: String,
                                log: @escaping @Sendable (String) -> Void) throws {
        let manager = FileManager.default
        try manager.createDirectory(atPath: parent,
                                    withIntermediateDirectories: true)
        let staging = parent + "/.drift-kernel-staging-\(UUID().uuidString)"
        defer { try? manager.removeItem(atPath: staging) }

        try manager.copyItem(at: folder,
                             to: URL(fileURLWithPath: staging))
        let sourceStats = try treeStats(folder.path)
        let stagedStats = try treeStats(staging)
        guard sourceStats.files == stagedStats.files,
              sourceStats.bytes == stagedStats.bytes else {
            throw DriftError("暂存校验失败：源文件与目标文件数或字节数不一致。")
        }
        try fsyncTree(staging)

        let destination = parent + "/" + name
        guard !manager.fileExists(atPath: destination) else {
            throw DriftError("目标目录已存在，拒绝覆盖：\(destination)")
        }
        let result = staging.withCString { source in
            destination.withCString { target in rename(source, target) }
        }
        guard result == 0 else {
            throw DriftError("原子改名失败：\(String(cString: strerror(errno)))")
        }
        fsyncDirectory(parent)

        let finalStats = try treeStats(destination)
        guard finalStats.files == sourceStats.files,
              finalStats.bytes == sourceStats.bytes else {
            try? manager.removeItem(atPath: destination)
            fsyncDirectory(parent)
            throw DriftError("落盘后复核失败：目标目录与源内容不一致。")
        }
        log("[内核写入] 落盘：\(name)（\(finalStats.files) 个文件 / \(finalStats.bytes) 字节）")
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
