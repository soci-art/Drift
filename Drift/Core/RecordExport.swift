import Foundation
import ZIPFoundation

/// One apply-history record packed for handing over (collection #237 /
/// #238, Grace 2026-11-12): the user taps 导出 on a single record in
/// Settings → 刷入记录 and gets a zip with exactly three things —
///
///   1. the record itself (time, apply or reset, success or failure,
///      error, device, model, system);
///   2. that run's own log slice (never the whole log standing in);
///   3. the ORIGINAL .tendies file(s) that run flashed (never a
///      (patched) repair product, never another run's pack).
///
/// Anything missing is declared in 缺失说明.txt inside the zip — old
/// records predate the pack/slice fields and export with the record
/// alone plus that note. Nothing here is automatic: a bundle exists
/// only because the user tapped the button. The plain log upload in
/// Settings (LogUpload) stays log-only forever; wallpaper travels only
/// through this per-record door.
enum RecordExport {
    struct Bundle {
        /// The built zip in the caches directory.
        let url: URL
        let bytes: Int
        /// Plain-language lines naming what the bundle could NOT include.
        let missing: [String]

        /// The big-upload door caps at 24 MB (the inbox's own ceiling);
        /// past it, 导出 still works and only 上传 is refused (#237).
        var tooBigToUpload: Bool { bytes > LogUpload.bigMaxBytes }

        var sizeText: String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes),
                                      countStyle: .file)
        }
    }

    /// Build the zip for one record. Throws only for real I/O failures;
    /// missing contents are reported in the bundle, not thrown.
    static func build(for record: ApplyHistory.Record) throws -> Bundle {
        let fm = FileManager.default
        let name = "Drift记录-\(fileStamp(from: record.timestamp)).zip"
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent(name)
        try? fm.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        var missing: [String] = []

        // 1 — the record itself.
        try addText(archive, name: "刷入记录.txt", text: describe(record))

        // 2 — this run's log slice.
        if let slice = record.logSlice {
            let sliceURL = ApplyHistory.sliceURL(slice)
            if fm.fileExists(atPath: sliceURL.path) {
                try archive.addEntry(with: "本次日志.txt", fileURL: sliceURL)
            } else {
                missing.append("这次的日志片段（文件已不在）")
            }
        } else {
            missing.append("这次的日志片段（这条记录没有存下）")
        }

        // 3 — the original pack file(s) that run flashed.
        if let files = record.packFiles, !files.isEmpty {
            for file in files {
                let packURL = PosterBoardImports.directory
                    .appendingPathComponent(file)
                if fm.fileExists(atPath: packURL.path) {
                    try archive.addEntry(with: file, fileURL: packURL)
                } else {
                    missing.append("原始壁纸包「\(file)」（已不在壁纸包里）")
                }
            }
        } else {
            missing.append("原始壁纸包（这条记录没记下刷的是哪个包）")
        }

        if !missing.isEmpty {
            try addText(archive, name: "缺失说明.txt",
                        text: "这份记录包缺了以下内容：\n"
                            + missing.joined(separator: "\n") + "\n")
        }

        let bytes = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        return Bundle(url: url, bytes: bytes, missing: missing)
    }

    /// The 导出（存成文件） landing spot: `Documents/Drift/Exports/`,
    /// where the Files app shows the app's own folder.
    static var exportsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Drift", isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)
    }

    /// Copy a built bundle into the exports directory. Returns the copy.
    @discardableResult
    static func saveToFiles(_ bundle: Bundle) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        let target = exportsDirectory.appendingPathComponent(bundle.url.lastPathComponent)
        try? fm.removeItem(at: target)
        try fm.copyItem(at: bundle.url, to: target)
        return target
    }

    /// The record as plain text — the same fields the store keeps, in
    /// the order a person reads them.
    private static func describe(_ record: ApplyHistory.Record) -> String {
        var lines: [String] = []
        lines.append("时间：\(record.timestamp)")
        lines.append("操作：\(record.mode)")
        lines.append("结果：\(record.success ? "成功" : "失败")")
        if !record.error.isEmpty { lines.append("报错：\(record.error)") }
        if let channel = record.channel { lines.append("通道：\(channel)") }
        if let effect = record.effect { lines.append("生效：\(effect)") }
        if let verification = record.verification { lines.append("核验：\(verification)") }
        if let provider = record.provider { lines.append("写入位置：\(provider)") }
        if !record.device.isEmpty { lines.append("设备：\(record.device)") }
        if !record.model.isEmpty { lines.append("机型：\(record.model)") }
        if !record.ios.isEmpty { lines.append("系统：iOS \(record.ios)") }
        if let packName = record.packName { lines.append("刷的包：\(packName)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `yyyyMMdd-HHmmss` out of the record's ISO-8601 timestamp (the
    /// log-package naming style); unparseable stamps fall back to a
    /// filesystem-safe scrub of the raw string.
    private static func fileStamp(from timestamp: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate,
                             .withColonSeparatorInTime]
        if let date = iso.date(from: timestamp) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            return formatter.string(from: date)
        }
        return timestamp
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "-")
            .prefix(17).description
    }

    private static func addText(_ archive: Archive, name: String, text: String) throws {
        let data = Data(text.utf8)
        try archive.addEntry(with: name, type: .file,
                             uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position)..<(Int(position) + size))
        }
    }
}
