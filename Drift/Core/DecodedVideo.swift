import Foundation
import ImageIO
import UIKit

/// One decoded video wallpaper, kept on the phone ready to flash.
///
/// The decode (video page, Grace, 2026-11-22) runs the very same
/// `PosterBoardVideo.generate` an apply would run, but ahead of time
/// and into the library below, so flashing a heavy video no longer
/// pays the decode minutes into a run — the failure that killed
/// restore dry runs after their long pulls. What is stored is the
/// generated descriptor tree itself (the `product` directory), plus
/// a small `meta.json` describing it and a preview image. An apply
/// stages the tree back out of the library (see
/// `PosterBoardVideo.generate(selection:)`); the library copy is
/// never written by an apply, so one decode serves any number of
/// flashes until the user deletes it.
struct DecodedVideoItem: Identifiable, Equatable {
    let id: String
    /// The source video's file name — display only; the source is
    /// not kept.
    let name: String
    /// The playback options the decode was made with. Changing the
    /// options means decoding again: the product embodies them.
    let loop: Bool
    let reverse: Bool
    let foreground: Bool
    let calculationMode: PosterBoardCalculationMode
    /// The decode carried a user framing from the video page's box
    /// (Grace, 2026-11-23): the product's geometry is the box's.
    let framed: Bool
    /// The decode's depth / motion switches (Grace, 2026-11-28),
    /// recorded like the other options so a listed product says
    /// what it carries.
    let depthEffect: Bool
    let motionEffect: Bool
    /// Decoded frame count for a loop; nil for the live-photo shape.
    let frameCount: Int?
    /// Frame size in pixels (0 when it could not be read back).
    let width: Int
    let height: Int
    /// The product tree's total size on disk.
    let byteCount: Int64
    let decodedAt: Date

    /// The item's own directory inside the library root.
    var directory: URL { DecodedVideoLibrary.root.appendingPathComponent(id, isDirectory: true) }
    /// The generated descriptor tree an apply stages.
    var productDirectory: URL { directory.appendingPathComponent("product", isDirectory: true) }
    var previewURL: URL { directory.appendingPathComponent("preview.jpg") }
    var hasPreview: Bool { FileManager.default.fileExists(atPath: previewURL.path) }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file) }

    /// The one-line option summary the lists show, e.g.
    /// 「循环 · 400 帧 · 倒放」.
    var optionsSummary: String {
        var parts: [String] = []
        if loop {
            parts.append("循环")
            if let frameCount { parts.append("\(frameCount) 帧") }
        } else {
            parts.append("非循环（实况照片式）")
        }
        if reverse { parts.append("倒放") }
        if foreground { parts.append("前景层") }
        if framed { parts.append("已调整画面") }
        if depthEffect { parts.append("景深效果") }
        if motionEffect { parts.append("动态效果") }
        return parts.joined(separator: " · ")
    }

    var resolutionText: String? {
        guard width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }

    /// The selection a flash of this item runs: no source video, the
    /// stored product instead, with the decode's options riding
    /// along for the log and the judgement text.
    func makeSelection() -> PosterBoardSelection {
        var selection = PosterBoardSelection()
        selection.preGeneratedVideoDirectory = productDirectory
        selection.preGeneratedVideoName = name
        selection.loop = loop
        selection.reverse = reverse
        selection.foreground = foreground
        selection.calculationMode = calculationMode
        selection.depthEffect = depthEffect
        selection.motionEffect = motionEffect
        return selection
    }
}

/// The decoded-video library: a directory of items under
/// Documents/PosterBoard/DecodedVideos, one folder per item.
///
/// An item only exists once its decode has finished and its
/// `meta.json` is written; a decode interrupted by the app being
/// killed leaves a folder without one, and the launch scan removes
/// such orphans rather than letting a forever-「解码中」 ghost stand
/// (Grace's cleanup ruling, 2026-11-22). The in-flight decode itself
/// is memory-only state for the same reason.
final class DecodedVideoLibrary: ObservableObject {
    static let shared = DecodedVideoLibrary()

    static var root: URL {
        URL.documents.appendingPathComponent("PosterBoard/DecodedVideos", conformingTo: .data)
    }

    @Published private(set) var items: [DecodedVideoItem] = []
    /// The source name of the decode currently running, if any.
    @Published private(set) var decodingName: String?

    private struct Meta: Codable {
        var name: String
        var loop: Bool
        var reverse: Bool
        var foreground: Bool
        var calculationMode: String
        /// Optional on purpose: metas written before the framing
        /// existed have no such key, and a missing key must read as
        /// "not framed", never as an unreadable item.
        var framed: Bool?
        /// Same reasoning: metas written before the depth / motion
        /// switches existed read as both off.
        var depthEffect: Bool?
        var motionEffect: Bool?
        var frameCount: Int?
        var width: Int
        var height: Int
        var byteCount: Int64
        var decodedAt: Date
    }

