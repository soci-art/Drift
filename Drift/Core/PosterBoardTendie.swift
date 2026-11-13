import Foundation
import ZIPFoundation

/// An imported `.tendies` wallpaper pack, as the reference reads it.
///
/// A port of `src/tweaks/posterboard/tendie_file.py`. The file is a ZIP whose
/// entries decide three things the UI and the apply both need:
///
///   * how many descriptors it carries — the reference caps a selection at 10
///     (`PosterboardTweak.verify_tendie`), because PosterBoard's picker gets
///     unusable past that;
///   * whether it carries a `container/` — a full data-store snapshot rather
///     than a descriptor, which is a different delivery path (`recursive_add`'s
///     `container` branch);
///   * whether that container carries the PosterBoard **database** itself, in
///     which case the reference calls it `unsafe_container` and tells the user
///     they may need a full wallpaper reset first.  That is not a scare: a
///     database stitched from a stale snapshot lands on the device with row
///     sets the live store does not have.
///
/// The counting rules are the reference's, including the two case-sensitivity
/// quirks in it — `__MACOSX` is matched on the lowercased name, the database
/// file name on the raw one.  Both are reproduced rather than tidied, because
/// either could be load-bearing for a pack in the wild.
/// Which PosterBoard extension a descriptor pack belongs to.
///
/// A pack that ships a bare `descriptors/<UUID>` tree does not say which
/// extension owns it — the path on the device does, and the pack has no copy of
/// that path. The reference asks the user at import time and remembers the
/// answer (`TendieItem.posterType`, `TendiesModel.swift`), because the injection
/// target is built from it:
/// `…/PRBPosterExtensionDataStore/<version>/Extensions/<extensionBundleId>/descriptors`.
///
/// Getting this wrong does not fail loudly. A descriptor injected under the
/// wrong extension id lands in a folder PosterBoard's provider never reads, so
/// the wallpaper simply does not appear.
enum PosterBoardPosterType: String, CaseIterable, Identifiable, Codable {
    case collections
    case suggestedPhotos
    case mercury
    case container

    var id: String { rawValue }

    /// The reference's `TendiePosterType.extensionBundleId`.
    var extensionBundleID: String {
        switch self {
        case .collections: return "com.apple.WallpaperKit.CollectionsPoster"
        case .suggestedPhotos: return "com.apple.PhotosUIPrivate.PhotosPosterProvider"
        case .mercury: return "com.apple.MercuryPoster"
        case .container: return "com.apple.PosterBoard"
        }
    }

    var label: String {
        switch self {
        case .collections: return String(localized: "Collections")
        case .suggestedPhotos: return String(localized: "Suggested Photos")
        case .mercury: return String(localized: "Mercury")
        case .container: return String(localized: "App Container")
        }
    }

    /// One plain-language line on where a wallpaper of this kind ends up,
    /// shown under the type picker in the pack detail. The segmented labels
    /// are PosterBoard's own provider names — "Mercury" says nothing to
    /// anyone who has not read this file — so each kind also carries its
    /// explanation in ordinary words (Grace, 2026-11-09).
    var blurb: String {
        switch self {
        case .collections: return String(localized: "Appears in the wallpaper gallery's Collections section, alongside Apple's own featured wallpapers. Right for most packs — and the safe pick when unsure.")
        case .suggestedPhotos: return String(localized: "Appears in the gallery section that suggests wallpapers made from your own photo library.")
        case .mercury: return String(localized: "Apple's dynamic wallpapers — the kind with floating layers and depth motion. Older WWDC22-format packs are usually this kind.")
        case .container: return String(localized: "Ships the wallpaper store's whole contents, database included — the kind most likely to scramble your existing wallpapers. Only for packs that actually are containers.")
        }
    }

    var systemImage: String {
        switch self {
        case .collections: return "paintpalette.fill"
        case .suggestedPhotos: return "photo.fill"
        case .mercury: return "sparkles"
        case .container: return "shippingbox.fill"
        }
    }

    /// A `container/` snapshot is its own kind of pack, so it defaults to the
    /// type named after it rather than to Collections.
    static func defaultForContainer(_ isContainer: Bool) -> PosterBoardPosterType {
        isContainer ? .container : .collections
    }
}

