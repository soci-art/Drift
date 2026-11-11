import Foundation

/// Which channel wrote a descriptor. The raw values are the fixed method
/// names, so a receipt reads the same in the list as the home card.
enum PosterBoardReceiptChannel: String, Codable, CaseIterable, Hashable, Sendable {
    case local = "本机直刷"
    case direct = "免注销直刷"
    case airlift = "注销直刷"

    var isTunnel: Bool { self != .local }
}

/// One descriptor Drift wrote, recorded so it can be listed and deleted later
/// without guessing where it went.
///
/// 3106 keeps the same kind of journal; the checklist made it a requirement
/// for the local channel and this round extends it to the two tunnel channels:
/// a receipt is the only proof the management page has that a descriptor is
/// Drift's, so it never lists or deletes anything without one.
struct PosterBoardLocalReceipt: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let date: String
    let pack: String
    let extensionID: String
    /// The store generation (structure version) the folder was written into.
    let generation: Int
    let folderName: String
    let numericID: Int
    /// The absolute `.../descriptors` directory the folder was renamed into.
    let parent: String
    /// Which channel wrote it. Missing in records written by 3.0.0, which
    /// only ever wrote local receipts — those decode as 本机直刷.
    var channel: PosterBoardReceiptChannel? = nil

    var path: String { parent + "/" + folderName }

    /// The channel this receipt belongs to, treating 3.0.0's field-less
    /// records as local.
    var resolvedChannel: PosterBoardReceiptChannel { channel ?? .local }

    var channelLabel: String { resolvedChannel.rawValue }

    var summary: String {
        let identifier = numericID > 0 ? " · #\(numericID)" : ""
        return "\(pack) · \(extensionID) · 代际 \(generation)\(identifier)"
    }
}

/// The receipt journal, stored beside the apply history.
enum PosterBoardLocalReceipts {
    private static let lock = NSLock()

    static func load() -> [PosterBoardLocalReceipt] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    /// Append one placed descriptor. Recording never changes the apply result:
    /// a write that landed stays landed even if the journal cannot be saved.
    static func remember(_ placed: PosterBoardLocal.Placed) {
        remember(pack: placed.pack,
                 channel: .local,
                 extensionID: placed.extensionID,
                 generation: generation(from: placed.parent),
                 folderName: placed.folderName,
                 numericID: placed.numericID,
                 parent: placed.parent)
    }

    /// The descriptors a tunnel run actually wrote. Only the confirmed ones
    /// get a receipt: an unconfirmed write must not become deletable evidence
    /// of a wallpaper the store may never have indexed.
    struct TunnelWrite {
        let pack: String
        let extensionID: String
        let folderName: String
        let numericID: Int
    }

    static func remember(_ writes: [TunnelWrite],
                         confirmed: Set<String>,
                         container: String,
                         structureVersion: Int,
                         channel: PosterBoardReceiptChannel) {
        guard channel.isTunnel else { return }
        for write in writes
        where confirmed.contains("\(write.extensionID)/\(write.folderName)") {
            remember(pack: write.pack,
                     channel: channel,
                     extensionID: write.extensionID,
                     generation: structureVersion,
                     folderName: write.folderName,
                     numericID: write.numericID,
                     parent: PosterBoard.descriptorsParentPath(
                        container: container,
                        structureVersion: structureVersion,
                        extensionID: write.extensionID))
        }
    }

    private static func remember(pack: String,
                                 channel: PosterBoardReceiptChannel,
                                 extensionID: String,
                                 generation: Int,
                                 folderName: String,
                                 numericID: Int,
                                 parent: String) {
        lock.lock()
        defer { lock.unlock() }
        var records = loadLocked()
        records.append(PosterBoardLocalReceipt(
            id: UUID().uuidString,
            date: ISO8601DateFormatter().string(from: Date()),
            pack: pack,
            extensionID: extensionID,
            generation: generation,
            folderName: folderName,
            numericID: numericID,
            parent: parent,
            channel: channel))
        saveLocked(records)
    }

    /// Drop one record after its descriptor was deleted and verified absent.
    static func forget(id: String) {
        lock.lock()
        defer { lock.unlock() }
        saveLocked(loadLocked().filter { $0.id != id })
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The generation number in `.../PRBPosterExtensionDataStore/<n>/Extensions/...`.
    private static func generation(from parent: String) -> Int {
        let parts = parent.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: PosterBoard.storeDirectoryName),
              index + 1 < parts.count else { return 0 }
        return Int(parts[index + 1]) ?? 0
    }

    private static func loadLocked() -> [PosterBoardLocalReceipt] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PosterBoardLocalReceipt].self, from: data)) ?? []
    }

    private static func saveLocked(_ records: [PosterBoardLocalReceipt]) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            // Never throw: the write already succeeded, the journal is auxiliary.
        }
    }

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Drift", isDirectory: true)
            .appendingPathComponent("LocalReceipts.json")
    }
}
