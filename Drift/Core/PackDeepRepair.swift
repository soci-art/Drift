import Foundation
import ZIPFoundation
import AVFoundation
import ImageIO
import CoreGraphics

/// Deep repair (Grace, 2026-11-12, feedback #253–#255 / #258–#261):
/// the second button on the pack detail page, beside — and separate
/// from — the structural「壁纸修复」. Structural repair fixes a pack's
/// *layout*; deep repair fixes a pack's *fit for this device*. It never
/// touches the original: the result is a new pack named
/// `name(deep).tendies` in the imports folder.
///
/// What it does, in order:
///
///   1. **Takes stock first (#260).** Before changing anything it
///      checks what the structural repair already did to this pack:
///      a `(patched)` name is that repair's product, and when the
///      pre-repair original is still in the list, inspecting it names
///      exactly what was fixed. Structural problems still standing are
///      reported, not silently worked around — deep repair builds on
///      the structural repair's result, and refuses to run while a
///      blocking structural issue remains (that is the other button's
///      job, and its output would otherwise inherit the breakage).
///   2. **Re-fits the canvas.** A pack authored for another device's
///      screen (an iPhone 15 Pro pack on a 16 Pro Max, a phone pack
///      on an iPad) is rebuilt at THIS device's canvas through the
///      converter, which re-derives every plane document at the new
///      size — layers come out aligned to the one canvas by
///      construction. That is the black-bar and cut-off cure.
///   3. **Supplements the home-screen side** at declaration level:
///      the same conversion pass makes sure the pack declares its
///      lock-and-home payload, so a lock-only pack stops leaving the
///      home screen blank.
///   4. **Fixes videos**: a clip whose rotation metadata would play
///      it sideways, or in a codec the system does not read, is
///      re-exported with the rotation baked in and a standard codec;
///      an oversized clip is scaled down to the device's pixels.
///   5. **Right-sizes and normalises stills**: a full-frame image
///      bigger than the device's pixels is scaled to them (slimming
///      the pack), and an image in an outlandish colour space is
///      re-encoded as sRGB so it stops rendering grey or wrong.
///   6. **Rebuilds a broken preview**: a zero-byte or unreadable
///      in-pack preview image is regenerated from the pack's own
///      largest still.
///
/// The canvas comes from the caller (the view reads the live screen
/// on the main actor); the engine itself never touches UIKit.
enum PackDeepRepair {

    /// This device's canvas, in points plus the pixel scale — the
    /// shape the converter already takes.
    struct Canvas: Equatable {
        var width: Int
        var height: Int
        var scale: Int
        var pixelWidth: Int { width * scale }
        var pixelHeight: Int { height * scale }
        var label: String { "\(width)×\(height)" }
    }

    /// What the stock-take found, worded for the user. `fixes` are the
    /// plain-language lines of what a repair run would do.
    struct Report {
        /// The pack is the structural repair's product.
        var priorRepairMark = false
        /// What the structural repair fixed, when its original could
        /// be inspected; empty when there is nothing to say.
        var priorRepairLines: [String] = []
        /// Blocking structural problems still standing — deep repair
        /// will not run until the other button has dealt with these.
        var structuralBlocking: [String] = []
        /// The fixes a run would apply, one plain line each.
        var fixes: [String] = []
        var canApply: Bool { !fixes.isEmpty && structuralBlocking.isEmpty }
    }

    /// Whether a pack is one deep repair produced: the name's mark.
    static func isDeepRepaired(_ pack: PosterBoardTendie) -> Bool {
        pack.name.contains("(deep)")
    }

    // MARK: - Stock-take (#260 first, then the fit checks)