struct PosterBoardTendie: Identifiable, Hashable {
    let id = UUID()
    /// Where the pack lives in this app's container, so it survives a launch.
    let url: URL
    /// The file name the reference would show (`os.path.basename`).
    let name: String
    let descriptorCount: Int
    let isContainer: Bool
    let isUnsafeContainer: Bool
    /// Which extension this pack's descriptors are injected under. User-chosen,
    /// because the pack does not carry it; see `PosterBoardPosterType`.
    var posterType: PosterBoardPosterType
    /// The user's answer to the legacy-format prompt: `true` convert, `false`
    /// install as is, `nil` never asked.
    ///
    /// Upstream keeps this on the tendie object (`TendieFile.auto_convert`) and
    /// honours it per extracted pack in `apply_tweak`, which is why each pack is
    /// extracted into its own folder. Here the pack is a file on disk that is
    /// re-read from its archive on every launch, so the answer is kept in
    /// `PosterBoardPreferences.autoConvertAnswers` by file name and read back
    /// here.
    var autoConvert: Bool?

    /// The exact name `TendieFile` looks for inside a `container/` pack.
    static let databaseEntryName = "PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"

    init(url: URL) throws {
        self.url = url
        self.name = url.lastPathComponent

        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw DriftError("\(url.lastPathComponent) 不是可读的 .tendies 文件："
                + "归档：\(error.localizedDescription)")
        }

        var descriptors = 0
        var container = false
        var unsafeContainer = false
        // The provider this pack is *for*, read off its own paths, and nil when
        // nothing said. The reference does this in the same walk
        // (`TendiesEngine.swift`: a `/container/` path sets `.container`, then a
        // descriptor path overrides it with mercury or photos). Order matters
        // there and it is preserved here: the container rule runs on the way down
        // and the descriptor rule on the way into the payload, so a snapshot
        // ends up as the provider it snapshots rather than as `.container`.
        var detected: PosterBoardPosterType?
        for entry in archive {
            let path = entry.path
            let lower = path.lowercased()
            if lower.contains("__macosx/") { continue }
            if lower.contains("container") {
                container = true
                // Raw case, as in the reference: the entry it is looking for is
                // spelled exactly this way inside a container dump.
                if path.contains(Self.databaseEntryName) { unsafeContainer = true }
            }
            if lower.contains("/container/") || lower.hasSuffix("/container") {
                detected = .container
            }
            // `descriptor/` and `descriptors/` are mutually exclusive as
            // substrings (`"descriptor/"` is not in `"descriptors/…"`), and the
            // reference tests them in that order — so the second is only reached
            // by the plural spelling.
            let marker = lower.contains("descriptor/") ? "descriptor/"
                : (lower.contains("descriptors/") ? "descriptors/" : nil)
            guard let marker else { continue }
            if lower.contains("video") || lower.contains("photos") {
                detected = .suggestedPhotos
            } else if lower.contains("mercury") {
                detected = .mercury
            } else if detected != .container {
                detected = .collections
            }
            if let tail = lower.components(separatedBy: marker).dropFirst().first {
                // One level under the marker, and a directory: `UUID/`.
                if tail.filter({ $0 == "/" }).count == 1 && tail.hasSuffix("/") {
                    descriptors += 1
                }
            }
        }

