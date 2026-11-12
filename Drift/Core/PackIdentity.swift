import Foundation
import ZIPFoundation

/// Import-time descriptor-identity normalisation (#259, Grace
/// 2026-11-12): some pack-making tools stamp every pack they produce
/// with the SAME placeholder descriptor id — the Gothic pack caught in
/// the wild literally ships `99990000-0000-0000-0000-000000000000`.
/// Packs that share an id collide in the store: flash one and it can
/// displace the other, or never appear at all.
///
/// Grace's ruling: this is not a repair the user should have to run —
/// importing a pack swaps any placeholder id (and any id another
/// imported pack already uses) for a fresh UUID right away, folder
/// name and every in-pack reference together, so the pack that lands
/// in the list is already clean. A pack carrying only ordinary unique
/// ids costs one archive listing and is left byte-for-byte alone.
///
/// The swap works on the stored file: extract, rename the descriptor
/// folders, byte-replace the old id strings (same 36 characters, so
/// XML and binary plists alike stay well-formed), rezip over the
/// original. Any failure leaves the imported file untouched — a pack
/// with a shared id is still a usable pack, just not a normalised one.
enum PackIdentity {

    /// A UUID whose hex digits use at most two distinct characters is
    /// a placeholder, not an identity: `99990000-0000-…`, all zeros,
    /// all ones. A randomly minted UUID uses a dozen-plus distinct
    /// digits, so this test cannot misfire on a real one.
    static func isPlaceholderID(_ id: String) -> Bool {
        let hex = id.replacingOccurrences(of: "-", with: "").lowercased()
        guard hex.count == 32, hex.allSatisfy({ $0.isHexDigit }) else { return false }
        return Set(hex).count <= 2
    }

    /// The descriptor folder ids a pack carries, from its archive
    /// listing: the `<id>` in `descriptors/<id>/…` entries.
    static func descriptorIDs(in archive: Archive) -> [String] {
        var ids: [String] = []
        for entry in archive {
            let parts = entry.path.split(separator: "/").map(String.init)
            guard parts.count >= 2, parts[0].lowercased() == "descriptors" else { continue }
            let id = parts[1]
            if UUID(uuidString: id) != nil, !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// Normalise the just-imported pack stored at `url`, in place.
    /// `siblings` are the other pack files in the imports directory;
    /// an id any of them already uses counts as shared and is swapped
    /// too. Best-effort by design: every failure path returns quietly
    /// with the stored file as it was.
    static func normalizeStoredPack(at url: URL, siblings: [URL]) {
        guard let pack = try? PosterBoardTendie(url: url), !pack.isContainer,
              let archive = try? Archive(url: url, accessMode: .read) else { return }
        let ownIDs = descriptorIDs(in: archive)
        guard !ownIDs.isEmpty else { return }

        var siblingIDs = Set<String>()
        for sibling in siblings where sibling.lastPathComponent != url.lastPathComponent {
            if let other = try? Archive(url: sibling, accessMode: .read) {
                siblingIDs.formUnion(descriptorIDs(in: other).map { $0.lowercased() })
            }
        }

        var swaps: [(old: String, new: String)] = []
        for id in ownIDs where isPlaceholderID(id) || siblingIDs.contains(id.lowercased()) {
            swaps.append((id, UUID().uuidString))
        }
        guard !swaps.isEmpty else { return }

        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("PackIdentity-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            try pack.extract(to: work)

            let descriptorsRoot = work.appendingPathComponent("descriptors", isDirectory: true)
            for swap in swaps {
                let oldDir = descriptorsRoot.appendingPathComponent(swap.old, isDirectory: true)
                let newDir = descriptorsRoot.appendingPathComponent(swap.new, isDirectory: true)
                if fm.fileExists(atPath: oldDir.path) {
                    try fm.moveItem(at: oldDir, to: newDir)
                }
                try replaceID(swap.old, with: swap.new, in: work)
            }

            let staging = fm.temporaryDirectory
                .appendingPathComponent("PackIdentity-\(UUID().uuidString).zip")
            defer { try? fm.removeItem(at: staging) }
            try writeZip(of: work, to: staging)
            _ = try fm.replaceItemAt(url, withItemAt: staging)
            DriftEngine.shared.log("pack identity: \(url.lastPathComponent) — "
                + "导入时已换掉共用 ID："
                + swaps.map { "\($0.old) → \($0.new)" }.joined(separator: "、"))
        } catch {
            DriftEngine.shared.log("pack identity: \(url.lastPathComponent) — "
                + "换 ID 没做成，包按原样保留：\(error.localizedDescription)")
        }
    }

    /// Byte-replace every occurrence of the old id (either case) in
    /// every file under `root`. Same length in, same length out, so
    /// binary plists and archives inside the tree keep their offsets.
    private static func replaceID(_ old: String, with new: String, in root: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let needles = [old.lowercased(), old.uppercased()].map { Data($0.utf8) }
        let replacement = Data(new.utf8)
        for case let file as URL in enumerator {
            if ((try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) { continue }
            guard var data = try? Data(contentsOf: file) else { continue }
            var changed = false
            for needle in needles {
                var out = Data()
                var rest = data
                while let range = rest.range(of: needle) {
                    out.append(rest[..<range.lowerBound])
                    out.append(replacement)
                    rest = rest[range.upperBound...]
                    changed = true
                }
                out.append(rest)
                data = out
            }
            if changed { try data.write(to: file, options: .atomic) }
        }
    }

    /// The same explicit-directory rezip the repair path uses: the pack
    /// reader counts descriptors by their `descriptors/<UUID>/`
    /// entries, so directory entries are written on purpose.
    private static func writeZip(of root: URL, to dest: URL) throws {
        let fm = FileManager.default
        let archive = try Archive(url: dest, accessMode: .create)
        var directories: [String] = []
        var files: [(relative: String, url: URL)] = []
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in enumerator {
                let relative = String(url.path.dropFirst(root.path.count + 1))
                if relative.isEmpty { continue }
                if ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) {
                    directories.append(relative)
                } else {
                    files.append((relative, url))
                }
            }
        }
        for dir in directories.sorted() {
            try archive.addEntry(with: dir + "/", type: .directory,
                                 uncompressedSize: Int64(0)) { _, _ in Data() }
        }
        for file in files.sorted(by: { $0.relative < $1.relative }) {
            try archive.addEntry(with: file.relative, fileURL: file.url)
        }
    }
}