    static func analyze(_ pack: PosterBoardTendie, canvas: Canvas) async -> Report {
        var report = Report()
        // #254 (Grace, 2026-11-13): a container pack that actually
        // carries wallpapers is a patient now. Its descriptors sit
        // deep inside the store snapshot, and every check below
        // already walks the whole extracted tree — the guard that
        // used to turn container packs away unread is why a 15 Pro
        // store snapshot on a 16 Pro Max reported「没有查到需要修复
        // 的毛病」while wearing a 393×852 canvas. A container
        // TEMPLATE (no descriptors by design) still returns at once.
        guard !(pack.isContainer && pack.descriptorCount == 0) else { return report }

        // What the structural repair already did to this pack.
        report.priorRepairMark = PackRepair.isRepaired(pack)
        if report.priorRepairMark {
            let stem = pack.name.replacingOccurrences(of: "(patched)", with: "")
            if let original = PosterBoardImports.load().first(where: { $0.name == stem }) {
                report.priorRepairLines = PackRepair.inspect(original).map { $0.describe }
            }
        }
        let structural = PackRepair.inspect(pack)
        report.structuralBlocking = structural.filter { $0.isBlocking }.map { $0.describe }

        // The fit checks need the extracted tree.
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("PackDeepCheck-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            try pack.extract(to: work)
            let scan = await scanTree(work, canvas: canvas)
            report.fixes = scan.fixLines
        } catch {
            // An unextractable pack has nothing deep repair can say.
        }
        return report
    }

    /// The tree-level findings, shared by the stock-take and the run
    /// itself so the two can never disagree about what needs doing.
    private struct Scan {
        var fixLines: [String] = []
        var convertDescriptors: [URL] = []
        var videoFixes: [(url: URL, bakeRotation: Bool, downscale: Bool, line: String)] = []
        var imageFixes: [(url: URL, targetPixels: (Int, Int)?, normalizeColor: Bool, line: String)] = []
        var previewFixes: [(preview: URL, source: URL, line: String)] = []
        var needsSkeletonRename = false

        /// Whether the run has anything at all to do.
        var canApplyWork: Bool {
            !convertDescriptors.isEmpty || !videoFixes.isEmpty
                || !imageFixes.isEmpty || !previewFixes.isEmpty
        }
    }

    private static func scanTree(_ root: URL, canvas: Canvas) async -> Scan {
        var scan = Scan()
        let fm = FileManager.default

        // Descriptors: canvas fit, legacy form, home declaration.
        for descriptorDir in PosterBoardConverter.descriptorDirectories(under: root) {
            guard let wallpaperDir = PosterBoardConverter.findWallpaperDir(descriptorDir) else { continue }
            let plist = PosterBoardConverter.readPlist(
                wallpaperDir.appendingPathComponent("Wallpaper.plist"))
            let packCanvas = PosterBoardConverter.parseLogicalScreenClass(
                plist["logicalScreenClass"] as? String) ?? planeDocSize(wallpaperDir)
            let legacy = PosterBoardConverter.isLegacyDescriptor(descriptorDir)
            let assets = plist["assets"] as? [String: Any]
            let missingHome = assets?["lockAndHome"] == nil

            var reasons: [String] = []
            if let packCanvas, (packCanvas.width, packCanvas.height) != (canvas.width, canvas.height) {
                reasons.append("画布是 \(packCanvas.width)×\(packCanvas.height)，这台设备是 \(canvas.label)，对不上")
            }
            if legacy { reasons.append("还是老式布局，要按新布局重出") }
            if missingHome { reasons.append("主屏那份没声明，设到主屏会是空白") }
            if !reasons.isEmpty {
                scan.convertDescriptors.append(descriptorDir)
                scan.needsSkeletonRename = true
                scan.fixLines.append("「\(descriptorDir.lastPathComponent)」"
                    + reasons.joined(separator: "；")
                    + "——按这台设备的 \(canvas.label) 重新出，各层一起对齐"
                    + (missingHome ? "，并按锁屏内容补上主屏那份" : ""))
            }

            // A broken in-pack preview riding with this descriptor.
            if let previewFix = brokenPreview(in: descriptorDir) {
                scan.previewFixes.append(previewFix)
                scan.fixLines.append(previewFix.line)
            }
        }

        // Videos and stills, wherever they sit in the tree.
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else {
            return scan
        }
        for case let file as URL in enumerator {
            let ext = file.pathExtension.lowercased()
            if ["mov", "mp4", "m4v"].contains(ext) {
                if let fix = await videoFix(for: file, canvas: canvas) {
                    scan.videoFixes.append(fix)
                    scan.fixLines.append(fix.line)
                }
            } else if ["png", "jpg", "jpeg", "heic"].contains(ext) {
                if let fix = imageFix(for: file, canvas: canvas) {
                    scan.imageFixes.append(fix)
                    scan.fixLines.append(fix.line)
                }
            }
        }
        return scan
    }

