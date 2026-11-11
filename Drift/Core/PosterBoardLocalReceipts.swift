import Foundation

/// One descriptor the local channel wrote, recorded so it can be listed and
/// deleted later without guessing where it went.
///
/// 3106 keeps the same kind of journal; the checklist makes it a requirement
/// for this channel: every write records its destination and identifier, and
/// deletion is driven by that record, not by a re-scan.
struct PosterBoardLocalReceipt: Codable, Identifiable, Equatable {
    let id: String
    let date: String
    let pack: String
    let extensionID: String
    let generation: Int
    let folderName: String
    let numericID: Int
    /// The absolute `.../descriptors` directory the folder was renamed into.
    let parent: String

    var path: String { parent + "/" + folderName }

    var summary: String {
        "\(pack) · \(extensionID) · 代际 \(generation) · #\(numericID)"
    }
}

/// The local channel's receipt journal, stored beside the apply history.
enum PosterBoardLocalReceipts {
    private static let lock = NSLock()

    static func load() -> [PosterBoardLocalReceipt] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PosterBoardLocalReceipt].self, from: data)) ?? []
    }

    /// Append one placed descriptor. Recording never changes the apply result:
    /// a write that landed stays landed even if the journal cannot be saved.
    static func remember(_ placed: PosterBoardLocal.Placed) {
        lock.lock()
        defer { lock.unlock() }
        var records = loadLocked()
        records.append(PosterBoardLocalReceipt(
            id: UUID().uuidString,
            date: ISO8601DateFormatter().string(from: Date()),
            pack: placed.pack,
            extensionID: placed.extensionID,
            generation: generation(from: placed.parent),
            folderName: placed.folderName,
            numericID: placed.numericID,
            parent: placed.parent))
        saveLocked(records)
    }

    /// Drop one record after its directory was deleted (or was already gone).
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
