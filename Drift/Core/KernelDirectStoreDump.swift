import Foundation

/// #319 显示关：只读商店内容比对转储。
///
/// Runs in the same kernel session as the write, after the probe (or the
/// write) has finished, and only reads. Every line carries the
/// `[商店转储]` prefix so it can be lifted out of the app log.
///
/// What is dumped:
/// 1. The whole PRBPosterExtensionDataStore tree, relative path and size.
/// 2. One descriptor the app did not write, from the same provider and
///    structure version (falling back to any other store descriptor), with
///    its file list and every text plist's keys and values.
/// 3. The sample descriptor named by the order, the same way.
/// 4. The container's Library level, to look for a second wallpaper store.
///
/// It never creates, edits or deletes anything.
enum KernelDirectStoreDump {
    /// Descriptors written by earlier builds; never used as the system sample.
    static let previouslyWritten: Set<String> = [
        "BD2BBB27-7712-4996-8D8B-B74AC4FF026E",
        "DB3D07FF-1F61-41AF-87C1-9B10D22CBD40",
        "DF7DB641-6C46-4AC5-B87C-1F18A76AD940",
        "C7975343-1EEF-4619-8C99-B6DF4C363036",
        "5CBCF89A-BD9F-4D95-A05C-11E911F591C0",
    ]
    /// The order's own sample, dumped verbatim for side-by-side comparison.
    static let comparisonUUID = "5CBCF89A-BD9F-4D95-A05C-11E911F591C0"
    /// Same provider the pack targets, preferred for the system sample.
    static let sampleProvider = "com.apple.WallpaperKit.CollectionsPoster"

    /// Long values are split so no single log line becomes unusable.
    private static let chunk = 900
    private static let maxTreeEntries = 8_000
    private static let maxPlistBytes = 256 * 1024

    private static let lock = NSLock()
    private static var dumpedInThisProcess = false

    struct Result {
        let systemSample: String?
        let systemSampleSource: String
        let ourSamplePresent: Bool
        let treeEntries: Int
    }

