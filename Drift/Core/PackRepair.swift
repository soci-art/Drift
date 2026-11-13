import Foundation
import ZIPFoundation

/// Wallpaper-pack repair (Grace, 2026-11-12, feedback #207/#210): fixing
/// a pack whose *layout* is wrong, as opposed to the legacy-format
/// conversion, which rewrites a layout that is merely old. The two are
/// offered together — one「壁纸修复」button in the pack detail page —
/// but they are different operations: repair moves files back where the
/// flash looks for them and takes out packaging junk; conversion then
/// runs over the repaired tree under the pack's own conversion answer,
/// exactly as it would at flash time.
///
/// What repair can fix (structure only — never wallpaper content):
///   * a wrapper folder around everything (`Porche-2.1/descriptors/…`),
///     the layout that made such a pack import fine (the counter finds
///     the nested descriptors) yet fail at flash time with "no
///     descriptor found";
///   * descriptor folders sitting at the top level, or a `descriptors/`
///     tree buried under some other prefix;
///   * a pack nested inside the pack (a `.tendies` or `.zip` entry);
///   * packaging junk — `.DS_Store`, `__MACOSX`, `Thumbs.db`,
///     `desktop.ini` — swept as part of any repair.
///
/// What it cannot fix, and says so instead: genuinely missing files and
/// true container-template packs (no descriptors by design — those
/// belong to the sealed restore route, and stay untouched).
///
/// Container packs that DO carry wallpapers became patients with
/// #254 (Grace, 2026-11-13): the wallpapers inside a store snapshot
/// went completely unchecked — the black-bar pack that prompted the
/// item is one. Inside a snapshot the layout is the store's own and
/// already correct, so "repair" there means only the depth-agnostic
/// parts: the junk sweep and the per-descriptor conversion, never a
/// reshuffle and never the nested-pack swap.
///
/// Repair never touches the original: it produces a NEW pack named
/// `name(patched).tendies` in the imports folder, and the detail page
/// shows「已修复」for a pack whose name carries that mark.
enum PackRepair {
    enum Issue: Equatable {
        /// One folder wraps the whole pack: `X/descriptors/…`.
        case wrapper(folder: String)
        /// Descriptor folders at the top level with no `descriptors/`.
        case looseDescriptors
        /// A `descriptors/` tree exists but under a mixed prefix.
        case buriedDescriptors
        /// Another pack archive inside this one.
        case nestedPack(name: String)
        /// Packaging junk files (counted once, however many).
        case junk

        /// Blocking issues stop a flash from finding the wallpapers;
        /// junk alone never does, so junk alone earns no import notice.
        var isBlocking: Bool {
            if case .junk = self { return false }
            return true
        }

        /// The problem in plain words, for logs and the repair result.
        var describe: String {
            switch self {
            case .wrapper(let folder): return "多套了一层文件夹（\(folder)）"
            case .looseDescriptors: return "描述符文件夹没在 descriptors 里面"
            case .buriedDescriptors: return "descriptors 埋在别的层级下面"
            case .nestedPack(let name): return "包里还套着一个包（\(name)）"
            case .junk: return "混进了打包垃圾文件"
            }
        }
    }

    /// Every issue found in a pack, in fix order.
    static func inspect(_ pack: PosterBoardTendie) -> [Issue] {
        guard let archive = try? Archive(url: pack.url, accessMode: .read) else { return [] }
        if pack.isContainer {
            // #254: only a snapshot that actually carries wallpapers
            // is a patient, and inside it only the junk check maps —
            // the layout checks below read a plain pack's top level,
            // and a nested archive inside a snapshot is part of the
            // store copy, not a pack in a pack.
            guard pack.descriptorCount > 0 else { return [] }
            let paths = archive.map { $0.path }
            return inspect(paths: paths).filter { $0 == .junk }
        }
        return inspect(paths: archive.map { $0.path })
    }

    /// The blocking subset — what the post-import notice names a pack for.
    static func blockingIssues(of pack: PosterBoardTendie) -> [Issue] {
        inspect(pack).filter { $0.isBlocking }
    }

