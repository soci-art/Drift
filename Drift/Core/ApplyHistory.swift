import Foundation

/// The small local history of apply/reset operations — the port of
/// `src/controllers/apply_history.py`, stored where the desktop stores it
/// (`AppDataLocation/GoldenNugget/History/operations.json`) so a shared
/// container reads the same file shape: `Documents/GoldenNugget/History/operations.json`.
///
/// The desktop never lets recording change the operation result — every failure
/// is swallowed (`record_operation`'s whole body sits in `try/except`), and the
/// same holds here: `record` returns nothing and never throws.
enum ApplyHistory {
    /// `MAX_ENTRIES` (`apply_history.py:9`).
    static let maxEntries = 30

    /// One bounded record, in the reference's own field set
    /// (`apply_history.py:30`): `timestamp` (local ISO-8601 with seconds),
    /// `mode` ("apply" or "reset"), `success`, `error`, plus the device
    /// descriptors the desktop's manager had available.
    struct Record: Codable {
        let timestamp: String
        let mode: String
        let success: Bool
        let error: String
        let device: String
        let model: String
        let ios: String
        let udid: String
        /// How the wallpaper actually took effect ("免注销" / "写入后手动注销").
        /// Optional so records written by 1.2.0 and earlier still decode.
        var effect: String? = nil
        /// The internal write channel a 2.0.0 run used ("本机通道" /
        /// "隧道 · 免注销" / "隧道 · 注销生效"). Optional for old records.
        var channel: String? = nil
        /// The provider folder(s) the run wrote into. Optional for old records.
        var provider: String? = nil
        /// The store-verification grade ("已核验：在册 n/n" /
        /// "已写入、未确认显示：…"). Optional for old records.
        var verification: String? = nil
        /// The wallpaper pack name(s) the run handled (#185: history rows
        /// lead with the pack name). Optional — records written before
        /// build 19 do not have it and fall back to the mode text.
        var packName: String? = nil
        /// The imported pack file name(s) this run flashed, inside the
        /// imports directory — a record export (#237) packs these as the
        /// ORIGINAL wallpaper files. Optional: records written before
        /// this field existed never stored them, and their exports say
        /// so in the missing-contents note instead of substituting
        /// another pack.
        var packFiles: [String]? = nil
        /// The file name (inside `History/Slices/`) holding this run's
        /// own log lines, snapshotted by the caller at record time
        /// (#237). Optional for the same reason as `packFiles`.
        var logSlice: String? = nil

        /// `datetime.now().astimezone().isoformat(timespec="seconds")`, which is
        /// local time with the offset (`"2026-10-12T14:05:33+03:00"`).
        static func now() -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate,
                                       .withColonSeparatorInTime]
            formatter.timeZone = .current
            return formatter.string(from: Date())
        }
    }

    /// `load_history` — the file's list of records, or `[]` when the file is
    /// missing, unreadable or not a list (`apply_history.py:18`).
    static func load() -> [Record] {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    /// `record_operation` — append one bounded record atomically
    /// (`apply_history.py:27`).
    ///
    /// Mirrors the reference field for field: `mode` is kept verbatim ("apply"
    /// or "reset"), the record is appended to whatever is on disk, trimmed to
    /// the last `maxEntries`, and swapped into place with `os.replace`'s Swift
    /// equivalent.  Any failure is swallowed.
    static func record(mode: String, success: Bool, error: String = "",
                       device: String = "", model: String = "", ios: String = "",
                       udid: String = "", effect: String? = nil,
                       channel: String? = nil, provider: String? = nil,
                       verification: String? = nil, packName: String? = nil,
                       packFiles: [String]? = nil, logSliceText: String? = nil) {
        let timestamp = Record.now()
        // The run's log slice is written first so the record can name it;
        // a failed write just leaves the field empty (the export then
        // declares the slice missing rather than inventing one).
        var sliceName: String? = nil
        if let logSliceText, !logSliceText.isEmpty {
            sliceName = saveLogSlice(text: logSliceText, timestamp: timestamp)
        }
        let item = Record(timestamp: timestamp,
                          mode: mode,
                          success: success,
                          error: error,
                          device: device,
                          model: model,
                          ios: ios,
                          udid: udid,
                          effect: effect,
                          channel: channel,
                          provider: provider,
                          verification: verification,
                          packName: packName,
                          packFiles: packFiles,
                          logSlice: sliceName)
        var records = load() + [item]
        if records.count > maxEntries {
            records = Array(records.suffix(maxEntries))
        }
        pruneLogSlices(keeping: Set(records.compactMap(\.logSlice)))
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            let temporary = directory.appendingPathComponent("operations.json.tmp")
            try data.write(to: temporary, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } catch {
            // Never throw: recording must not affect the operation result.
        }
    }

    /// `clear_history` — unlink the file, tolerating its absence
    /// (`apply_history.py:52`). The log slices go with it (#237: no
    /// orphaned slice files outliving their records).
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: slicesDirectory)
    }

    // MARK: - Per-run log slices (#237)

    /// Where the per-run log slices live: `History/Slices/` next to
    /// `operations.json`.
    static var slicesDirectory: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("Slices", isDirectory: true)
    }

    /// The on-disk URL for a record's `logSlice` file name.
    static func sliceURL(_ name: String) -> URL {
        slicesDirectory.appendingPathComponent(name)
    }

    /// Write one run's log lines to its slice file. Returns the file
    /// name to store in the record, or nil when the write failed.
    private static func saveLogSlice(text: String, timestamp: String) -> String? {
        let name = timestamp
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "_") + ".txt"
        do {
            try FileManager.default.createDirectory(at: slicesDirectory,
                                                    withIntermediateDirectories: true)
            try text.write(to: sliceURL(name), atomically: true, encoding: .utf8)
            return name
        } catch {
            return nil
        }
    }

    /// Delete every slice file whose record is gone — records trimmed by
    /// the 30-entry cap, or files orphaned any other way.
    private static func pruneLogSlices(keeping names: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: slicesDirectory.path)) ?? []
        for file in files where !names.contains(file) {
            try? FileManager.default.removeItem(at: sliceURL(file))
        }
    }

    /// `_path` (`apply_history.py:12`): the file this app owns inside
    /// `<Documents>/GoldenNugget/History/`.
    static var fileURL: URL {
        fileURLOverride ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Drift", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
            .appendingPathComponent("operations.json")
    }

    /// Test seam: point the store somewhere else (the regression harness keeps
    /// the real Documents folder untouched).  Never set in the app.
    static var fileURLOverride: URL?
}
