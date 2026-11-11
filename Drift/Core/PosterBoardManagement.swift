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

        struct GroupKey: Hashable {
            let container: String
            let generation: Int
        }
        var groups: [GroupKey: [PosterBoardLocalReceipt]] = [:]
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
            groups[GroupKey(container: container, generation: receipt.generation),
                   default: []].append(receipt)
        }

        for (key, group) in groups {
            do {
                let items = try await Airlift.posterStoreList(
                    pairingPath: AppPaths.pairingFile.path,
                    containerPath: key.container,
                    structureVersion: key.generation)
                let present = Set(items.map { "\($0.extension)/\($0.uuid)" })
                for receipt in group {
                    states[receipt.id] = present.contains(
                        "\(receipt.extensionID)/\(receipt.folderName)") ? .inStore : .absent
                }
                log("管理页对账：结构版本 \(key.generation) 枚举到 \(items.count) 个描述符。")
            } catch {
                for receipt in group {
                    states[receipt.id] = .unknown("商店枚举失败：\(error.localizedDescription)")
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
        switch receipt.resolvedChannel {
        case .local:
            try await PosterBoardLocal.delete(receipt: receipt, log: log)
            record(receipt, success: true,
                   verification: "本机删除后：目录已不在商店")
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
                       verification: "删除返回无法解析")
                throw DriftError("商店删除的返回无法解析，没有确认删除。")
            }
            guard let item = reply.results.first(where: { $0.uuid == receipt.folderName }),
                  item.ok else {
                record(receipt, success: false,
                       verification: "商店没有确认删除：\(reply.failed) 项失败")
                throw DriftError("商店没有确认删除这个描述符（可能已不在册，请重新核对）。")
            }
            if reply.commitAudit {
                PosterBoardLocalReceipts.forget(id: receipt.id)
                record(receipt, success: true,
                       verification: "隧道删除后复核：描述符已不在册")
                return PosterBoardDeletionOutcome(
                    confirmed: true,
                    message: "已删除并核验不在册：\(receipt.pack) 的描述符已从设备商店移除。可以点「刷新 PosterBoard」让它重新读取商店，或手动注销。",
                    channel: receipt.resolvedChannel)
            }
            record(receipt, success: false,
                   verification: "已删除、未确认：提交复核不可用，回执保留")
            return PosterBoardDeletionOutcome(
                confirmed: false,
                message: "已删除、未确认：商店的提交复核没有完成，回执先保留，下次对账再确认。不要把它当成已确认删除。",
                channel: receipt.resolvedChannel)
        }
    }

    /// Every management deletion lands in the apply history, with the pack,
    /// the channel and what was actually established.
    private static func record(_ receipt: PosterBoardLocalReceipt,
                               success: Bool,
                               verification: String) {
        ApplyHistory.record(mode: "删除壁纸 · \(receipt.pack)",
                            success: success,
                            error: success ? "" : verification,
                            channel: receipt.channelLabel,
                            provider: receipt.extensionID,
                            verification: verification)
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