    /// The declared document size of a descriptor's first plane, from
    /// its index.xml — the canvas fallback when Wallpaper.plist does
    /// not carry a logicalScreenClass.
    private static func planeDocSize(_ wallpaperDir: URL) -> (width: Int, height: Int, scale: Int)? {
        for planeDir in PosterBoardConverter.planeDirs(wallpaperDir) {
            let index = PosterBoardConverter.readPlist(planeDir.appendingPathComponent("index.xml"))
            if let w = (index["documentWidth"] as? NSNumber)?.intValue,
               let h = (index["documentHeight"] as? NSNumber)?.intValue, w > 0, h > 0 {
                return (w, h, 3)
            }
        }
        return nil
    }

    /// A preview file inside a descriptor that is empty or unreadable,
    /// paired with the still it can be rebuilt from.
    private static func brokenPreview(in descriptorDir: URL) -> (preview: URL, source: URL, line: String)? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: descriptorDir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        var previews: [URL] = []
        var stills: [(url: URL, bytes: Int)] = []
        for case let file as URL in enumerator {
            let ext = file.pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "heic"].contains(ext) else { continue }
            let bytes = ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
            if file.lastPathComponent.lowercased().contains("preview") {
                previews.append(file)
            } else {
                stills.append((file, bytes))
            }
        }
        for preview in previews {
            let bytes = ((try? preview.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
            var readable = false
            if bytes > 0, let source = CGImageSourceCreateWithURL(preview as CFURL, nil) {
                readable = CGImageSourceGetCount(source) > 0
            }
            if !readable, let source = stills.max(by: { $0.bytes < $1.bytes })?.url {
                return (preview, source, "预览图「\(preview.lastPathComponent)」坏了，从正片重做一张")
            }
        }
        return nil
    }

    // MARK: - Video check

    /// What one video needs, if anything: rotation baked from its
    /// metadata (a sideways clip), a codec the system reads, and a
    /// size no larger than the device's pixels.
    private static func videoFix(for file: URL, canvas: Canvas)
        async -> (url: URL, bakeRotation: Bool, downscale: Bool, line: String)? {
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let natural = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        guard natural.width > 0, natural.height > 0 else { return nil }

        let rotated = transform != .identity
        let displayed = CGRect(origin: .zero, size: natural).applying(transform)
        let shownWidth = abs(displayed.width), shownHeight = abs(displayed.height)
        let oversize = shownWidth > CGFloat(canvas.pixelWidth) * 1.05
            || shownHeight > CGFloat(canvas.pixelHeight) * 1.05

        var codecOdd = false
        if let descriptions = try? await track.load(.formatDescriptions) {
            for description in descriptions {
                let subtype = CMFormatDescriptionGetMediaSubType(description)
                let code = withUnsafeBytes(of: subtype.bigEndian) {
                    String(bytes: $0, encoding: .ascii) ?? ""
                }.trimmingCharacters(in: .whitespaces)
                if !["avc1", "hvc1", "hev1", "mp4v"].contains(code) { codecOdd = true }
            }
        }
        guard rotated || oversize || codecOdd else { return nil }
        var parts: [String] = []
        if rotated { parts.append("方向是歪的（靠标记转正，系统不认）") }
        if codecOdd { parts.append("格式太偏门") }
        if oversize { parts.append("比这台设备的画面还大") }
        return (file, rotated || codecOdd, oversize,
                "视频「\(file.lastPathComponent)」\(parts.joined(separator: "、"))——重新导出摆正、转成系统认的格式"
                    + (oversize ? "并缩到设备尺寸" : ""))
    }

    // MARK: - Still check

    /// What one still needs, if anything: a full-frame image larger
    /// than the device's pixels is scaled to them; an image outside
    /// the colour spaces the system renders faithfully (sRGB, Display
    /// P3) is re-encoded as sRGB.
    private static func imageFix(for file: URL, canvas: Canvas)
        -> (url: URL, targetPixels: (Int, Int)?, normalizeColor: Bool, line: String)? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = props[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = props[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth > 0, pixelHeight > 0 else { return nil }

        let imageAspect = Double(pixelWidth) / Double(pixelHeight)
        let canvasAspect = Double(canvas.width) / Double(canvas.height)
        let fullFrame = abs(imageAspect - canvasAspect) / canvasAspect < 0.12
            && pixelWidth >= canvas.pixelWidth / 2
        let oversize = fullFrame
            && (pixelWidth > canvas.pixelWidth || pixelHeight > canvas.pixelHeight)

        var normalizeColor = false
        if let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceSubsampleFactor: 8] as CFDictionary),
           let spaceName = image.colorSpace?.name {
            let fine: [CFString] = [CGColorSpace.sRGB, CGColorSpace.displayP3]
            if !fine.contains(spaceName) { normalizeColor = true }
        }
        guard oversize || normalizeColor else { return nil }
        var parts: [String] = []
        if oversize { parts.append("比设备画面大一圈，白占地方") }
        if normalizeColor { parts.append("颜色格式太偏门，可能显错色或发灰") }
        return (file, oversize ? (canvas.pixelWidth, canvas.pixelHeight) : nil, normalizeColor,
                "图片「\(file.lastPathComponent)」\(parts.joined(separator: "、"))——"
                    + (oversize ? "缩到设备尺寸" : "")
                    + (oversize && normalizeColor ? "并" : "")
                    + (normalizeColor ? "转成标准颜色" : ""))
    }

    // MARK: - The run

    /// Deep-repair a pack and register the result as a new imported
    /// pack. Returns the new pack and the lines of what was done.
    static func repair(_ pack: PosterBoardTendie, canvas: Canvas,
                       progress: @escaping (Double) -> Void) async throws -> (pack: PosterBoardTendie, done: [String]) {
        let preflight = PackRepair.inspect(pack).filter { $0.isBlocking }
        guard preflight.isEmpty else {
            throw DriftError("这个包还有结构问题没修："
                + preflight.map { $0.describe }.joined(separator: "、")
                + "。先用「壁纸修复」把结构修好，再来深度修复。")
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("PackDeepRepair-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        try pack.extract(to: work)
        progress(0.1)
        let scan = await scanTree(work, canvas: canvas)
        guard scan.canApplyWork else {
            throw DriftError("这个包没查到需要深度修复的地方。")
        }

        var done: [String] = []
        var skipped: [String] = []

        // Canvas re-fit through the converter (layers aligned by
        // construction; the home-screen declaration rides along).
        if !scan.convertDescriptors.isEmpty {
            let screen = (width: canvas.width, height: canvas.height, scale: canvas.scale)
            for descriptorDir in scan.convertDescriptors {
                do {
                    _ = try PosterBoardConverter.convertDescriptor(descriptorDir, screen: screen)
                    done.append("「\(descriptorDir.lastPathComponent)」已按 \(canvas.label) 重新出")
                } catch {
                    skipped.append("「\(descriptorDir.lastPathComponent)」没转成：\(error.localizedDescription)")
                }
            }
            if scan.needsSkeletonRename {
                _ = PosterBoardConverter.renameDescriptorsToSkeleton(work)
            }
        }
        progress(0.45)

        for fix in scan.videoFixes {
            do {
                try await exportVideoFix(fix.url, canvas: canvas, downscale: fix.downscale)
                done.append("视频「\(fix.url.lastPathComponent)」已重新导出")
            } catch {
                skipped.append("视频「\(fix.url.lastPathComponent)」没导出成：\(error.localizedDescription)")
            }
        }
        progress(0.7)

        for fix in scan.imageFixes {
            if rewriteStill(fix.url, targetPixels: fix.targetPixels) {
                done.append("图片「\(fix.url.lastPathComponent)」已处理")
            } else {
                skipped.append("图片「\(fix.url.lastPathComponent)」没处理成")
            }
        }
        for fix in scan.previewFixes {
            if rebuildPreview(at: fix.preview, from: fix.source) {
                done.append("预览图「\(fix.preview.lastPathComponent)」已重做")
            } else {
                skipped.append("预览图「\(fix.preview.lastPathComponent)」没重做成")
            }
        }
        progress(0.85)

        guard !done.isEmpty else {
            throw DriftError("深度修复没做成。"
                + (skipped.isEmpty ? "" : skipped.joined(separator: "；")))
        }

        let dest = try writeDeepPack(from: work, basedOn: pack)
        progress(1.0)
        DriftEngine.shared.log("deep repair: \(pack.name) -> \(dest.lastPathComponent) "
            + "(\(done.joined(separator: "、")))")
        var repaired = try PosterBoardTendie(url: dest)
        repaired = repaired.settingPosterType(pack.posterType)
        PosterBoardPreview.invalidate(for: repaired)
        return (repaired, done + skipped.map { "没做成——\($0)" })
    }

    /// Re-export one video with its rotation baked into the frames and
    /// (when asked) scaled down to the device's pixels, in a codec the
    /// system reads. The file keeps its name and container kind, so
    /// every reference to it stays true.
    private static func exportVideoFix(_ file: URL, canvas: Canvas, downscale: Bool) async throws {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw DriftError("读不到视频轨道")
        }
        let natural = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)

        let shown = CGRect(origin: .zero, size: natural).applying(preferred)
        var final = preferred.concatenating(
            CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
        var renderSize = CGSize(width: abs(shown.width), height: abs(shown.height))
        if downscale {
            let factor = min(1, min(CGFloat(canvas.pixelWidth) / renderSize.width,
                                    CGFloat(canvas.pixelHeight) / renderSize.height))
            if factor < 1 {
                final = final.concatenating(CGAffineTransform(scaleX: factor, y: factor))
                renderSize = CGSize(width: renderSize.width * factor,
                                    height: renderSize.height * factor)
            }
        }
        // Encoders want even dimensions.
        renderSize = CGSize(width: max(2, (Int(renderSize.width) / 2) * 2),
                            height: max(2, (Int(renderSize.height) / 2) * 2))

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(final, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw DriftError("建不了导出")
        }
        let fileType: AVFileType
        switch file.pathExtension.lowercased() {
        case "mp4": fileType = .mp4
        case "m4v": fileType = .m4v
        default: fileType = .mov
        }
        let staging = file.deletingLastPathComponent()
            .appendingPathComponent("deepfix-\(UUID().uuidString).\(file.pathExtension)")
        session.outputURL = staging
        session.outputFileType = fileType
        session.videoComposition = composition
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: session.error ?? DriftError("视频导出失败"))
                default:
                    break
                }
            }
        }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: staging)
    }

    /// Rewrite one still: drawn into an sRGB context at the target
    /// size (or its own, when only the colour needs normalising), so
    /// one pass both right-sizes and colour-normalises. Written back
    /// in its own format; the name — and every reference — stays.
    private static func rewriteStill(_ file: URL, targetPixels: (Int, Int)?) -> Bool {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let targetWidth = targetPixels?.0 ?? image.width
        let targetHeight = targetPixels?.1 ?? image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: targetWidth, height: targetHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let drawn = context.makeImage() else { return false }

        let type: CFString
        switch file.pathExtension.lowercased() {
        case "jpg", "jpeg": type = "public.jpeg" as CFString
        case "heic": type = "public.heic" as CFString
        default: type = "public.png" as CFString
        }
        let staging = file.deletingLastPathComponent()
            .appendingPathComponent("deepfix-\(UUID().uuidString).\(file.pathExtension)")
        guard let destination = CGImageDestinationCreateWithURL(staging as CFURL, type, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, drawn,
                                   [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return false }
        do {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: staging)
            return true
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return false
        }
    }

    /// Replace a broken preview with a still rendered from the pack's
    /// own largest image, at picker size, in the preview's format.
    private static func rebuildPreview(at preview: URL, from source: URL) -> Bool {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return false
        }
        let type: CFString
        switch preview.pathExtension.lowercased() {
        case "jpg", "jpeg": type = "public.jpeg" as CFString
        case "heic": type = "public.heic" as CFString
        default: type = "public.png" as CFString
        }
        let staging = preview.deletingLastPathComponent()
            .appendingPathComponent("deepfix-\(UUID().uuidString).\(preview.pathExtension)")
        guard let destination = CGImageDestinationCreateWithURL(staging as CFURL, type, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        do {
            _ = try FileManager.default.replaceItemAt(preview, withItemAt: staging)
            return true
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return false
        }
    }

    /// The deep-repaired pack, written the same way the structural
    /// repair writes its product — explicit directory entries, the
    /// layout the pack reader counts descriptors by.
    private static func writeDeepPack(from root: URL, basedOn pack: PosterBoardTendie) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: PosterBoardImports.directory, withIntermediateDirectories: true)
        let stem = (pack.name as NSString).deletingPathExtension
        let dest = PosterBoardImports.uniqueDestination(for: "\(stem)(deep).tendies")

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
