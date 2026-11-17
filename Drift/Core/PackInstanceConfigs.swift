import Foundation
import ZIPFoundation

/// iOS 17 import-time completion of the per-descriptor instance
/// configuration plists (Grace, 2026-11-17).
///
/// The finding behind it: on iOS 17.0 a kernel-flashed layered-animation
/// wallpaper displays and can be selected, but its animation scene never
/// runs. The pack itself was verified complete, and the same pack
/// animates on iOS 18.3.1 and iOS 27.2 through the same write path. The
/// one file-level difference left standing: a descriptor's versions
/// directory is expected to carry three
/// `com.apple.posterkit.provider.instance.*` plists (quickActions,
/// renderingConfiguration, titleStyleConfiguration). Real packs ship
/// only some of them — the verified case carried complicationLayout
/// and titleStyleConfiguration but no renderingConfiguration and no
/// quickActions. The reference write path force-adds all three from
/// templates (`PosterBoardResources.configConversion`); the kernel
/// path publishes the descriptor as shipped. Newer systems appear to
/// default a missing rendering configuration; iOS 17 apparently does
/// not.
///
/// So, on an iOS 17 device only, importing a pack completes each
/// descriptor's versions directories with whichever of the three
/// templates are missing. Files the pack already carries are never
/// touched, and nothing about the pack changes on any other system.
enum PackInstanceConfigs {

    /// Complete the stored pack in place when it lacks any of the
    /// three instance plists. Returns the reloaded pack when files
    /// were added; nil when the gate is off, nothing was missing, or
    /// the completion failed (best-effort: the pack as imported
    /// always survives).
    static func completeIfNeeded(_ pack: PosterBoardTendie,
                                 deviceVersion: String) -> PosterBoardTendie? {
        guard isIOS17(deviceVersion) else { return nil }
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("PackInstanceConfigs-\(UUID().uuidString)", isDirectory: true)
        let rezipped = fm.temporaryDirectory
            .appendingPathComponent("PackInstanceConfigs-\(UUID().uuidString).tendies")
        defer {
            try? fm.removeItem(at: work)
            try? fm.removeItem(at: rezipped)
        }
        do {
            try pack.extract(to: work)
            let added = addMissingInstanceConfigs(in: work)
            guard added > 0 else { return nil }
            try writeZip(from: work, to: rezipped)
            // Swap the stored file for the completed one, keeping the
            // original until the new file is in place.
            let backup = pack.url.appendingPathExtension("import-backup")
            try? fm.removeItem(at: backup)
            try fm.moveItem(at: pack.url, to: backup)
            do {
                try fm.moveItem(at: rezipped, to: pack.url)
            } catch {
                try? fm.moveItem(at: backup, to: pack.url)
                throw error
            }
            try? fm.removeItem(at: backup)
            AppLog.op("导入：\(pack.name) 在 iOS 17 上已自动补齐缺失的壁纸实例配置（\(added) 份）")
            return try PosterBoardTendie(url: pack.url)
        } catch {
            AppLog.warn("导入：\(pack.name) 的 iOS 17 实例配置自动补齐没成功（\(error.localizedDescription)），先按原包导入")
            return nil
        }
    }

    private static func isIOS17(_ version: String) -> Bool {
        String(version.split(separator: ".").first ?? "") == "17"
    }

    /// Write every missing template into every
    /// `descriptors/<id>/versions/<n>` directory in the extracted
    /// tree, returning how many files were added. Directories are
    /// collected before anything is written — writing into a tree
    /// while enumerating it is not safe.
    private static func addMissingInstanceConfigs(in root: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isDirectoryKey]) else {
            return 0
        }
        var versionDirs: [URL] = []
        for case let url as URL in enumerator {
            guard ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
            else { continue }
            let name = url.lastPathComponent
            guard !name.isEmpty, name.allSatisfy({ $0.isNumber }),
                  url.deletingLastPathComponent().lastPathComponent == "versions"
            else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard relative.split(separator: "/").contains("descriptors") else { continue }
            versionDirs.append(url)
        }
        var added = 0
        for dir in versionDirs {
            for (fileName, data) in PosterBoardResources.configConversion {
                let target = dir.appendingPathComponent(fileName)
                guard !fm.fileExists(atPath: target.path) else { continue }
                if (try? data.write(to: target)) != nil { added += 1 }
            }
        }
        return added
    }

    /// Rezip an extracted tree, the same shape `PackRepair` writes:
    /// directory entries first, then files, both sorted.
    private static func writeZip(from root: URL, to dest: URL) throws {
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