    init() { reload() }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteCount } }
    var isDecoding: Bool { decodingName != nil }

    /// Re-read the library from disk, dropping folders that carry no
    /// readable meta (interrupted decodes, partial copies).
    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.root, withIntermediateDirectories: true)
        var loaded: [DecodedVideoItem] = []
        let dirs = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(Meta.self, from: data) else {
                try? fm.removeItem(at: dir)
                continue
            }
            loaded.append(DecodedVideoItem(
                id: dir.lastPathComponent,
                name: meta.name,
                loop: meta.loop,
                reverse: meta.reverse,
                foreground: meta.foreground,
                calculationMode: PosterBoardCalculationMode(rawValue: meta.calculationMode) ?? .linear,
                framed: meta.framed ?? false,
                depthEffect: meta.depthEffect ?? false,
                motionEffect: meta.motionEffect ?? false,
                frameCount: meta.frameCount,
                width: meta.width,
                height: meta.height,
                byteCount: meta.byteCount,
                decodedAt: meta.decodedAt))
        }
        items = loaded.sorted { $0.decodedAt > $1.decodedAt }
    }

    /// Decode the page's current pick with its current options and
    /// keep the product. Throws with the decode's own error; a failed
    /// decode leaves nothing behind.
    @MainActor
    func decode(selection: PosterBoardSelection, preview: UIImage?) async throws {
        guard let plan = selection.plan else { throw DriftError("还没选视频。") }
        guard decodingName == nil else { throw DriftError("已经有一个视频在解码了，等它解完再来。") }
        let name = selection.videoDisplayName ?? "Video"
        decodingName = name
        defer { decodingName = nil }

        // Diagnosis (2026-11-26): log the framing THIS decode carries,
        // at the moment it starts. The decode bakes the selection as it
        // stands now — an adjustment made while a long decode runs
        // cannot enter its product — and before this line the log
        // could not show which side of an adjustment a decode fell on.
        if let framing = selection.framing, !framing.isDefault {
            AppLog.op("开始解码：\(name)（带入画面调整：缩放 ×"
                + "\(String(format: "%.3f", framing.scale))、偏移 ("
                + "\(String(format: "%.1f", framing.offsetX)), "
                + "\(String(format: "%.1f", framing.offsetY)))）")
        } else {
            AppLog.op("开始解码：\(name)（没有带入画面调整，按默认居中）")
        }

        let fm = FileManager.default
        let id = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let directory = Self.root.appendingPathComponent(id, isDirectory: true)
        let product = directory.appendingPathComponent("product", isDirectory: true)
        try fm.createDirectory(at: product, withIntermediateDirectories: true)
        do {
            try await PosterBoardVideo.generate(plan: plan, outputDirectory: product) {
                DriftEngine.shared.log($0)
            }
        } catch {
            // A failed decode used to leave no trace in the log —
            // only the popup the user saw (2026-11-28 iPad cases:
            // repeated loop-decode failures were invisible in
            // drift.log, inferable only from starts with no
            // completion). Log it in full before it propagates.
            AppLog.failure("解码失败：\(name)：\(error.localizedDescription)")
            try? fm.removeItem(at: directory)
            throw error
        }

        // Read the product back for the list: frame count and frame
        // size come from the frames themselves, never from a guess.
        var frameCount: Int?
        var width = 0
        var height = 0
        let frames = Self.jpegFiles(under: product)
        if selection.loop {
            frameCount = frames.count
            if let first = frames.first, let size = Self.pixelSize(of: first) {
                width = size.width
                height = size.height
            }
        } else if let thumbnail = selection.thumbnail, let size = Self.pixelSize(of: thumbnail) {
            width = size.width
            height = size.height
        }
        let meta = Meta(name: name,
                        loop: selection.loop,
                        reverse: selection.reverse,
                        foreground: selection.foreground,
                        calculationMode: selection.calculationMode.rawValue,
                        framed: selection.framing.map { !$0.isDefault } ?? false,
                        depthEffect: selection.depthEffect,
                        motionEffect: selection.motionEffect,
                        frameCount: frameCount,
                        width: width,
                        height: height,
                        byteCount: Self.treeSize(of: product),
                        decodedAt: Date())
        let data = try JSONEncoder().encode(meta)
        try data.write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
        if let preview, let jpeg = preview.jpegData(compressionQuality: 0.8) {
            try? jpeg.write(to: directory.appendingPathComponent("preview.jpg"), options: .atomic)
        }
        reload()
        DriftEngine.shared.log("Decoded video kept: \(name) (\(meta.byteCount) bytes, "
            + "\(frameCount.map { "\($0) frame(s)" } ?? "live photo"))")
        // Diagnosis (2026-11-26): the kept product's framing state in
        // the same words as the decode-start line, so a flash of this
        // item later can be matched to the decode that made it.
        AppLog.info("解码完成入库：\(name)，成品带画面调整：\(meta.framed == true ? "是" : "否")"
            + "，景深：\(meta.depthEffect == true ? "开" : "关")、动态：\(meta.motionEffect == true ? "开" : "关")")
    }

    /// Delete the chosen items and their products.
    /// The ids whose stored product was decoded for a different
    /// screen size than this device's — the flash gate would refuse
    /// them, so the list marks them instead of letting the user find
    /// out by tapping. Recomputed by the list views whenever the
    /// items change.
    func staleItemIDs() async -> Set<String> {
        var ids: Set<String> = []
        for item in items {
            if await PosterBoardVideo.productMismatchesCurrentScreen(
                at: item.productDirectory) {
                ids.insert(item.id)
            }
        }
        return ids
    }

    func delete(ids: Set<String>) {
        let fm = FileManager.default
        for item in items where ids.contains(item.id) {
            try? fm.removeItem(at: item.directory)
        }
        reload()
    }

    private static func jpegFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.path < $1.path }
    }

    private static func pixelSize(of image: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(image as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else { return nil }
        return (width, height)
    }

    private static func treeSize(of root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