        if descriptors == 0 && !container {
            throw DriftError("\(url.lastPathComponent) 里既没有描述文件也没有"
                + "container — it does not look like a .tendies pack.")
        }
        self.descriptorCount = descriptors
        self.isContainer = container
        self.isUnsafeContainer = unsafeContainer
        self.posterType = PosterBoardPreferences.posterTypes[url.lastPathComponent]
            ?? detected ?? .defaultForContainer(container)
        self.autoConvert = PosterBoardPreferences.autoConvertAnswers[url.lastPathComponent]
    }

    /// Remember the legacy-format answer for this pack, and return it with the
    /// answer set. Written immediately, like `settingPosterType`.
    func settingAutoConvert(_ convert: Bool) -> PosterBoardTendie {
        var copy = self
        copy.autoConvert = convert
        var answers = PosterBoardPreferences.autoConvertAnswers
        answers[url.lastPathComponent] = convert
        PosterBoardPreferences.autoConvertAnswers = answers
        return copy
    }

    /// The families of the pre-iOS 27 packages inside this pack, read straight out
    /// of the archive.
    ///
    /// Empty means nothing legacy is in there, or the pack cannot be opened.  The
    /// pack was already opened successfully in `init`, so a throw here is a real
    /// I/O failure — which is why `legacyConvertPrompt` swallows it and asks
    /// nothing: an archive that cannot be read cannot be converted either, so
    /// there is no question worth putting to the user, and the apply then fails on
    /// the same read and says so.
    func legacyFamilies() throws -> [String] {
        try PosterBoardConverter.legacyFamilies(ofPack: url)
    }

    /// What to ask the user about this pack, or nil when there is nothing to ask.
    ///
    /// `PosterboardTweak._ask_legacy_convert`'s gates in its own order: the
    /// setting, the device (iOS 27 is where the format changed), then whether the
    /// archive holds a pre-27 package at all. The one addition is
    /// `autoConvert != nil`, which is what "already answered" means — upstream
    /// gets that for free because the flag only exists while the object that was
    /// asked about is still in memory.
    func legacyConvertPrompt(deviceVersion: String) -> LegacyConvertPrompt? {
        guard PosterBoardPreferences.autoConvertLegacy, autoConvert == nil else { return nil }
        guard let atLeast27 = PosterBoard.compareVersion(deviceVersion, "27"), atLeast27 >= 0
        else { return nil }
        guard let families = try? legacyFamilies(), !families.isEmpty else { return nil }
        return LegacyConvertPrompt(pack: self, families: families)
    }

    /// Remember a poster type for this pack, and return the pack with it set.
    ///
    /// The pack is re-read from its archive on every launch, so the answer cannot
    /// live in the pack — it goes to the one store that outlives a launch, keyed
    /// by file name. Losing it is not catastrophic: the type falls back to
    /// Collections. A wallpaper that silently stops appearing is, so it is written
    /// the moment it changes rather than at Apply time.
    func settingPosterType(_ type: PosterBoardPosterType) -> PosterBoardTendie {
        var copy = self
        copy.posterType = type
        var types = PosterBoardPreferences.posterTypes
        types[url.lastPathComponent] = type
        PosterBoardPreferences.posterTypes = types
        return copy
    }

    /// A one-line description for the row, including the reference's warning.
    var summary: String {
        if isContainer {
            return isUnsafeContainer
                ? "container, carries the database — upstream says reset all wallpapers first"
                : "container snapshot"
        }
        return descriptorCount == 1 ? "1 descriptor" : "\(descriptorCount) descriptors"
    }

    /// Unpack into `destination`, exactly as `TendieFile.extract` does.
    ///
    /// Every entry is written under `destination` and a path that would escape
    /// it is refused: the reference hands the archive straight to
    /// `zipfile.extractall`, which is safe only because CPython sanitises entry
    /// names — reproducing that with `URL(fileURLWithPath:)` needs the check
    /// spelled out.
    func extract(to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = destination.standardizedFileURL.path

        let archive = try Archive(url: url, accessMode: .read)
        for entry in archive {
            let relative = entry.path
            guard !relative.hasPrefix("/"),
                  !relative.split(separator: "/").contains("..") else {
                throw DriftError("\(name)：归档里有一个条目会逃出以下目录："
                    + "extraction directory (\(relative)).")
            }
            let target = URL(fileURLWithPath: root + "/" + relative)
            guard target.standardizedFileURL.path.hasPrefix(root) else {
                throw DriftError("\(name)：拒绝把 \(relative) 写到以下位置之外："
                    + "extraction directory.")
            }
            // A directory entry can legitimately be repeated or already exist
            // (some zips carry both `a/` and `a/b`), and the reference's
            // `extractall` merges them.
            if entry.type == .directory, fm.fileExists(atPath: target.path) { continue }
            _ = try archive.extract(entry, to: target)
        }
    }
}