    static func inspect(paths rawPaths: [String]) -> [Issue] {
        var issues: [Issue] = []
        let lower = rawPaths.map { $0.lowercased() }

        // Junk: macOS/Windows packaging litter, anywhere in the tree.
        let hasJunk = lower.contains {
            $0.contains("__macosx/")
                || $0.hasSuffix("/.ds_store") || $0 == ".ds_store"
                || $0.hasSuffix("/thumbs.db") || $0.hasSuffix("/desktop.ini")
        }

        // Paths that carry content (junk trees excluded from the layout
        // reading, exactly as the pack reader excludes them).
        let real = lower.filter { !$0.contains("__macosx/") }

        // A nested pack archive.
        if let nested = real.first(where: {
            ($0.hasSuffix(".tendies") || $0.hasSuffix(".zip"))
                && !$0.hasSuffix("/") }) {
            issues.append(.nestedPack(name: nested.split(separator: "/").last.map(String.init) ?? nested))
        }

        let hasTopDescriptors = real.contains { $0.hasPrefix("descriptors/") }
        if !hasTopDescriptors {
            // Every prefix that leads to a descriptors/ tree.
            var prefixes = Set<String>()
            for path in real {
                if let range = path.range(of: "descriptors/") {
                    prefixes.insert(String(path[..<range.lowerBound]))
                }
            }
            let contentPrefixes = prefixes.filter { !$0.isEmpty }
            if contentPrefixes.count == 1, let only = contentPrefixes.first {
                // `X/descriptors/…` and nothing else above it: the clean
                // wrapper case when X/ holds nothing but that tree.
                let folder = only.hasSuffix("/") ? String(only.dropLast()) : only
                let outside = real.filter { !$0.hasPrefix(only) && !$0.hasPrefix("descriptors/") }
                if outside.allSatisfy({ $0 == folder + "/" || $0.hasSuffix(".tendies") || $0.hasSuffix(".zip") }) {
                    issues.append(.wrapper(folder: folder))
                } else {
                    issues.append(.buriedDescriptors)
                }
            } else if contentPrefixes.count > 1 {
                issues.append(.buriedDescriptors)
            } else if prefixes.isEmpty {
                // No descriptors/ anywhere: descriptor folders may be
                // sitting loose at the top (`<UUID>/versions/…`).
                let loose = real.contains {
                    $0.contains("/versions/") && !$0.contains("descriptors")
                }
                if loose { issues.append(.looseDescriptors) }
            }
        }

        if hasJunk { issues.append(.junk) }
        return issues
    }

    /// Whether a pack is one repair produced: the name carries the mark.
    static func isRepaired(_ pack: PosterBoardTendie) -> Bool {
        pack.name.contains("(patched)")
    }

