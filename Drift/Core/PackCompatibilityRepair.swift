import Foundation
import ZIPFoundation
import CryptoKit
import Darwin

/// Import-time PosterBoard metadata adaptation.
///
/// The first bundled template is intentionally narrow: it was extracted from
/// two independent CollectionsPoster system descriptors on iOS 18.3.1
/// (22D72), Store generation 61. Both samples had byte-identical
/// galleryOptions and configurableOptions. We only add absent files; existing
/// wallpaper-specific metadata is never overwritten. Other OS builds/providers
/// are left untouched until a matching system sample is verified.
enum PackCompatibilityRepair {
    enum Result {
        case skipped(String)
        case adapted(name: String, changes: [String])
        case needsReview(String)
    }

    private static let targetSystemVersion = "18.3.1"
    private static let targetBuild = "22D72"
    private static let galleryPath = "com.apple.posterkit.provider.contents.galleryOptions"
    private static let configurablePath = ".com.apple.posterkit.provider.contents.configurableOptions.plist"

    private static let galleryOptions = Data(base64Encoded:
        "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGkCwwqK1UkbnVsbN8QDw0ODxAREhMUFRYXGBkaGxwdHh8gHBwcHB8fHx0oKV8QGXNwb2tlbk5hbWVMb2NhbGl6YXRpb25LZXlccGhvdG9TdWJ0eXBlXxAXZmVhdHVyZWRDb25maWRlbmNlTGV2ZWxfECJhbGxvd3NTeXN0ZW1TdWdnZXN0ZWRDb21wbGljYXRpb25zXxAaZGlzcGxheU5hbWVMb2NhbGl6YXRpb25LZXlfEBRtb2R1bGFyQ29tcGxpY2F0aW9uc18QHmRlc2NyaXB0aXZlVGV4dExvY2FsaXphdGlvbktleV8QEmlubGluZUNvbXBsaWNhdGlvbl8QHW1vZHVsYXJMYW5kc2NhcGVDb21wbGljYXRpb25zVGhlcm9fEBhzaG91bGRTaG93QXNTaHVmZmxlU3RhY2tfECJvbmx5RWxpZ2libGVGb3JNYWRlRm9yRm9jdXNTZWN0aW9uVWZvY3VzXxAtYWxsb3dzU3lzdGVtU3VnZ2VzdGVkQ29tcGxpY2F0aW9uc0luTGFuZHNjYXBlViRjbGFzc4AAEAAQAQiAAoAAgACAAIAACAgICYADYny+kAnSLC0uL1okY2xhc3NuYW1lWCRjbGFzc2VzXxAhQVRYUG9zdGVyRGVzY3JpcHRvckdhbGxlcnlPcHRpb25zojAxXxAhQVRYUG9zdGVyRGVzY3JpcHRvckdhbGxlcnlPcHRpb25zWE5TT2JqZWN0AAgAEQAaACQAKQAyADcASQBMAFEAUwBYAF4AfwCbAKgAwgDnAQQBGwE8AVEBcQF2AZEBtgG8AewB8wH1AfcB+QH6AfwB/gIAAgICBAIFAgYCBwIIAgoCDwIUAh8CKAJMAk8CcwAAAAAAAAIBAAAAAAAAADIAAAAAAAAAAAAAAAAAAAJ8"
    )!

    private static let configurableOptions = Data(base64Encoded:
        "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGqCwwdHiIoKRczN1UkbnVsbNgNDg8QERITFBUWFxgZGhsbXxAgcHJlZmVycmVkSG9tZVNjcmVlbkNvbmZpZ3VyYXRpb25WJGNsYXNzXxAaYW1iaWVudFN1cHBvcnRlZERhdGFMYXlvdXRfEBpkaXNwbGF5TmFtZUxvY2FsaXphdGlvbktleVlsdW1pbmFuY2VUcm9sZV8QH3ByZWZlcnJlZFRpbWVGb250Q29uZmlndXJhdGlvbnNfEBRwcmVmZXJyZWRUaXRsZUNvbG9yc4AGgAkQAIAAgAWAAoADgANfEBZQUlBvc3RlclJvbGVMb2NrU2NyZWVu0h8OICFaTlMub2JqZWN0c6CABNIjJCUmWiRjbGFzc25hbWVYJGNsYXNzZXNXTlNBcnJheaIlJ1hOU09iamVjdCM/4AAAAAAAANUqKw4sLS4YMBgyXnByZWZlcnJlZFN0eWxlXxAUcHJlZmVycmVkU29saWRDb2xvcnNfEBdwcmVmZXJyZWRHcmFkaWVudENvbG9yc18QHWFsbG93c01vZGlmeWluZ0xlZ2liaWxpdHlCbHVygAeAAIAIgAAJ0iMkNDVfEClQUlBvc3RlckRlc2NyaXB0b3JIb21lU2NyZWVuQ29uZmlndXJhdGlvbqI2J18QKVBSUG9zdGVyRGVzY3JpcHRvckhvbWVTY3JlZW5Db25maWd1cmF0aW9u0iMkODlfEBtQUlBvc3RlckNvbmZpZ3VyYWJsZU9wdGlvbnOiOidfEBtQUlBvc3RlckNvbmZpZ3VyYWJsZU9wdGlvbnMACAARABoAJAApADIANwBJAEwAUQBTAF4AZAB1AJgAnwC8ANkA4wDoAQoBIQEjASUBJwEpASsBLQEvATEBSgFPAVoBWwFdAWIBbQF2AX4BgQGKAZMBngGtAcQB3gH+AgACAgIEAgYCBwIMAjgCOwJnAmwCigKNAAAAAAAAAgEAAAAAAAAAOwAAAAAAAAAAAAAAAAAAAqs="
    )!