/// A pack waiting on the Convert / Install-as-is answer.
///
/// The reference's `prompt_legacy_convert` returns a `bool` straight into
/// `TendieFile.auto_convert`; there is nothing to keep on screen afterwards.  A
/// SwiftUI alert is presented from the view, so the pending question is a value
/// the view holds, and the pack it is about travels with it.
struct LegacyConvertPrompt: Identifiable {
    let pack: PosterBoardTendie
    /// The pre-iOS 27 families found inside, as the dialog spells them:
    /// `", ".join(sorted(set(families)))`. Normalised here rather than in the
    /// views, because the run log prints the same list.
    let families: [String]

    /// Two packages of the same family produce one entry, the way the reference's
    /// `set()` does.
    init(pack: PosterBoardTendie, families: [String]) {
        self.pack = pack
        self.families = Array(Set(families)).sorted()
    }

    var id: String { pack.url.lastPathComponent }

    /// The dialog's `setText`: "<b>pack</b> uses the legacy A, B format."
    var title: String {
        String(localized: "\(pack.name) uses the legacy \(families.joined(separator: ", ")) format.")
    }

    /// The dialog's informative text. Feedback #22 rewrote it: the old
    /// "depth effect" wording understated the stakes — an unconverted
    /// legacy pack on iOS 27 does not look flat, it never appears at all.
    static var message: String {
        String(localized: "iOS 27's wallpaper library cannot read this legacy (WWDC22) layout at all: installed as-is, the wallpaper would never appear — no error, just nothing. Converting rewrites the pack into the modern layout iOS 27 reads. Pick “Install as is” to push the original files untouched instead.")
    }

    /// `Convert (may break the wallpaper)` — the reference's accepted-role button,
    /// and its default.
    static var convertTitle: String { String(localized: "Convert (may break the wallpaper)") }
    /// `Install as is` — the reference's rejected-role button.
    static var asIsTitle: String { String(localized: "Install as is") }
}

/// The conversion explanation, worded once and shown wherever the question
/// comes up — the pack detail page, the About page, and (in its shorter
/// form above) the convert prompt itself (feedback #22: the three places
/// must not drift into three different stories).
enum LegacyConversionCopy {
    /// Why conversion exists at all: the WWDC22 layout is unreadable to
    /// iOS 27's store, and the failure mode is silence, not an error.
    static var why: String {
        String(localized: "Legacy packs use the WWDC22 layout. iOS 27's wallpaper library cannot read that layout: installed unconverted, a pack raises no error and simply never appears. Converting rewrites the pack into the modern layout iOS 27 reads.")
    }

    /// Which systems need it: the major version only.
    static var versions: String {
        String(localized: "Whether conversion is needed depends only on the major version: every iOS 26 release reads legacy packs as they are — no conversion, and the question is never asked; every iOS 27 release and later needs the conversion. Minor versions and build numbers do not matter. Below iOS 26 is not supported.")
    }
}

/// The imported packs, as files in this app's container.
///
/// The reference keeps its tendie list in memory (`tweaks[TweakID.PosterBoard]`)
/// and loses it on exit.  A pack is tens of megabytes that the user picked by
/// hand through the document picker, so here the **directory is the list**: a
/// pack is imported once, stays on disk, and the page shows what it finds.  That
/// is a deliberate divergence, and the only one in this area — nothing about
/// what reaches the device changes.
enum PosterBoardImports {
    static var directory: URL {
        URL.documents.appendingPathComponent("PosterBoard/Imports", conformingTo: .data)
    }

    /// A name that is not taken yet, so a second import of the same pack does
    /// not overwrite the first.
    static func uniqueDestination(for name: String) -> URL {
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        return directory.appendingPathComponent(AfcFileExplorer.uniqueName(name, against: existing),
                                                conformingTo: .data)
    }

