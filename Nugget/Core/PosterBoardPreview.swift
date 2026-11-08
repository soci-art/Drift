import Foundation
import UIKit
import AVFoundation
import ZIPFoundation

/// Preview pictures for imported wallpaper packs, extracted once at import
/// time and cached as small JPEGs. Purely presentational: nothing here feeds
/// the apply path.
///
/// Picking rule (the user's, from the feature list): a ready-made preview or
/// poster image inside the pack wins; otherwise the largest still image in
/// each descriptor; a video-only descriptor contributes its first frame. A
/// pack with no stills and no readable video yields no preview at all, and
/// the UI draws its gradient placeholder — the About page says so.
enum PosterBoardPreview {
    static var cacheDirectory: URL {
        let dir = URL.documents.appending(path: "PosterBoard/Previews")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let stillExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// A cache key that changes when the pack file is replaced.
    private static func key(for tendie: PosterBoardTendie) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: tendie.url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let base = tendie.url.deletingPathExtension().lastPathComponent
        return "\(base)-\(size)"
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

    static func invalidate(for tendie: PosterBoardTendie) {
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
            if let best = group.1.max(by: { $0.score < $1.score }) {
                image = imageFromEntry(archive: archive, entry: best.entry)
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

    private static func imageFromEntry(archive: Archive, entry: Entry) -> UIImage? {
        var data = Data()
        do {
            _ = try archive.extract(entry) { data.append($0) }
        } catch { return nil }
        return UIImage(data: data)
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