    /// `placedFolders` are this run's own descriptor folder names, so a
    /// freshly written descriptor cannot be mistaken for a system one.
    static func run(container: String,
                    store: String,
                    generation: Int,
                    placedFolders: Set<String>,
                    log: @escaping @Sendable (String) -> Void) -> Result {
        lock.lock()
        let already = dumpedInThisProcess
        dumpedInThisProcess = true
        lock.unlock()

        let emit: @Sendable (String) -> Void = { line in
            for piece in split(line) { log("[商店转储] \(piece)") }
        }

        guard !already else {
            emit("本次进程已经转储过商店，跳过重复转储")
            return Result(systemSample: nil, systemSampleSource: "已转储过",
                          ourSamplePresent: false, treeEntries: 0)
        }

        let started = Date()
        emit("开始：容器 \(container)")
        emit("开始：商店 \(store)，比对结构版本 \(generation)")

        let treeCount = dumpTree(store: store, emit: emit)

        // 2. System sample: same provider, same version first.
        var sample: (path: String, provider: String, version: Int)?
        var source = ""
        let sameSpot = descriptorFolders(store: store,
                                         version: generation,
                                         provider: sampleProvider)
        let excluded = previouslyWritten.union(placedFolders)
        if let candidate = sameSpot.first(where: { !excluded.contains($0) }) {
            sample = (candidate, sampleProvider, generation)
            source = "同扩展同版本"
        } else {
            emit("同扩展同版本下没有系统自带描述符（无系统样本）")
            outer: for version in versionDirectories(store: store) {
                for provider in providers(store: store, version: version)
                where provider != sampleProvider {
                    if let candidate = descriptorFolders(store: store,
                                                         version: version,
                                                         provider: provider)
                        .first(where: { !excluded.contains($0) }) {
                        sample = (candidate, provider, version)
                        source = "全商店任选（扩展 \(provider)，版本 \(version)）"
                        break outer
                    }
                }
            }
        }

        if let sample {
            emit("系统样本：\(source)，\(sample.provider)/\(sample.version)/\(sample.path)")
            dumpDescriptor(store: store,
                           version: sample.version,
                           provider: sample.provider,
                           folder: sample.path,
                           emit: emit)
        } else {
            emit("系统样本：整个商店里也没有可用的系统自带描述符")
        }

        // 3. Our sample, by its exact UUID.
        let ourPath = descriptorFolders(store: store,
                                        version: generation,
                                        provider: sampleProvider)
            .first { $0.caseInsensitiveCompare(comparisonUUID) == .orderedSame }
        if let ourPath {
            emit("我方样本：\(sampleProvider)/\(generation)/\(ourPath)")
            dumpDescriptor(store: store,
                           version: generation,
                           provider: sampleProvider,
                           folder: ourPath,
                           emit: emit)
        } else {
            emit("我方样本：\(generation)/Extensions/\(sampleProvider)/\(comparisonUUID) 不在商店里")
        }

        // 4. Container Library: one level, looking for another store.
        let library = container + "/Library"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: library)) ?? []
        if names.isEmpty {
            emit("容器 Library：读不出条目（\(library)）")
        } else {
            emit("容器 Library 一层：\(names.sorted().joined(separator: "、"))")
            let poster = names.filter { $0.localizedCaseInsensitiveContains("poster") }
            emit("容器 Library 里含 Poster 的条目：\(poster.isEmpty ? "（无）" : poster.joined(separator: "、"))")
            let storeName = (store as NSString).lastPathComponent
            let others = poster.filter { $0 != storeName }
            emit("容器 Library 里除 \(storeName) 外的壁纸相关条目：\(others.isEmpty ? "（无）" : others.joined(separator: "、"))")
        }

        emit(String(format: "结束：树条目 %d 个，总耗时 %.2f 秒", treeCount,
                    Date().timeIntervalSince(started)))
        return Result(systemSample: sample?.path,
                      systemSampleSource: source,
                      ourSamplePresent: ourPath != nil,
                      treeEntries: treeCount)
    }

    // MARK: - Tree

    private static func dumpTree(store: String,
                                 emit: @Sendable (String) -> Void) -> Int {
        let manager = FileManager.default
        emit("树：开始递归列出商店（相对路径 + 大小）")
        guard let enumerator = manager.enumerator(atPath: store) else {
            emit("树：商店无法枚举 \(store)")
            return 0
        }
        var count = 0
        var truncated = false
        for case let relative as String in enumerator {
            if count >= maxTreeEntries {
                truncated = true
                break
            }
            count += 1
            let full = (store as NSString).appendingPathComponent(relative)
            let attributes = try? manager.attributesOfItem(atPath: full)
            let type = attributes?[.type] as? FileAttributeType
            if type == .typeDirectory {
                emit("树 D \(relative)/")
            } else if type == .typeSymbolicLink {
                let target = (try? manager.destinationOfSymbolicLink(atPath: full)) ?? "?"
                emit("树 L \(relative) -> \(target)")
            } else {
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                emit("树 F \(relative) \(size)")
            }
        }
        if truncated {
            emit("树：已达到 \(maxTreeEntries) 条上限，其余条目未列出")
        }
        emit("树：共 \(count) 条")
        return count
    }

    // MARK: - Descriptor

    private static func dumpDescriptor(store: String,
                                       version: Int,
                                       provider: String,
                                       folder: String,
                                       emit: @Sendable (String) -> Void) {
        let manager = FileManager.default
        let root = (store as NSString)
            .appendingPathComponent("\(version)/Extensions/\(provider)/\(folder)")
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            emit("  \(provider)/\(folder)：目录不存在")
            return
        }
        emit("  \(provider)/\(folder)/ 文件清单开始")
        guard let enumerator = manager.enumerator(atPath: root) else {
            emit("  \(provider)/\(folder)：无法枚举")
            return
        }
        var entries = 0
        for case let relative as String in enumerator {
            entries += 1
            let full = (root as NSString).appendingPathComponent(relative)
            let attributes = try? manager.attributesOfItem(atPath: full)
            if (attributes?[.type] as? FileAttributeType) == .typeDirectory {
                emit("  D \(relative)/")
            } else {
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                emit("  F \(relative) \(size)")
            }
        }
        emit("  \(provider)/\(folder)/ 文件清单结束：\(entries) 条")

        // Text plists only: their keys and values are the comparison target.
        let plists = textPlists(under: root)
        if plists.isEmpty {
            emit("  \(provider)/\(folder)：没有文本 plist")
            return
        }
        for plist in plists {
            let attributes = try? manager.attributesOfItem(atPath: plist)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            guard size <= Int64(maxPlistBytes) else {
                emit("  plist 跳过（过大 \(size) 字节）：\(plist.replacingOccurrences(of: root + "/", with: ""))")
                continue
            }
            emit("  plist 开始：\(plist.replacingOccurrences(of: root + "/", with: ""))")
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: plist)) else {
                emit("  plist 读取失败")
                continue
            }
            var format = PropertyListSerialization.PropertyListFormat.xml
            guard let object = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: &format
            ), format.rawValue != PropertyListSerialization.PropertyListFormat.binary.rawValue else {
                emit("  plist 不是文本 plist（或无法解析）")
                continue
            }
            for line in flatten(object, path: "") {
                emit("  \(line)")
            }
            emit("  plist 结束")
        }
    }

    private static func textPlists(under root: String) -> [String] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(atPath: root) else { return [] }
        var found: [String] = []
        for case let relative as String in enumerator where relative.hasSuffix(".plist") {
            let full = (root as NSString).appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)),
                  let head = String(data: data.prefix(64), encoding: .utf8) else { continue }
            // A binary plist starts with "bplist00"; text ones start with
            // either an XML header or an OpenStep "{" / "(".
            guard !head.hasPrefix("bplist00") else { continue }
            found.append(full)
        }
        return found.sorted()
    }

    private static func flatten(_ object: Any, path: String) -> [String] {
        switch object {
        case let dictionary as [String: Any]:
            if dictionary.isEmpty { return ["\(path.isEmpty ? "(根)" : path) = {}"] }
            return dictionary.keys.sorted().flatMap { key in
                flatten(dictionary[key] as Any,
                        path: path.isEmpty ? key : "\(path).\(key)")
            }
        case let array as [Any]:
            if array.isEmpty { return ["\(path.isEmpty ? "(根)" : path) = []"] }
            return array.enumerated().flatMap { index, value in
                flatten(value, path: "\(path)[\(index)]")
            }
        case let string as String:
            return ["\(path) = \(string)"]
        case let data as Data:
            return ["\(path) = <data \(data.count) 字节>"]
        default:
            return ["\(path) = \(object)"]
        }
    }

    // MARK: - Directory helpers

    private static func versionDirectories(store: String) -> [Int] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store)) ?? [])
            .compactMap(Int.init)
            .sorted(by: >)
    }

    private static func providers(store: String, version: Int) -> [String] {
        let root = (store as NSString).appendingPathComponent("\(version)/Extensions")
        return ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
    }

    private static func descriptorFolders(store: String,
                                          version: Int,
                                          provider: String) -> [String] {
        let root = (store as NSString)
            .appendingPathComponent("\(version)/Extensions/\(provider)")
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: root)) ?? []
        return names.filter { name in
            var isDirectory: ObjCBool = false
            let full = (root as NSString).appendingPathComponent(name)
            guard manager.fileExists(atPath: full, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
            return UUID(uuidString: name.uppercased()) != nil
        }.sorted()
    }

    // MARK: - Line splitting

    private static func split(_ line: String) -> [String] {
        guard line.count > chunk else { return [line] }
        var pieces: [String] = []
        var start = line.startIndex
        while start < line.endIndex {
            let end = line.index(start, offsetBy: chunk, limitedBy: line.endIndex) ?? line.endIndex
            pieces.append(String(line[start..<end]))
            start = end
        }
        return pieces
    }
}