    /// Import one picked file and return every pack that joined the
    /// list because of it.
    ///
    /// Copies rather than references: the picker's URL is security-scoped
    /// and its access ends with the callback, so a pack kept by reference
    /// would be unreadable on the next apply.
    ///
    /// Collection #269 (Grace, 2026-11-13): users kept arriving with the
    /// right wallpaper wearing the wrong name, or one layer of zip too
    /// many. The rules now:
    ///   * the stored name always ends in `.tendies`, whatever the pick
    ///     was called — the content is validated, not the suffix;
    ///   * a zip that IS a pack (its contents are the wallpaper) imports
    ///     like any pack; a zip that is a BAG (`.tendies` files inside,
    ///     possibly in a folder) imports each pack it carries;
    ///   * rar / 7z cannot be opened here at all and are refused with
    ///     words that say what to do instead — never a silent failure;
    ///   * a pack with structural problems is repaired right here, the
    ///     way tapping 「壁纸修复」 would — nobody has to know there was
    ///     anything to fix.
    static func importPicked(from source: URL) throws -> [PosterBoardTendie] {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        if let format = archiveFormat(of: source) {
            throw DriftError("这个文件是 \(format) 压缩包，Drift 打不开这种格式。"
                + "请先把它解压开，再导入里面的 .tendies 文件；或者直接导入 .tendies，不要隔着这一层压缩。")
        }
        let data = try unwrappedPackData(from: source)
        if let format = archiveFormat(ofData: data) {
            throw DriftError("这个文件是 \(format) 压缩包，Drift 打不开这种格式。"
                + "请先把它解压开，再导入里面的 .tendies 文件；或者直接导入 .tendies，不要隔着这一层压缩。")
        }

        let started = Date()
        AppLog.op("导入：收到 \(source.lastPathComponent)（\(data.count) 字节）")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The file itself is a pack, whatever it was called.
        let packName = normalizedName(for: source.lastPathComponent)
        var packError: Error?
        do {
            let tendie = try storePack(data: data, named: packName)
            let result = finishImport(tendie)
            AppLog.timing("导入 \(packName)", since: started)
            return result
        } catch {
            packError = error
        }

        // A bag: pull every .tendies out of it and import each one.
        let inners = innerPacks(in: data)
        if !inners.isEmpty {
            var result: [PosterBoardTendie] = []
            for inner in inners {
                do {
                    let tendie = try storePack(data: inner.data,
                                                named: normalizedName(for: inner.name))
                    result.append(contentsOf: finishImport(tendie))
                } catch {
                    AppLog.warn("导入：压缩包里的 \(inner.name) 不是能用的壁纸包，跳过")
                }
            }
            if !result.isEmpty {
                AppLog.op("导入：从 \(source.lastPathComponent) 里取出 \(result.count) 个壁纸包")
                AppLog.timing("导入压缩包 \(source.lastPathComponent)", since: started)
                return result
            }
        }

        // Neither a pack nor a bag of packs: the validator's own words.
        throw packError ?? DriftError("这个文件不是能用的壁纸包。")
    }

    /// rar / 7z by file name — the two formats this app cannot open.
    private static func archiveFormat(of source: URL) -> String? {
        switch source.pathExtension.lowercased() {
        case "rar": return "RAR"
        case "7z": return "7Z"
        default: return nil
        }
    }