    private static let expectedGallerySHA256 = "ade19ada42b747fb44234af6f21f816b156b28fea6ceacf5e8347627e883e855"
    private static let expectedConfigurableSHA256 = "4875e6ec384cf681452be0216fe3fc27fb84475fcd1f0d12f994b490c7b77158"

    static func adaptIfNeeded(_ pack: PosterBoardTendie) throws -> Result {
        guard pack.posterType == .collections else {
            return .skipped("非 CollectionsPoster 类型，不套用该模板")
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)" == targetSystemVersion,
              kernelBuildVersion() == targetBuild else {
            return .skipped("当前系统为 iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)（\(kernelBuildVersion())），尚无匹配的已验证模板")
        }
        guard SHA256.hash(data: galleryOptions).map({ String(format: "%02x", $0) }).joined() == expectedGallerySHA256,
              SHA256.hash(data: configurableOptions).map({ String(format: "%02x", $0) }).joined() == expectedConfigurableSHA256,
              galleryOptions.count == 768, configurableOptions.count == 833 else {
            throw DriftError("内置系统模板校验失败，已停止适配。")
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("PackCompatibility-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try pack.extract(to: work)

        let descriptors = PosterBoardConverter.descriptorDirectories(under: work)
        guard !descriptors.isEmpty else { return .skipped("没有可适配的 descriptor") }

        var changes: [String] = []
        var review: [String] = []
        for descriptor in descriptors {
            let versions = descriptor.appendingPathComponent("versions", isDirectory: true)
            let versionNames = (try? fm.contentsOfDirectory(atPath: versions.path)) ?? []
            for versionName in versionNames.sorted() {
                let contents = versions.appendingPathComponent(versionName, isDirectory: true)
                    .appendingPathComponent("contents", isDirectory: true)
                let hasWallpaperBundle = ((try? fm.contentsOfDirectory(atPath: contents.path)) ?? [])
                    .contains { $0.hasSuffix(".wallpaper") }
                guard fm.fileExists(atPath: contents.path), hasWallpaperBundle else { continue }

                let galleryURL = contents.appendingPathComponent(galleryPath)
                if !fm.fileExists(atPath: galleryURL.path) {
                    try galleryOptions.write(to: galleryURL, options: .atomic)
                    changes.append("\(descriptor.lastPathComponent)/versions/\(versionName)：补入 galleryOptions（768 B，系统样本 SHA-256 已核验）")
                } else if let existing = try? Data(contentsOf: galleryURL),
                          digest(existing) != expectedGallerySHA256 {
                    review.append("\(descriptor.lastPathComponent)/versions/\(versionName) 已有自定义 galleryOptions，未覆盖")
                }

                let configurableURL = contents.appendingPathComponent(configurablePath)
                if !fm.fileExists(atPath: configurableURL.path) {
                    try configurableOptions.write(to: configurableURL, options: .atomic)
                    changes.append("\(descriptor.lastPathComponent)/versions/\(versionName)：补入 configurableOptions（833 B，系统样本 SHA-256 已核验）")
                } else if let existing = try? Data(contentsOf: configurableURL),
                          digest(existing) != expectedConfigurableSHA256 {
                    review.append("\(descriptor.lastPathComponent)/versions/\(versionName) 已有自定义 configurableOptions，未覆盖")
                }
            }
        }

        guard !changes.isEmpty else {
            return review.isEmpty
                ? .skipped("目标版本的必要元数据已存在，无需修改")
                : .needsReview(review.joined(separator: "；"))
        }

        let stem = (pack.name as NSString).deletingPathExtension
        let destination = PosterBoardImports.uniqueDestination(for: "\(stem)(适配-iOS18.3.1).tendies")
        try writeArchive(from: work, to: destination)
        var adapted = try PosterBoardTendie(url: destination)
        adapted = adapted.settingPosterType(pack.posterType)
        if let autoConvert = pack.autoConvert {
            adapted = adapted.settingAutoConvert(autoConvert)
        }
        PosterBoardPreview.invalidate(for: adapted)
        DriftEngine.shared.log("导入适配：\(pack.name) -> \(adapted.name)；\(changes.joined(separator: "；"))")
        return .adapted(name: adapted.name, changes: changes + review.map { "保留未覆盖项：\($0)" })
    }

    private static func kernelBuildVersion() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeArchive(from root: URL, to destination: URL) throws {
        let fm = FileManager.default
        var directories: [String] = []
        var files: [(String, URL)] = []
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw DriftError("无法读取适配后的壁纸目录。")
        }
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard !relative.isEmpty else { continue }
            if ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) {
                directories.append(relative)
            } else {
                files.append((relative, url))
            }
        }
        do {
            do {
                let archive = try Archive(url: destination, accessMode: .create)
                for directory in directories.sorted() {
                    try archive.addEntry(with: directory + "/", type: .directory,
                                         uncompressedSize: 0) { _, _ in Data() }
                }
                for file in files.sorted(by: { $0.0 < $1.0 }) {
                    try archive.addEntry(with: file.0, fileURL: file.1)
                }
            }
            let check = try Archive(url: destination, accessMode: .read)
            let paths = Set(check.map { $0.path })
            guard paths.contains(where: { $0.hasSuffix("/" + galleryPath) }) else {
                throw DriftError("适配包写出后没有找到 galleryOptions，已停止导入副本。")
            }
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }
}
