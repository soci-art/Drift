import Foundation
import UIKit
import AVFoundation
import ImageIO
import ZIPFoundation

/// Preview pictures for imported wallpaper packs, extracted once at import
/// time and cached as small JPEGs. Purely presentational: nothing here feeds
/// the apply path.
///
/// Picking rule (the user's, from the feature list): a ready-made preview or
/// poster image inside the pack wins. Otherwise the WHOLE picture wins
/// (collection #263, Grace, 2026-11-13): the old rule ranked stills by file
/// size, which for layered (CA) packs crowned a single layer sprite — a
/// black record disc, a cut-out foreground figure — and the list showed a
/// part instead of the wallpaper. Now the biggest opaque still by pixel
/// area (in practice the background plane, the full frame) is the base; a
/// transparent still of comparable area is composited over it, the way the
/// wallpaper itself layers. A video-only descriptor contributes its first
/// frame. A pack with no stills and no readable video yields no preview at
/// all, and the UI draws its gradient placeholder.
enum PosterBoardPreview {
    static var cacheDirectory: URL {
        let dir = URL.documents.appending(path: "PosterBoard/Previews")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let stillExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// A cache key that changes when the pack file is replaced. The
    /// trailing rule version is part of the key on purpose: when the
    /// picking rule changes (#263), every already-cached thumbnail on a
    /// user's phone is stale in the old rule's favour, so the rule bump
    /// re-extracts instead of serving the old pick forever.
    private static func key(for tendie: PosterBoardTendie) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: tendie.url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let base = tendie.url.deletingPathExtension().lastPathComponent
        return "\(base)-\(size)-r2"
    }

    /// One preview per descriptor (in archive order), cached. Empty when the
    /// pack has nothing previewable. Runs synchronously — call off the main
    /// thread.
    static func previews(for tendie: PosterBoardTendie) -> [URL] {
        let key = key(for: tendie)
        let fm = FileManager.default
        let cached = ((try? fm.contentsOfDirectory(atPath: cacheDirectory.path)) ?? [])
            .filter { $0.hasPrefix(key + "-") && $0.hasSuffix(".jpg") }
            .sorted()
        if !cached.isEmpty {
            return cached.map { cacheDirectory.appending(path: $0) }
        }
        guard let made = extract(tendie: tendie, key: key) else { return [] }
        return made
    }

    static func cover(for tendie: PosterBoardTendie) -> URL? {
        previews(for: tendie).first
    }

    // MARK: - Decoded cover cache (collection #267)

    /// Decoded covers, downsampled for list rows and kept in memory.
    /// Rows used to decode the preview JPEG fresh on every appearance —
    /// with a dozen packs that alone made scrolling feel heavy. The
    /// cache key carries the preview file's path (which itself encodes
    /// the pack's name, size and picking-rule version), so a replaced
    /// pack never serves its old cover.
    private static let coverCache = NSCache<NSString, UIImage>()

