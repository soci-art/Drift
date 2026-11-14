import Foundation

/// The state of one receipt against the device store. `unknown` is a real
/// answer — the premises for checking are not there — and must never be
/// rendered as "in store" or "gone".
enum PosterBoardReconcileState: Equatable {
    case inStore
    case absent
    case unsupported(String)
    case unknown(String)

    var label: String {
        switch self {
        case .inStore: return "在册"
        case .absent: return "已不在册"
        case .unsupported: return "暂不支持"
        case .unknown: return "未核对"
        }
    }

    var note: String {
        switch self {
        case .inStore: return ""
        case .absent: return "设备商店里已经找不到这张壁纸。"
        case .unsupported(let reason), .unknown(let reason): return reason
        }
    }
}

/// Collects the lines one deletion emits, so the deletion's history
/// record can carry that run's own log slice (collection #308,
/// Grace, 2026-11-13). A deletion record used to export with nothing
/// but its own text — no log slice, no pack — while a flash record
/// exports all three; the sink tees every line into this buffer and
/// forwards it to the caller's log unchanged.
final class DeletionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let forward: @Sendable (String) -> Void

    init(forward: @escaping @Sendable (String) -> Void) {
        self.forward = forward
    }

    var sink: @Sendable (String) -> Void {
        { line in
            self.lock.lock()
            self.lines.append(line)
            self.lock.unlock()
            self.forward(line)
        }
    }

    var text: String? {
        lock.lock()
        defer { lock.unlock() }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// What one management deletion established.
struct PosterBoardDeletionOutcome {
    /// True only when the deletion was verified: the local directory is gone,
    /// or the tunnel's fresh commit audit says the descriptor is absent.
    let confirmed: Bool
    let message: String
    let channel: PosterBoardReceiptChannel
}

/// Listing, reconciling and deleting the wallpapers Drift itself wrote.
///
/// The safety line is the receipt: only a descriptor in the journal is ever
/// listed or deleted. System wallpapers and wallpapers other tools wrote are
/// not ours to manage.
enum PosterBoardManagement {
    /// The Rust store primitives audit and delete only these two providers.
    /// Everything else is refused under the FFI, so the UI must say so rather
    /// than offer a button that cannot work.
    static let tunnelSupportedProviders: Set<String> = [
        "com.apple.WallpaperKit.CollectionsPoster",
        "com.apple.Posters.CollectionsPosterApp",
    ]

    static func tunnelSupports(_ extensionID: String) -> Bool {
        tunnelSupportedProviders.contains(extensionID)
    }

    /// The container path in a receipt's absolute parent directory.
    static func containerPath(from parent: String) -> String? {
        let marker = "/Library/Application Support/\(PosterBoard.storeDirectoryName)/"
        guard let range = parent.range(of: marker) else { return nil }
        var root = String(parent[..<range.lowerBound])
        if !root.hasSuffix("/") { root += "/" }
        return root
    }

    /// Compare every receipt with the store in its own channel. Local receipts
    /// are checked on disk; tunnel receipts by enumerating the device store
    /// when the tunnel premises are present.
    static func reconcile(_ receipts: [PosterBoardLocalReceipt],
                          tunnelReady: Bool,
                          log: @escaping @Sendable (String) -> Void) async -> [String: PosterBoardReconcileState] {
        var states: [String: PosterBoardReconcileState] = [:]
        let local = receipts.filter { $0.resolvedChannel == .local }
        let tunnel = receipts.filter { $0.resolvedChannel.isTunnel }

        if !local.isEmpty {
            do {
                let present = try await PosterBoardLocal.existingReceiptIDs(local, log: log)
                for receipt in local {
                    states[receipt.id] = present.contains(receipt.id) ? .inStore : .absent
                }
            } catch {
                for receipt in local {
                    states[receipt.id] = .unknown("本机商店打不开：\(error.localizedDescription)")
                }
            }
        }

        guard !tunnel.isEmpty else { return states }
        guard tunnelReady else {
            for receipt in tunnel {
                states[receipt.id] = .unknown("需要配对文件、LocalDevVPN 和已连接的设备，隧道就绪后才能核对。")
            }
            return states
        }

        var groups: [String: [Int: [PosterBoardLocalReceipt]]] = [:]
        for receipt in tunnel {
            guard tunnelSupports(receipt.extensionID) else {
                states[receipt.id] = .unsupported(
                    "隧道管理目前只覆盖合集类壁纸；这条 \(receipt.channelLabel) 回执的 \(receipt.extensionID) 描述符暂不支持核对或删除。")
                continue
            }
            guard receipt.generation > 0,
                  let container = containerPath(from: receipt.parent) else {
                states[receipt.id] = .unknown("回执里缺少结构版本或容器路径，无法核对。")
                continue
            }
            var containerGroups = groups[container] ?? [:]
            var generationReceipts = containerGroups[receipt.generation] ?? []
            generationReceipts.append(receipt)
            containerGroups[receipt.generation] = generationReceipts
            groups[container] = containerGroups
        }

        // Read the root once per container; never ask store_list for a
        // generation absent from that root listing.
        for (container, generationGroups) in groups {
            let availableGenerations: Set<Int>
            do {
                availableGenerations = Set(try await Airlift.posterStoreGenerations(
                    pairingPath: AppPaths.pairingFile.path,
                    containerPath: container))
                log("管理页对账：商店根目录结构版本 \(availableGenerations.sorted())。")
            } catch {
                for group in generationGroups.values {
                    for receipt in group {
                        states[receipt.id] = .unknown("商店根目录枚举失败：\(error.localizedDescription)")
                    }
                }
                continue
            }

            for generation in generationGroups.keys.sorted() {
                guard let group = generationGroups[generation] else { continue }
                guard availableGenerations.contains(generation) else {
                    for receipt in group { states[receipt.id] = .absent }
                    log("管理页对账：结构版本 \(generation) 不在商店根目录中，跳过细问。")
                    continue
                }
                do {
                    let items = try await Airlift.posterStoreList(
                        pairingPath: AppPaths.pairingFile.path,
                        containerPath: container,
                        structureVersion: generation)
                    let present = Set(items.map { "\($0.extension)/\($0.uuid)" })
                    for receipt in group {
                        states[receipt.id] = present.contains(
                            "\(receipt.extensionID)/\(receipt.folderName)") ? .inStore : .absent
                    }
                    log("管理页对账：结构版本 \(generation) 枚举到 \(items.count) 个描述符。")
                } catch {
                    for receipt in group {
                        states[receipt.id] = .unknown("商店枚举失败：\(error.localizedDescription)")
                    }
                }
            }
        }
        return states
    }

    /// Delete one receipt's descriptor through the channel that wrote it.
    /// Never falls back to another channel.
    static func delete(_ receipt: PosterBoardLocalReceipt,
                       tunnelReady: Bool,
                       log: @escaping @Sendable (String) -> Void) async throws -> PosterBoardDeletionOutcome {
        // #308: the lines this deletion emits become its record's
        // log slice, like a flash run's.
        let collected = DeletionLog(forward: log)
        let log = collected.sink
        switch receipt.resolvedChannel {
        case .local:
            try await PosterBoardLocal.delete(receipt: receipt, log: log)
            record(receipt, success: true,
                   verification: "本机删除后：目录已不在商店",
                   logSlice: collected.text)
            return PosterBoardDeletionOutcome(
                confirmed: true,
                message: "已删除并在本机核验：\(receipt.pack) 的描述符已不在商店里。打开应用切换器，向上轻扫关闭 PosterBoard 后生效。",
                channel: .local)

        case .direct, .airlift:
            guard tunnelSupports(receipt.extensionID) else {
                throw DriftError("隧道管理目前只覆盖合集类壁纸；这条 \(receipt.channelLabel) 回执的 \(receipt.extensionID) 描述符暂不支持删除。")
            }
            guard tunnelReady else {
                throw DriftError("隧道没有就绪：需要配对文件、LocalDevVPN，并且能读到设备。隧道条目的删除不能改走本机通道。")
            }
            guard receipt.generation > 0,
                  let container = containerPath(from: receipt.parent) else {
                throw DriftError("回执里缺少结构版本或容器路径，无法定位这个描述符。")
            }
            log("管理页删除：\(receipt.channelLabel) · \(receipt.extensionID)/\(receipt.folderName)")
            let json = try await Airlift.posterStoreDelete(
                pairingPath: AppPaths.pairingFile.path,
                containerPath: container,
                structureVersion: receipt.generation,
                descriptorIDs: ["\(receipt.extensionID)/\(receipt.folderName)"])
            guard let data = json.data(using: .utf8),
                  let reply = try? JSONDecoder().decode(StoreDeleteReply.self, from: data) else {
                record(receipt, success: false,
                       verification: "删除返回无法解析",
                       logSlice: collected.text)
                throw DriftError("商店删除的返回无法解析，没有确认删除。")
            }
            guard let item = reply.results.first(where: { $0.uuid == receipt.folderName }),
                  item.ok else {
                record(receipt, success: false,
                       verification: "商店没有确认删除：\(reply.failed) 项失败",
                       logSlice: collected.text)
                throw DriftError("商店没有确认删除这个描述符（可能已不在册，请重新核对）。")
            }
            if reply.commitAudit {
                PosterBoardLocalReceipts.forget(id: receipt.id)
                record(receipt, success: true,
                       verification: "隧道删除后复核：描述符已不在册",
                       logSlice: collected.text)
                return PosterBoardDeletionOutcome(
                    confirmed: true,
                    message: "已删除并核验不在册：\(receipt.pack) 的描述符已从设备商店移除。可以点「刷新 PosterBoard」让它重新读取商店，或手动注销。",
                    channel: receipt.resolvedChannel)
            }
            record(receipt, success: false,
                   verification: "已删除、未确认：提交复核不可用，回执保留",
                   logSlice: collected.text)
            return PosterBoardDeletionOutcome(
                confirmed: false,
                message: "已删除、未确认：商店的提交复核没有完成，回执先保留，下次对账再确认。不要把它当成已确认删除。",
                channel: receipt.resolvedChannel)
        }
    }

    // MARK: - Enumeration-based management (store is the source of truth)

    // Collection #288 (Grace, 2026-11-13): the manager makes NO
    // judgement about who wrote a descriptor. The #275 experiment —
    // labelling entries 系统壁纸 / 刷入壁纸 — was tried in 3.0.13
    // and failed on her real store: on the local channel the contents
    // of every entry came back unreadable, so only the package name
    // was left to judge by, and it mislabelled five stock system
    // wallpapers (Clownfish, the iOS 17 default, Space Black, Stripe
    // Green, Multicolored — their "package name" is Apple's own asset
    // identifier) as flashed. Her call: no labels, no classification,
    // the page just lists what is in the store. The classification
    // machinery that briefly lived here is gone on purpose.

    struct ManagedEntry: Identifiable, Hashable {
        let id: String
        let provider: String
        let uuid: String
        let name: String
        let packageName: String
        let generation: Int
        let containerPath: String
    }

    /// Load the descriptors currently in the store, choosing the source by
    /// premise: tunnel first, then local. Returns entries plus a source label
    /// and an optional reason when nothing could be enumerated.
    static func loadManagedEntries(
        tunnelReady: Bool,
        identityVersion: String,
        log: @escaping @Sendable (String) -> Void
    ) async -> (entries: [ManagedEntry], source: String, reason: String?) {
        let tunnelAvailable = tunnelReady && !identityVersion.isEmpty
        if tunnelAvailable {
            var container = PosterBoardAirlift.cachedContainer
            if container.isEmpty {
                do { container = try await PosterBoardAirlift.resolveContainer(
                    pairingPath: AppPaths.pairingFile.path) }
                catch { container = "" }
            }
            guard !container.isEmpty else {
                return ([], "隧道", "隧道容器未读到，无法列出商店。")
            }
            if !container.hasSuffix("/") { container += "/" }
            let availableGenerations: Set<Int>
            do {
                availableGenerations = Set(try await Airlift.posterStoreGenerations(
                    pairingPath: AppPaths.pairingFile.path,
                    containerPath: container))
            } catch {
                return ([], "隧道", "隧道商店没读到：\(error.localizedDescription)")
            }
            guard !availableGenerations.isEmpty else {
                log("隧道商店根目录为空，没有可管理的描述符。")
                return ([], "隧道", nil)
            }
            log("隧道商店根目录：实际存在的结构版本 \(availableGenerations.sorted())。")

            var entries: [ManagedEntry] = []
            var seen = Set<String>()
            for generation in [61, 62, 63, 60, 64] where availableGenerations.contains(generation) {
                do {
                    let items = try await Airlift.posterStoreList(
                        pairingPath: AppPaths.pairingFile.path,
                        containerPath: container,
                        structureVersion: generation)
                    for item in items where PosterBoard.managedProviders.contains(item.extension) {
                        let key = "\(item.extension)/\(item.uuid)/\(generation)"
                        if seen.contains(key) { continue }
                        seen.insert(key)
                        entries.append(ManagedEntry(
                            id: key,
                            provider: item.extension,
                            uuid: item.uuid,
                            name: (item.name?.isEmpty == false) ? (item.name ?? item.uuid) : (item.packageName?.isEmpty == false ? item.packageName! : String(item.uuid.prefix(8))),
                            packageName: item.packageName ?? "",
                            generation: generation,
                            containerPath: container))
                    }
                } catch {
                    continue
                }
            }
            return (entries, "隧道", nil)
        }

        let localAvailable = WorseQueryEscape.isAvailable(
            deviceVersion: WorseQueryEscape.processVersion,
            buildVersion: WorseQueryEscape.processBuildVersion)
        if localAvailable {
            do {
                let (container, items) = try await PosterBoardLocal.enumerateLocalStore(log: log)
                let entries = items.map { item in
                    ManagedEntry(
                        id: "\(item.provider)/\(item.uuid)/\(item.generation)",
                        provider: item.provider,
                        uuid: item.uuid,
                        name: item.name,
                        packageName: item.packageName,
                        generation: item.generation,
                        containerPath: container)
                }
                return (entries, "本机", nil)
            } catch {
                let message = error.localizedDescription
                return ([], "本机", message.hasPrefix("这次没找到壁纸商店")
                    ? message : "本机商店打不开：\(message)")
            }
        }

        return ([], "", "需要配对文件、LocalDevVPN 和已连接的设备，或本机直刷可用，才能列出商店里的壁纸。")
    }

    /// Delete one managed entry through whichever route the premises allow.
    static func deleteManagedEntry(
        _ entry: ManagedEntry,
        tunnelReady: Bool,
        identityVersion: String,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> (confirmed: Bool, message: String, channelLabel: String) {
        // #308: same log-slice treatment as the receipt path — the
        // lines this deletion emits ride along into its record. An
        // entry with no receipt has no original pack to name; the
        // exporter declares that missing, as before.
        let collected = DeletionLog(forward: log)
        let log = collected.sink
        let tunnelAvailable = tunnelReady && !identityVersion.isEmpty
        let localAvailable = WorseQueryEscape.isAvailable(
            deviceVersion: WorseQueryEscape.processVersion,
            buildVersion: WorseQueryEscape.processBuildVersion)

        if tunnelAvailable {
            let json = try await Airlift.posterStoreDelete(
                pairingPath: AppPaths.pairingFile.path,
                containerPath: entry.containerPath,
                structureVersion: entry.generation,
                descriptorIDs: ["\(entry.provider)/\(entry.uuid)"])
            var commitAudit = false
            var itemOK = false
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                commitAudit = obj["commitAudit"] as? Bool ?? false
                if let results = obj["results"] as? [[String: Any]] {
                    itemOK = results.contains { ($0["uuid"] as? String) == entry.uuid && ($0["ok"] as? Bool ?? false) }
                }
            }
            let confirmed = itemOK && commitAudit
            if confirmed {
                ApplyHistory.record(mode: "删除壁纸 · \(entry.name)",
                                    success: true,
                                    ios: identityVersion,
                                    channel: "隧道",
                                    provider: entry.provider,
                                    verification: "隧道删除后复核：描述符已不在册",
                                    packName: entry.name,
                                    logSliceText: collected.text)
            } else {
                ApplyHistory.record(mode: "删除壁纸 · \(entry.name)",
                                    success: false,
                                    error: "已删除、未确认",
                                    ios: identityVersion,
                                    channel: "隧道",
                                    provider: entry.provider,
                                    verification: "已删除、未确认：提交复核不可用",
                                    packName: entry.name,
                                    logSliceText: collected.text)
            }
            let message = confirmed
                ? "已删除并核验不在册：\(entry.name) 的描述符已从设备商店移除。"
                : "已删除、未确认：商店的提交复核没有完成，下次对账再确认。不要把它当成已确认删除。"
            return (confirmed, message, "隧道")
        }

        if localAvailable {
            try await PosterBoardLocal.deleteManagedDescriptor(
                provider: entry.provider, uuid: entry.uuid,
                generation: entry.generation, log: log)
            // #161: no auto-open here any more. The management view prompts
            // first — keyed to how the wallpaper was flashed — and only acts
            // when the user taps.
            ApplyHistory.record(mode: "删除壁纸 · \(entry.name)",
                                success: true,
                                ios: WorseQueryEscape.processVersion,
                                channel: "本机",
                                provider: entry.provider,
                                verification: "本机删除后：目录已不在商店",
                                packName: entry.name,
                                logSliceText: collected.text)
            return (true, "已删除并在本机核验：\(entry.name) 的描述符已不在商店里。", "本机")
        }

        throw DriftError("删不了：隧道和本机两条路现在都走不通。")
    }

    /// Every management deletion lands in the apply history, with the pack,
    /// the channel and what was actually established.
    private static func record(_ receipt: PosterBoardLocalReceipt,
                               success: Bool,
                               verification: String,
                               logSlice: String? = nil) {
        // #186 red line (Grace, 2026-11-11): a record's system version is
        // always a real value — the tunnel-read device version when there
        // is one, this device's own version otherwise. Never empty:
        // "未知系统" must be impossible, the log package depends on it.
        let tunnelVersion = DeviceIdentityMonitor.shared.current.version
        let ios = receipt.resolvedChannel == .local
            ? WorseQueryEscape.processVersion
            : (tunnelVersion.isEmpty ? WorseQueryEscape.processVersion : tunnelVersion)
        // #308: the record names the pack file the wallpaper came
        // from, so its export bundle can carry the original pack
        // like a flash record's does (the exporter still declares
        // it missing when the pack has left the library).
        ApplyHistory.record(mode: "删除壁纸 · \(receipt.pack)",
                            success: success,
                            error: success ? "" : verification,
                            ios: ios,
                            channel: receipt.channelLabel,
                            provider: receipt.extensionID,
                            verification: verification,
                            packName: receipt.pack,
                            packFiles: [receipt.pack],
                            logSliceText: logSlice)
    }

    private struct StoreDeleteReply: Decodable {
        let deleted: Int
        let failed: Int
        let commitAudit: Bool
        let results: [StoreDeleteItem]

        struct StoreDeleteItem: Decodable {
            let `extension`: String
            let uuid: String
            let ok: Bool
        }
    }
}