    /// Repair a pack and register the result as a new imported pack.
    /// `deviceVersion` gates the bundled conversion the same way the
    /// flash does (conversion only exists on iOS 27+).
    static func repair(_ pack: PosterBoardTendie, deviceVersion: String,
                       progress: @escaping (Double) -> Void) throws -> PosterBoardTendie {
        let issues = inspect(pack)
        guard !issues.isEmpty else {
            throw DriftError("这个包没查到需要修的毛病。")
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("PackRepair-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // Phase 1: unpack (through the pack's own escape-checked extract).
        try pack.extract(to: work)
        progress(1.0 / 3.0)

        // A pack inside the pack: swap the working tree for the inner
        // archive's contents, then normalise whatever layout it has.
        let hasNested = issues.contains { issue in
            if case .nestedPack(_) = issue { return true }
            return false
        }
        // #254: a container snapshot's tree is never swapped out or
        // reshuffled — its layout is the store's own. Only the junk
        // sweep and the conversion below apply inside it.
        if hasNested && !pack.isContainer {
            if let inner = findNestedArchive(in: work) {
                let innerData = try Data(contentsOf: inner)
                let staging = work.appendingPathComponent("__inner", isDirectory: true)
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                let innerZip = staging.appendingPathComponent("inner.zip")
                try innerData.write(to: innerZip)
                let archive = try Archive(url: innerZip, accessMode: .read)
                let innerTree = staging.appendingPathComponent("tree", isDirectory: true)
                try fm.createDirectory(at: innerTree, withIntermediateDirectories: true)
                let probe = PosterBoardTendieProbe(url: innerZip, archive: archive)
                try probe.extractEntries(to: innerTree)
                // Replace the working tree with the inner one.
                for item in try fm.contentsOfDirectory(atPath: work.path) where item != "__inner" {
                    try? fm.removeItem(at: work.appendingPathComponent(item))
                }
                for item in try fm.contentsOfDirectory(atPath: innerTree.path) {
                    try fm.moveItem(at: innerTree.appendingPathComponent(item),
                                    to: work.appendingPathComponent(item))
                }
                try? fm.removeItem(at: staging)
            }
        }

        // Phase 2: normalise the layout, sweep junk, and run the bundled
        // conversion under the pack's own answer (default: convert).
        // A container snapshot skips the normalising (#254): its
        // descriptors are converted in place by `convertTree`, which
        // walks the whole tree at any depth.
        sweepJunk(in: work)
        if !pack.isContainer { try normalizeLayout(in: work) }
        let wantsConvert = pack.autoConvert ?? true
        if wantsConvert,
           let atLeast27 = PosterBoard.compareVersion(deviceVersion, "27"), atLeast27 >= 0 {
            _ = try PosterBoardConverter.convertTree(work)
        }
        progress(2.0 / 3.0)

        // Phase 3: rezip as name(patched).tendies and register it.
        let dest = try writeRepairedPack(from: work, basedOn: pack)
        progress(1.0)
        DriftEngine.shared.log("pack repair: \(pack.name) -> \(dest.lastPathComponent) "
            + "(\(issues.map { $0.describe }.joined(separator: "、")))")
        var repaired = try PosterBoardTendie(url: dest)
        repaired = repaired.settingPosterType(pack.posterType)
        return repaired
    }

    // MARK: - Layout surgery on an extracted tree

    /// Bring the tree to the one layout the flash reads: `descriptors/`
    /// at the top, nothing structural beside it.
    private static func normalizeLayout(in root: URL) throws {
        let fm = FileManager.default
        let top = try fm.contentsOfDirectory(atPath: root.path)
        if top.contains("descriptors") { return }

        // Wrapper / buried: a folder below holds descriptors/.
        if let holder = findDescriptorsHolder(in: root, depth: 0) {
            let descriptors = holder.appendingPathComponent("descriptors", isDirectory: true)
            try fm.moveItem(at: descriptors, to: root.appendingPathComponent("descriptors", isDirectory: true))
            // The wrapper itself goes: whatever else it held was part of
            // the broken wrapping (top-level files beside a descriptors
            // tree are never read by any path in the app).
            if holder != root {
                var cursor = holder
                while cursor.path != root.path {
                    let siblings = (try? fm.contentsOfDirectory(atPath: cursor.path)) ?? []
                    if !siblings.isEmpty { break }
                    try? fm.removeItem(at: cursor)
                    cursor = cursor.deletingLastPathComponent()
                }
                if holder.deletingLastPathComponent().path == root.path,
                   ((try? fm.contentsOfDirectory(atPath: holder.path)) ?? []).isEmpty {
                    try? fm.removeItem(at: holder)
                }
            }
            return
        }

        // Loose descriptor folders at the top: gather them under
        // descriptors/. A folder counts as a descriptor folder when it
        // holds a versions/ tree (the shape every descriptor has).
        let loose = top.filter { name in
            let dir = root.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return false }
            return fm.fileExists(atPath: dir.appendingPathComponent("versions").path)
        }
        if !loose.isEmpty {
            let descriptors = root.appendingPathComponent("descriptors", isDirectory: true)
            try fm.createDirectory(at: descriptors, withIntermediateDirectories: true)
            for name in loose {
                try fm.moveItem(at: root.appendingPathComponent(name),
                                to: descriptors.appendingPathComponent(name, isDirectory: true))
            }
        }
    }

    /// The shallowest directory (within a few levels) that contains a
    /// `descriptors` folder.
    private static func findDescriptorsHolder(in dir: URL, depth: Int) -> URL? {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        if children.contains("descriptors") { return dir }
        guard depth < 3 else { return nil }
        for name in children where name.lowercased() != "__macosx" {
            let child = dir.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let found = findDescriptorsHolder(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func sweepJunk(in root: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root.path) else { return }
        for case let relative as String in enumerator {
            let lower = relative.lowercased()
            if lower.contains("__macosx") || lower.hasSuffix(".ds_store")
                || lower.hasSuffix("thumbs.db") || lower.hasSuffix("desktop.ini") {
                try? fm.removeItem(at: root.appendingPathComponent(relative))
            }
        }
    }

    private static func findNestedArchive(in root: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root.path) else { return nil }
        for case let relative as String in enumerator {
            let lower = relative.lowercased()
            if (lower.hasSuffix(".tendies") || lower.hasSuffix(".zip")),
               !lower.contains("__macosx") {
                return root.appendingPathComponent(relative)
            }
        }
        return nil
    }

    // MARK: - Rezip

    /// Write the normalised tree out as the new pack file and return its
    /// URL. Directory entries are written explicitly: the pack reader
    /// counts descriptors by their `descriptors/<UUID>/` entries, so a
    /// zip of files alone would read as a pack with no wallpapers.
    private static func writeRepairedPack(from root: URL, basedOn pack: PosterBoardTendie) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: PosterBoardImports.directory, withIntermediateDirectories: true)
        let stem = (pack.name as NSString).deletingPathExtension
        let dest = PosterBoardImports.uniqueDestination(for: "\(stem)(patched).tendies")

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
        return dest
    }
}

/// A minimal stand-in so the nested-archive branch can reuse the same
/// escape-checked extraction rules as `PosterBoardTendie.extract`
/// without constructing a full tendie (the inner archive has not been
/// validated as a pack yet — that happens when the repaired result is
/// read back).
private struct PosterBoardTendieProbe {
    let url: URL
    let archive: Archive

    func extractEntries(to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = destination.standardizedFileURL.path
        for entry in archive {
            let relative = entry.path
            guard !relative.hasPrefix("/"),
                  !relative.split(separator: "/").contains("..") else {
                throw DriftError("内层包里有一个条目会逃出解压目录（\(relative)）。")
            }
            let target = URL(fileURLWithPath: root + "/" + relative)
            guard target.standardizedFileURL.path.hasPrefix(root) else {
                throw DriftError("内层包拒绝写入解压目录之外（\(relative)）。")
            }
            if entry.type == .directory, fm.fileExists(atPath: target.path) { continue }
            _ = try archive.extract(entry, to: target)
        }
    }
}