    /// The same check by magic bytes, for archives wearing a wrong name.
    private static func archiveFormat(ofData data: Data) -> String? {
        if data.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return "7Z" }
        if data.starts(with: [0x52, 0x61, 0x72, 0x21]) { return "RAR" }
        return nil
    }

    /// The stored name: the pick's own name with its suffix corrected
    /// to `.tendies` (#269). Content is validated separately — this is
    /// only about what the pack is called in the list.
    private static func normalizedName(for fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return (base.isEmpty ? "壁纸包" : base) + ".tendies"
    }

    /// Write one pack's bytes under `name` and validate them. A failed
    /// validation removes the file again — nothing half-imported is
    /// left behind for the next launch to trip over.
    private static func storePack(data: Data, named name: String) throws -> PosterBoardTendie {
        let destination = uniqueDestination(for: name)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw DriftError("无法把 \(name) 拷贝进应用：" + error.localizedDescription)
        }
        do {
            return try PosterBoardTendie(url: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Every `.tendies` inside a zip's data, wherever in the folder
    /// tree they sit. Empty when the data is not a readable zip or the
    /// zip carries no packs.
    private static func innerPacks(in data: Data) -> [(name: String, data: Data)] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("drift-bag-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? data.write(to: tmp)) != nil,
              let archive = try? Archive(url: tmp, accessMode: .read) else { return [] }
        var found: [(name: String, data: Data)] = []
        for entry in archive where entry.type == .file
            && entry.path.lowercased().hasSuffix(".tendies") {
            var bytes = Data()
            do {
                _ = try archive.extract(entry) { bytes.append($0) }
            } catch { continue }
            if bytes.starts(with: [0x50, 0x4B]) {
                found.append((name: (entry.path as NSString).lastPathComponent, data: bytes))
            }
        }
        return found
    }

    /// The steps every stored pack goes through before it joins the
    /// list, returning the pack plus anything the steps produced.
    private static func finishImport(_ tendie: PosterBoardTendie) -> [PosterBoardTendie] {
        // #259 (Grace, 2026-11-12): a shared placeholder descriptor id
        // is swapped for a fresh one right here, at import — the pack
        // that joins the list is already clean. Best-effort: any
        // failure keeps the pack exactly as imported.
        PackIdentity.normalizeStoredPack(at: tendie.url, siblings: load().map(\.url))
        let clean = (try? PosterBoardTendie(url: tendie.url)) ?? tendie
        var result = [clean]
        // #269: structural problems are repaired at import too, the
        // same repair the detail flow offered by hand. Best-effort —
        // a failed repair keeps the pack and the log says so; the
        // caller still checks for blocking issues afterwards.
        if !PackRepair.inspect(clean).isEmpty {
            let version = DeviceIdentityMonitor.shared.current.version.isEmpty
                ? WorseQueryEscape.processVersion
                : DeviceIdentityMonitor.shared.current.version
            if let repaired = try? PackRepair.repair(clean, deviceVersion: version,
                                                     progress: { _ in }) {
                // #291 (Grace, 2026-11-13): an import-time repair is
                // invisible in the list — the repaired pack REPLACES
                // the imported one under its own file name, so the
                // list holds exactly one pack, wearing the original
                // name with no「已修复」mark. Only a repair the user
                // runs by hand (detail page / list actions) still
                // produces a separate `(patched)` pack. The swap is
                // best-effort like the repair itself: if the file
                // cannot be moved over, the repaired pack joins the
                // list the old way and the original stays.
                let fm = FileManager.default
                if repaired.url != clean.url,
                   (try? fm.removeItem(at: clean.url)) != nil,
                   (try? fm.moveItem(at: repaired.url, to: clean.url)) != nil,
                   let swapped = try? PosterBoardTendie(url: clean.url) {
                    AppLog.op("导入：\(clean.name) 查到结构问题，已自动修复并替换原包（列表只留修好的这一份）")
                    result = [swapped]
                } else {
                    AppLog.op("导入：\(clean.name) 查到结构问题，已自动修复出 \(repaired.name)")
                    result.append(repaired)
                }
            } else {
                AppLog.warn("导入：\(clean.name) 查到结构问题，这次自动修复没成功")
            }
        }
        return result
    }

    /// The pack's bytes, unwrapped first if they arrive encoded.
    ///
    /// Some packs circulate as base64 *text* wearing a `.tendies` name — the
    /// whole ZIP is in there, encoded (verified on Grace's real packs,
    /// 2026-11-09: the text decodes to a well-formed pack, while the archive
    /// reader alone reports a missing end-of-central-directory and refuses
    /// it). What is stored is always the plain ZIP, so every later reader —
    /// unpack, previews, apply — sees the one true form.
    ///
    /// The order matters: a normal pack costs one prefix test, and a decode
    /// is accepted only when it lands on a ZIP header. A file that is
    /// neither passes through untouched and keeps the archive reader's own
    /// error, so a genuinely bad pack fails exactly as it did before.
    private static func unwrappedPackData(from source: URL) throws -> Data {
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw DriftError("无法把 \(source.lastPathComponent) 拷贝进应用："
                + error.localizedDescription)
        }
        if data.starts(with: [0x50, 0x4B]) { return data } // "PK": a plain ZIP
        if let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters),
           decoded.starts(with: [0x50, 0x4B]) {
            return decoded
        }
        return data
    }

    /// Every imported pack, newest last, in file-name order.
    static func load() -> [PosterBoardTendie] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { try? PosterBoardTendie(url: directory.appendingPathComponent($0)) }
    }

    static func remove(_ tendie: PosterBoardTendie) {
        try? FileManager.default.removeItem(at: tendie.url)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The reference's cap (`PosterboardTweak.verify_tendie`).
    static let descriptorLimit = 10
}
