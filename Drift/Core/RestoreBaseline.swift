import Foundation

/// The restore route's retained download:
/// `Documents/PosterBoard/Recovery/<udid>/Baseline`.
///
/// `PosterBoardSnapshot.retainBaseline` keeps the first pre-apply copy of the
/// PosterBoard domain. It is deliberately never deleted automatically, because
/// it is the only local copy of the bytes that existed before the first
/// restore. What it is **not** is a one-tap rollback package: its `Manifest.db`
/// is host-built, it carries no `Manifest.plist`/`Info.plist`/`Status.plist`,
/// and no code reads it back. This type only measures and clears that
/// directory; the fetch scratch, the restore package and every other backup
/// live in different trees and are never touched here.
enum RestoreBaseline {
    struct Presence: Sendable, Equatable {
        /// Number of per-device `Baseline` directories found.
        var copies: Int
        /// Sum of the logical file sizes under those directories.
        var bytes: Int64

        /// No retained baseline directory at all. A zero-byte baseline still
        /// counts as present, so the cleanup action can remove the empty tree.
        var isEmpty: Bool { copies == 0 }
    }

    struct ClearResult: Sendable {
        let before: Presence
        let after: Presence

        var freedBytes: Int64 { max(0, before.bytes - after.bytes) }
    }

    /// `Documents/PosterBoard/Recovery` — the parent of every per-device
    /// baseline. `PosterBoardBackup.fetch` creates the baseline at
    /// `Documents/PosterBoard/Recovery/<udid>/Baseline`; this is the only
    /// directory this type ever deletes.
    static var recoveryRoot: URL {
        URL.documents.appendingPathComponent("PosterBoard/Recovery", isDirectory: true)
    }

    static func measure() -> Presence {
        let directories = baselineDirectories()
        var total: Int64 = 0
        for directory in directories {
            total += size(of: directory)
        }
        return Presence(copies: directories.count, bytes: total)
    }

    /// Delete every retained baseline and report what was there before and
    /// after. A failure stops the loop and is surfaced; no partial result is
    /// reported as success.
    static func clear() throws -> ClearResult {
        let before = measure()
        guard before.copies > 0 else {
            return ClearResult(before: before, after: before)
        }
        let fm = FileManager.default
        for directory in baselineDirectories() {
            do {
                try fm.removeItem(at: directory)
            } catch {
                throw DriftError("清理恢复副本失败：\(error.localizedDescription)")
            }
        }
        return ClearResult(before: before, after: measure())
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func baselineDirectories() -> [URL] {
        let fm = FileManager.default
        guard let devices = try? fm.contentsOfDirectory(
            at: recoveryRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        return devices.compactMap { device -> URL? in
            guard (try? device.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                return nil
            }
            let baseline = device.appendingPathComponent("Baseline", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: baseline.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            return baseline
        }
    }

    private static func size(of directory: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}
