import Foundation

/// The app's clearable cache (collection #172, Grace's feature): only
/// things the app can regenerate — wallpaper preview images, the
/// catalog/preview cache, the poster-store fetch scratch, the log
/// files and the last diagnostics dump.
///
/// NEVER cleared here, by design: the pairing file, the receipts, the
/// apply history, settings, imported wallpaper packs, and the local
/// backups (those have their own delete entry in Settings). Clearing
/// receipts or history as "cache" would break same-pack dedup and
/// the management page's flash-channel identification.
///
/// Logs are truncated, not deleted: the sinks keep writing to the
/// same path, and truncation frees the space immediately. The file
/// sink notices the size change on its next flush and reopens at
/// the new end (#323), so a clear never leaves a hole behind the
/// lines written after it.
enum AppCache {
    struct Breakdown {
        var previews = 0
        var catalogCache = 0
        var fetchScratch = 0
        var logs = 0
        /// Update IPAs the checker downloaded (#196): they live in
        /// Documents/Downloads, outside every other cache directory,
        /// and re-download on demand — cache by any honest definition.
        var updates = 0
        var total: Int { previews + catalogCache + fetchScratch + logs + updates }
    }

    private static var downloadsDirectory: URL {
        URL.documents.appendingPathComponent("Downloads", isDirectory: true)
    }

    private static var previewDirectories: [URL] {
        [PosterBoard.thumbnailDirectory,
         URL.documents.appendingPathComponent("PosterBoard/Previews", isDirectory: true)]
    }

    private static var catalogCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wallpaper_cache", isDirectory: true)
    }

    private static var fetchScratchDirectory: URL {
        URL.documents.appendingPathComponent("PosterBoardFetch", isDirectory: true)
    }

    private static var logFiles: [URL] {
        [AppPaths.appLog, AppPaths.rustLog, AppPaths.rustLogArchive, AppPaths.diagnostics]
    }

    static func measure() -> Breakdown {
        var result = Breakdown()
        for dir in previewDirectories { result.previews += directorySize(dir) }
        result.catalogCache = directorySize(catalogCacheDirectory)
        result.fetchScratch = directorySize(fetchScratchDirectory)
        for file in logFiles { result.logs += fileSize(file) }
        result.updates = directorySize(downloadsDirectory)
        return result
    }

    /// Clears the measured set and returns the bytes freed (measured
    /// again after, so the number is what actually went away).
    @discardableResult
    static func clear() -> Int {
        let before = measure().total
        let fm = FileManager.default
        for dir in previewDirectories { removeContents(of: dir) }
        // The preview type keeps in-memory memos of what was in that
        // directory — they go with it (cleanup round, 2026-11-13).
        PosterBoardPreview.noteCacheCleared()
        removeContents(of: catalogCacheDirectory)
        removeContents(of: fetchScratchDirectory)
        removeContents(of: downloadsDirectory)
        for file in logFiles {
            if file == AppPaths.diagnostics {
                try? fm.removeItem(at: file)
            } else {
                truncate(file)
            }
        }
        return max(0, before - measure().total)
    }

    private static func directorySize(_ url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total = 0
        for case let file as URL in enumerator {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    private static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
    }

    private static func removeContents(of directory: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for item in items {
            try? fm.removeItem(at: directory.appendingPathComponent(item))
        }
    }

    private static func truncate(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path),
              let handle = try? FileHandle(forWritingTo: file) else { return }
        try? handle.truncate(atOffset: 0)
        try? handle.close()
    }

    static func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