    static func coverImage(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let cacheKey = "\(url.path)|\(Int(maxPixelSize))" as NSString
        if let hit = coverCache.object(forKey: cacheKey) { return hit }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let image: UIImage?
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            image = UIImage(cgImage: cg)
        } else {
            image = UIImage(data: data)
        }
        if let image { coverCache.setObject(image, forKey: cacheKey) }
        return image
    }

    static func invalidate(for tendie: PosterBoardTendie) {
        coverCache.removeAllObjects()
        let key = key(for: tendie)
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
        where name.hasPrefix(key + "-") {
            try? fm.removeItem(at: cacheDirectory.appending(path: name))
        }
    }

    // MARK: - Extraction

    private struct Candidate {
        var entry: Entry
        var score: Int
    }

    private static func extract(tendie: PosterBoardTendie, key: String) -> [URL]? {
        guard let archive = try? Archive(url: tendie.url, accessMode: .read) else { return nil }

        // Group stills and videos by descriptor folder, archive order kept.
        var order: [String] = []
        var stills: [String: [Candidate]] = [:]
        var videos: [String: [Candidate]] = [:]
        var looseStills: [Candidate] = []

        for entry in archive where entry.type == .file {
            let path = entry.path
            let lower = path.lowercased()
            let ext = (path as NSString).pathExtension.lowercased()
            let isStill = stillExtensions.contains(ext)
            let isVideo = videoExtensions.contains(ext)
            guard isStill || isVideo else { continue }

            var score = Int(entry.uncompressedSize)
            for keyword in ["preview", "poster", "thumbnail", "hero", "cover"] where lower.contains(keyword) {
                score += 1_000_000_000
                break
            }
            let candidate = Candidate(entry: entry, score: score)

            let marker = lower.contains("descriptor/") ? "descriptor/"
                : (lower.contains("descriptors/") ? "descriptors/" : nil)
            guard let marker,
                  let tail = lower.components(separatedBy: marker).dropFirst().first,
                  !tail.isEmpty else {
                if isStill { looseStills.append(candidate) }
                continue
            }
            let descriptor = tail.components(separatedBy: "/").first ?? tail
            if !order.contains(descriptor) { order.append(descriptor) }
            if isStill { stills[descriptor, default: []].append(candidate) }
            if isVideo { videos[descriptor, default: []].append(candidate) }
        }

        var results: [URL] = []
        let groups: [(String, [Candidate], [Candidate])] =
            order.map { ($0, stills[$0] ?? [], videos[$0] ?? []) }
        let effective: [(String, [Candidate], [Candidate])] = groups.isEmpty && !looseStills.isEmpty
            ? [("loose", looseStills, [])]
            : groups

        for (index, group) in effective.enumerated() {
            var image: UIImage?
            if !group.1.isEmpty {
                image = pickStillImage(archive: archive, stills: group.1)
            }
            if image == nil, let video = group.2.max(by: { $0.score < $1.score }) {
                image = firstFrame(archive: archive, entry: video.entry)
            }
            guard let image, let data = thumbnailJPEG(image) else { continue }
            let out = cacheDirectory.appending(path: "\(key)-\(index).jpg")
            do {
                try data.write(to: out)
                results.append(out)
            } catch { continue }
        }
        return results.isEmpty ? nil : results
    }

    private static func entryData(archive: Archive, entry: Entry) -> Data? {
        var data = Data()
        do {
            _ = try archive.extract(entry) { data.append($0) }
        } catch { return nil }
        return data
    }

    /// The #263 pick for one descriptor's stills: a ready-made preview /
    /// poster file keeps the crown; otherwise the whole frame wins over
    /// any single part, and a comparable transparent part is composited
    /// onto the background instead of being shown alone.
    ///
    /// Two passes over the archive on purpose: the first reads each
    /// still's pixel size and alpha from its image header (cheap, no
    /// full decode) and keeps nothing; only the one or two winners are
    /// extracted again and decoded.
    private static func pickStillImage(archive: Archive, stills: [Candidate]) -> UIImage? {
        struct Meta {
            let candidate: Candidate
            let pixelSize: CGSize
            let hasAlpha: Bool
            let fileBytes: Int
            var area: CGFloat { pixelSize.width * pixelSize.height }
        }
        var metas: [Meta] = []
        for candidate in stills {
            guard let data = entryData(archive: archive, entry: candidate.entry) else { continue }
            let info = imageInfo(data)
            metas.append(Meta(candidate: candidate, pixelSize: info.size,
                              hasAlpha: info.hasAlpha, fileBytes: data.count))
        }
        guard !metas.isEmpty else { return nil }
        func load(_ meta: Meta) -> UIImage? {
            entryData(archive: archive, entry: meta.candidate.entry)
                .flatMap { UIImage(data: $0) }
        }
        // A named preview/poster is the pack author saying "this is the
        // cover" — it wins outright, as it always did.
        let keywords = ["preview", "poster", "thumbnail", "hero", "cover"]
        let named = metas.filter { meta in
            keywords.contains { meta.candidate.entry.path.lowercased().contains($0) }
        }
        if let best = named.max(by: { $0.fileBytes < $1.fileBytes }) {
            return load(best)
        }
        let byArea: (Meta, Meta) -> Bool = { a, b in
            a.area != b.area ? a.area < b.area : a.fileBytes < b.fileBytes
        }
        let background = metas.filter { !$0.hasAlpha }.max(by: byArea)
        let foreground = metas.filter { $0.hasAlpha }.max(by: byArea)
        // A transparent layer sized like the frame belongs ON the frame,
        // not in place of it. A small transparent asset (a strip, a logo)
        // never displaces the background.
        if let background, let foreground, foreground.area >= background.area * 0.5,
           let bgImage = load(background), let fgImage = load(foreground) {
            return composite(fgImage, over: bgImage)
        }
        if let background, let image = load(background) { return image }
        if let foreground, let image = load(foreground) { return image }
        return nil
    }

    /// Pixel size and alpha presence from the image header alone.
    private static func imageInfo(_ data: Data) -> (size: CGSize, hasAlpha: Bool) {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = props[kCGImagePropertyPixelHeight] as? NSNumber {
            let alpha = (props[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
            return (CGSize(width: width.doubleValue, height: height.doubleValue), alpha)
        }
        if let image = UIImage(data: data) {
            let alphaInfo = image.cgImage?.alphaInfo
            let alpha = alphaInfo != nil && alphaInfo != .none
                && alphaInfo != .noneSkipFirst && alphaInfo != .noneSkipLast
            return (CGSize(width: image.size.width * image.scale,
                           height: image.size.height * image.scale), alpha)
        }
        return (.zero, false)
    }

    /// Draw the foreground layer over the background at the background's
    /// own size — CA plane images are canvas-sized, so filling the frame
    /// is how the wallpaper itself composites them.
    private static func composite(_ foreground: UIImage, over background: UIImage) -> UIImage {
        let size = background.size
        guard size.width > 0, size.height > 0 else { return foreground }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            background.draw(in: CGRect(origin: .zero, size: size))
            foreground.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func firstFrame(archive: Archive, entry: Entry) -> UIImage? {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "drift-preview-\(UUID().uuidString)")
            .appendingPathExtension((entry.path as NSString).pathExtension)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            _ = try archive.extract(entry, to: tmp)
        } catch { return nil }
        let asset = AVURLAsset(url: tmp)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 1280)
        guard let cg = try? generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600),
                                                  actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Downscale to a list-friendly portrait thumbnail and encode as JPEG.
    private static func thumbnailJPEG(_ image: UIImage) -> Data? {
        let maxWidth: CGFloat = 360
        guard image.size.width > maxWidth else { return image.jpegData(compressionQuality: 0.8) }
        let scale = maxWidth / image.size.width
        let size = CGSize(width: maxWidth, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.8)
    }
}
