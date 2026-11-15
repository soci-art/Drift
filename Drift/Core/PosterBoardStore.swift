import Foundation
import SQLite3

/// The PosterBoard store's SQLite database: validating it, making an empty one,
/// and stitching new wallpapers into a copy.
///
/// A port of `src/tweaks/posterboard/pb_config_manager.py`.  Only this file
/// touches that database, for the same reason `ManifestStore` is the only thing
/// that touches `Manifest.db`: the row shapes below are a device contract, and
/// one copy of them is what makes them checkable in a single read.
///
/// Why the device's own database at all, rather than a synthesised one: a
/// wallpaper *is* three rows in this database plus its descriptor directory.
/// The rows carry the device's own provider registrations, the role memberships
/// and the usage metadata the picker sorts by, and there is no way to invent
/// those — `posterAttributes` has a `UNIQUE(posterUUID, roleId,
/// attributeIdentifier)` constraint that a guessed row set violates.  So the
/// apply reads the device's database, adds rows to a copy of it, and puts the
/// copy back.
enum PosterBoardStore {
    /// The classic pre-db5 table set.  Strict validation requires all four.
    static let requiredTables = ["poster", "posterAttributes", "posterRoleMembership",
                                 "sqlite_sequence"]

    /// Result of a transaction applied directly to the live WAL database.
    struct InPlaceRegistration {
        let backupDirectory: String
        let integrityCheck: String
        let registeredKeys: Set<String>
        let fileToCommitMilliseconds: Double
    }

    /// `SQLITE_TRANSIENT` is a C macro the module never sees; `-1` tells sqlite
    /// to copy the bytes rather than keep the pointer, which matters because the
    /// Swift temporaries die when the bind returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Validation

    /// `_validate_posterboard_db`.
    ///
    /// - Parameter strict: `true` requires the classic table set; `false`
    ///   accepts any healthy database carrying poster-ish tables, because the
    ///   schema moves between iOS releases (db5+).
    static func validate(_ url: URL, strict: Bool = true) -> Bool {
        diagnose(url, strict: strict) == nil
    }

    /// Which step of validation rejected the database, or `nil` when it is healthy.
    ///
    /// A bare `false` used to be all a failed fetch left behind: the run stopped,
    /// the log ended on the line before, and the only place the reason existed was
    /// a status line on the phone. `describeTables` only ever described a database
    /// that opened, which is precisely the case that needs explaining least —
    /// a store that will not open at all, or one whose `integrity_check` says
    /// something other than "ok", said nothing anywhere.
    static func diagnose(_ url: URL, strict: Bool = true) -> String? {
        let path = url.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let size = attributes?[.size] as? Int else {
            return "在 \(path) 处没有文件"
        }
        guard size >= 100 else { return "\(size) 字节——太小了，不可能是数据库" }
        guard let db = open(path) else {
            return "SQLite 打不开它：\(openComplaint(path))"
        }
        defer { sqlite3_close(db) }

        guard exec(db, "SELECT 1 FROM sqlite_master LIMIT 1") else {
            return "sqlite_master 不可读：\(String(cString: sqlite3_errmsg(db)))"
        }
        if strict {
            let missing = requiredTables.filter { !tableExists(db, $0) }
            guard missing.isEmpty else {
                return "缺少表：\(missing.joined(separator: "、"))"
            }
        } else {
            let tables = tableNames(db).map { $0.lowercased() }
            guard tables.contains(where: { $0.contains("poster") }) else {
                return "没有以 PosterBoard 命名的表（表："
                    + "\(tables.isEmpty ? "无" : tables.joined(separator: "、")))"
            }
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK else {
            return "integrity_check 无法运行：\(String(cString: sqlite3_errmsg(db)))"
        }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let text = sqlite3_column_text(statement, 0) else {
                return "integrity_check 什么都没说"
            }
            let verdict = String(cString: text)
            return verdict == "ok" ? nil : "integrity_check：\(verdict)"
        case SQLITE_DONE:
            return "integrity_check 没有返回任何行"
        default:
            return "integrity_check 失败：\(String(cString: sqlite3_errmsg(db)))"
        }
    }

    /// `open`'s own complaint, for the cases `open` cannot report itself: a
    /// read-only connection cannot create the `-shm` a WAL database needs, and
    /// that failure surfaces as nothing at all rather than as an error string.
    private static func openComplaint(_ path: String) -> String {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(db) }
        guard rc != SQLITE_OK else { return "只能以读写方式打开" }
        return String(cString: sqlite3_errmsg(db))
    }

    /// `_is_encrypted_database`: a database that will not open as plain SQLite
    /// is either encrypted or not a database, and both need the same answer.
    static func isEncrypted(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int, size >= 100 else { return false }
        guard let db = openReadOnly(url.path) else { return false }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &statement, nil)
        if status == SQLITE_OK { return false }
        let message = String(cString: sqlite3_errmsg(db)).lowercased()
        return message.contains("encrypted") || message.contains("不是数据库")
    }

    /// The tables a rejected file does carry, for the log line that says why.
    static func describeTables(_ url: URL) -> String {
        guard let db = open(url.path) else { return "unreadable" }
        defer { sqlite3_close(db) }
        let tables = tableNames(db)
        return tables.isEmpty ? "没有表" : tables.sorted().joined(separator: ", ")
    }

    /// What a store actually carries, in one line.
    ///
    /// The row counts are the only evidence either half of a fetch leaves about
    /// whether the device handed over a live store or an empty one: a store
    /// whose schema is intact and whose `poster` table holds nothing validates
    /// exactly like a full one, so shipping it back would erase every wallpaper
    /// on the device with nothing in the log to say why. Logged once on the
    /// fetched store and once on the staged copy, so "the device gave us
    /// nothing" and "the stitch lost the rows" cannot be mistaken for each other.
    static func summary(_ url: URL) -> String {
        guard let db = open(url.path) else { return "unreadable" }
        defer { sqlite3_close(db) }
        func count(_ table: String) -> String {
            guard let rows = try? scalarInt(db, "SELECT COUNT(*) FROM \(table)") else { return "?" }
            return String(rows)
        }
        var parts = ["\(count("poster")) poster(s)",
                     "\(count("posterRoleMembership")) membership row(s)"]
        if tableExists(db, "posterAttributes") {
            parts.append("\(count("posterAttributes")) attribute row(s)")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - The empty database

    /// `create_empty_posterboard_db`: the store's schema with no data, which is
    /// what a full reset leaves behind.
    static func createEmptyDatabase(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw DriftError("无法在以下位置创建空的 PosterBoard 数据库："
                + "\(url.lastPathComponent).")
        }
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE IF NOT EXISTS poster (
              posterId INTEGER PRIMARY KEY AUTOINCREMENT,
              UUID TEXT,
              providerId TEXT
            );
            CREATE TABLE IF NOT EXISTS posterAttributes (
              posterUUID TEXT,
              roleId TEXT,
              attributeIdentifier TEXT,
              attributePayload BLOB
            );
            CREATE TABLE IF NOT EXISTS posterRoleMembership (
              posterUUID TEXT,
              roleId TEXT,
              roleSortKey INTEGER
            );
            """
        guard exec(db, schema) else {
            throw DriftError("无法创建空的 PosterBoard 数据库结构："
                + String(cString: sqlite3_errmsg(db)))
        }
        // Same shipping requirement as a stitched store: the reset delivers this
        // file too, and PosterBoard's read-only open cannot switch a
        // rollback-journal database to WAL (see `declareWAL`).
        try declareWAL(db, describing: "空的 PosterBoard 数据库")
        guard validate(url) else {
            throw DriftError("空的 PosterBoard 数据库没有通过校验。重置已在写入设备之前停止。")
        }
    }

    // MARK: - Stitching

    /// `PBConfigManager.update_sqlite`, on a copy of the device's database.
    ///
    /// Returns the file to deliver.  The source is never modified: a run that
    /// fails after this point must not have changed the only copy of the store.
    static func stitch(database: URL,
                       items: [PosterBoardConfigItem],
                       workingDirectory: URL) throws -> URL {
        if isEncrypted(database) {
            throw DriftError(
                "该 PosterBoard 数据库是加密的。请在"
                + "访达 / iTunes 中关闭「加密本地备份」，重新做一份备份再获取——明文"
                + "载荷注入加密库后无法被"
                + "恢复代理解密（MBErrorDomain/205）。")
        }
        if let complaint = diagnose(database, strict: false) {
            throw DriftError(
                "该 PosterBoard 数据库不可用——\(complaint)（表："
                + "\(describeTables(database))）。它可能是一次被截断或中断的"
                + "获取；请重新获取。")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let staged = workingDirectory.appendingPathComponent(
            "STAGED-" + PosterBoard.databaseFileName, conformingTo: .data)
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: database, to: staged)
        guard validate(staged) else {
            throw DriftError("PosterBoard 数据库的暂存副本没有"
                + "校验——来源可能已损坏。请重新获取。")
        }

        var db: OpaquePointer?
        guard sqlite3_open(staged.path, &db) == SQLITE_OK, let db else {
            throw DriftError("无法打开暂存的 PosterBoard 数据库。")
        }
        defer { sqlite3_close(db) }
        guard exec(db, "PRAGMA busy_timeout = 10000") else {
            throw DriftError("无法为暂存数据库设置忙碌超时。")
        }
        guard exec(db, "BEGIN IMMEDIATE") else {
            throw DriftError("无法在暂存的 PosterBoard 上开启事务："
                + "database: " + String(cString: sqlite3_errmsg(db)))
        }
        do {
            try write(db, items: items)
            guard exec(db, "COMMIT") else {
                throw DriftError("无法提交 PosterBoard 数据行："
                    + String(cString: sqlite3_errmsg(db)))
            }
        } catch {
            _ = exec(db, "ROLLBACK")
            throw error
        }
        // The rows above were written through a `-wal`, and the payload the
        // apply ships is this one file — so it has to be in the shape the
        // device's own store is in (see `declareWAL`).
        try declareWAL(db, describing: "暂存的 PosterBoard 数据库")
        return staged
    }

    /// Register descriptors in the device's live database. This path never copies,
    /// replaces, checkpoints, or changes the journal mode of the live database.
    /// Hidden descriptor staging is prepared by the caller before BEGIN IMMEDIATE;
    /// only final directory publication and the DB row transaction happen here.
    static func registerInPlace(
        database: URL,
        items: [PosterBoardConfigItem],
        backupRoot: URL,
        installFiles: () throws -> Date,
        log: (String) -> Void
    ) throws -> InPlaceRegistration {
        guard !items.isEmpty else {
            throw DriftError("没有可登记的 PosterBoard 描述符。")
        }
        let keys = items.map { "\($0.extensionID)/\($0.uuid)" }
        guard Set(keys).count == keys.count else {
            throw DriftError("本轮存在重复的 PosterBoard UUID/provider，拒绝登记。")
        }

        // The family backup must finish before SQLite opens the live database.
        let backup = try backupDatabaseFamily(
            database: database, backupRoot: backupRoot, log: log
        )

        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openStatus = sqlite3_open_v2(database.path, &opened, flags, nil)
        guard openStatus == SQLITE_OK, let db = opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "无 SQLite 错误详情"
            if let opened { sqlite3_close(opened) }
            throw DriftError("SQLite 打开设备现有数据库失败（rc=\(openStatus)）：\(message)")
        }
        defer { sqlite3_close(db) }

        let busyStatus = sqlite3_busy_timeout(db, 10_000)
        guard busyStatus == SQLITE_OK else {
            throw DriftError("SQLite busy_timeout 设置失败（rc=\(busyStatus)）："
                + String(cString: sqlite3_errmsg(db)))
        }

        let journalMode = try scalarText(db, "PRAGMA journal_mode")?.lowercased() ?? ""
        guard journalMode == "wal" else {
            throw DriftError("设备数据库不是 WAL 模式（journal_mode=\(journalMode.isEmpty ? "未知" : journalMode)），拒绝改写。")
        }

        let missing = requiredTables.filter { !tableExists(db, $0) }
        guard missing.isEmpty else {
            throw DriftError("设备数据库缺少必要表：\(missing.joined(separator: "、"))。")
        }

        let beforeIntegrity = try integrityCheck(db)
        guard beforeIntegrity == "ok" else {
            throw DriftError("写入前 integrity_check 未通过：\(beforeIntegrity)")
        }
        let existingRows = try scalarInt(db, "SELECT COUNT(*) FROM poster") ?? 0
        guard existingRows > 0 else {
            throw DriftError("设备现有 poster 表为空，拒绝向空库登记。")
        }
        log("设备数据库已验证：WAL 模式，现有 poster 行 \(existingRows) 条")
        log("设备数据库备份：\(backup.path)")

        let beginStatus = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        guard beginStatus == SQLITE_OK else {
            throw DriftError("SQLite BEGIN IMMEDIATE 失败（rc=\(beginStatus)）："
                + String(cString: sqlite3_errmsg(db)))
        }

        var transactionOpen = true
        var lastFilePublishedAt = Date.distantPast
        do {
            // Prepare DB rows first while they remain invisible to other readers.
            // Publish final descriptor names only after the transaction has begun;
            // COMMIT follows the last rename/fsync immediately.
            try write(db, items: items)
            let transactionRows = try registeredKeys(on: db, items: items)
            guard transactionRows.count == items.count else {
                throw DriftError("BEGIN IMMEDIATE 内の行検証が不足：\(transactionRows.count)/\(items.count)。")
            }
            log("事务内数据库行验证：\(transactionRows.count)/\(items.count)")
            lastFilePublishedAt = try installFiles()

            let commitStatus = sqlite3_exec(db, "COMMIT", nil, nil, nil)
            guard commitStatus == SQLITE_OK else {
                throw DriftError("SQLite COMMIT 失败（rc=\(commitStatus)）："
                    + String(cString: sqlite3_errmsg(db)))
            }
            transactionOpen = false
        } catch {
            if transactionOpen {
                let rollbackStatus = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                if rollbackStatus != SQLITE_OK {
                    log("SQLite ROLLBACK 也失败（rc=\(rollbackStatus)）："
                        + String(cString: sqlite3_errmsg(db)))
                }
            }
            throw error
        }

        let commitGap = max(0, Date().timeIntervalSince(lastFilePublishedAt) * 1_000)
        if commitGap > 1_000 {
            log(String(format: "警告：最后一个 descriptor 最终目录发布到 SQLite COMMIT：%.0f ms（超过 1 秒目标）", commitGap))
        } else {
            log(String(format: "最后一个 descriptor 最终目录发布到 SQLite COMMIT：%.0f ms", commitGap))
        }

        let afterIntegrity: String
        do {
            afterIntegrity = try integrityCheck(db)
        } catch {
            afterIntegrity = "读取失败：\(error.localizedDescription)"
        }
        log("提交后 integrity_check：\(afterIntegrity)")

        let registered: Set<String>
        do {
            registered = try registeredKeys(on: db, items: items)
        } catch {
            log("提交后数据库行核验失败：\(error.localizedDescription)")
            return InPlaceRegistration(
                backupDirectory: backup.path,
                integrityCheck: afterIntegrity,
                registeredKeys: [],
                fileToCommitMilliseconds: commitGap
            )
        }
        log("提交后立即行核验：完整登记 \(registered.count)/\(items.count)")
        return InPlaceRegistration(
            backupDirectory: backup.path,
            integrityCheck: afterIntegrity,
            registeredKeys: registered,
            fileToCommitMilliseconds: commitGap
        )
    }

    /// Delayed read-back after PosterBoard has had time to process the store.
    static func verifyRegisteredItems(
        database: URL,
        items: [PosterBoardConfigItem],
        log: (String) -> Void
    ) throws -> Set<String> {
        guard let db = open(database.path) else {
            throw DriftError("SQLite 延迟复查无法打开设备数据库：\(database.path)")
        }
        defer { sqlite3_close(db) }
        let keys = try registeredKeys(on: db, items: items)
        log("延迟数据库复查：完整登记 \(keys.count)/\(items.count)")
        return keys
    }

    /// Leaves the database declaring WAL with every committed page in the main
    /// file — the only shape the restore may ship.
    ///
    /// PosterBoard opens its store read-only (`opening database … w/ flags 1`)
    /// and immediately runs `PRAGMA journal_mode=WAL`. On a database that
    /// already says WAL that is a no-op; on a rollback-journal database it is a
    /// *write*, and a read-only connection answers "attempt to write a
    /// readonly database". The store then logs "data store never ever
    /// initialized; skipping migration" and rebuilds itself from the gallery:
    /// every poster gets a new identity and every custom wallpaper — the ones
    /// whose content lives only in the store — is gone. That is the wipe this
    /// feature kept producing, and it was one line of SQL.
    ///
    /// The file stays self-contained: the checkpoint moves every frame into the
    /// main file and truncates the `-wal`, so the zero-byte `-wal`/`-shm`
    /// companions the restore ships alongside it are exactly what the device's
    /// own store has.
    private static func declareWAL(_ db: OpaquePointer, describing what: String) throws {
        guard exec(db, "PRAGMA journal_mode=WAL"),
              try scalarText(db, "PRAGMA journal_mode")?.lowercased() == "wal" else {
            throw DriftError("\(what)无法切换到 WAL 模式（"
                + String(cString: sqlite3_errmsg(db)) + "）。PosterBoard 打开它的库时"
                + "以只读方式并要求 WAL，而回滚日志模式的数据库会让这件事"
                + "失败——然后它会重建库并丢掉所有壁纸。")
        }
        guard exec(db, "PRAGMA wal_checkpoint(TRUNCATE)") else {
            throw DriftError("无法为\(what)做检查点——直接交付它会"
                + "把数据行留在一个恢复不会带走的文件里："
                + String(cString: sqlite3_errmsg(db)))
        }
    }

    /// The inserts themselves.  Every write updates first and only inserts when
    /// nothing matched, because a freshly fetched database can already carry
    /// rows this list names (a re-apply of the same pack), and the attribute and
    /// membership tables may hold orphans from an earlier failed apply.
    ///
    /// `posterId` starts **above** `MAX(posterId)` rather than at the stored
    /// `sqlite_sequence.seq + 1`: the old scheme collides with a live row whose
    /// id the sequence has drifted past (rows deleted since), and a primary-key
    /// clash is a failed apply or a corrupted on-device store.
    private static func write(_ db: OpaquePointer, items: [PosterBoardConfigItem]) throws {
        var sequence = try scalarInt(db, "SELECT MAX(posterId) FROM poster") ?? 0
        var sortKey = try scalarInt(db,
            "SELECT MAX(roleSortKey) FROM posterRoleMembership WHERE roleId = ?",
            [.text("PRPosterRoleLockScreen")]) ?? sequence

        // Exactly one selected wallpaper is valid. Preserve the current one
        // when no new item asks to become selected (including container-only runs).
        let selectedUUID = items.last(where: { $0.setSelected })?.uuid
        if selectedUUID != nil {
            try run(db, "DELETE FROM posterAttributes WHERE roleId = ? AND attributeIdentifier = ?",
                    [.text("PRPosterRoleLockScreen"), .text("SELECTED")])
        }

        for item in items {
            let payload = usageMetadataJSON()
            let existing = try scalarInt(db, "SELECT posterId FROM poster WHERE UUID = ?",
                                         [.text(item.uuid)])
            if let existing {
                try run(db, "UPDATE poster SET providerId = ? WHERE posterId = ?",
                        [.text(item.extensionID), .integer(existing)])
            } else {
                sequence += 1
                try run(db, "INSERT INTO poster (posterId, UUID, providerId) VALUES (?, ?, ?)",
                        [.integer(sequence), .text(item.uuid), .text(item.extensionID)])
            }

            try run(db,
                "UPDATE posterAttributes SET attributePayload = ? WHERE posterUUID = ? "
                + "AND roleId = ? AND attributeIdentifier = ?",
                [.text(payload), .text(item.uuid), .text("PRPosterRoleLockScreen"),
                 .text("PRPosterRoleAttributeTypeUsageMetadata")])
            if changes(db) == 0 {
                try run(db,
                    "INSERT INTO posterAttributes (posterUUID, roleId, attributeIdentifier, "
                    + "attributePayload) VALUES (?, ?, ?, ?)",
                    [.text(item.uuid), .text("PRPosterRoleLockScreen"),
                     .text("PRPosterRoleAttributeTypeUsageMetadata"), .text(payload)])
            }

            if item.uuid == selectedUUID {
                try run(db,
                    "DELETE FROM posterAttributes WHERE posterUUID = ? AND roleId = ? "
                    + "AND attributeIdentifier = ?",
                    [.text(item.uuid), .text("PRPosterRoleLockScreen"), .text("SELECTED")])
                try run(db,
                    "INSERT INTO posterAttributes (posterUUID, roleId, attributeIdentifier, "
                    + "attributePayload) VALUES (?, ?, ?, ?)",
                    [.text(item.uuid), .text("PRPosterRoleLockScreen"), .text("SELECTED"),
                     .integer(1)])
            }

            try run(db,
                "UPDATE posterRoleMembership SET roleSortKey = ? WHERE posterUUID = ? "
                + "AND roleId = ?",
                [.integer(sortKey + 1), .text(item.uuid), .text("PRPosterRoleLockScreen")])
            if changes(db) == 0 {
                try run(db,
                    "INSERT INTO posterRoleMembership (posterUUID, roleId, roleSortKey) "
                    + "VALUES (?, ?, ?)",
                    [.text(item.uuid), .text("PRPosterRoleLockScreen"), .integer(sortKey + 1)])
            }
            sortKey += 1
        }

        try run(db, "UPDATE sqlite_sequence SET seq = ? WHERE name = ?",
                [.integer(sequence), .text("poster")])
        if changes(db) == 0 {
            try run(db, "INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)",
                    [.text("poster"), .integer(sequence)])
        }
    }

    /// The `attributePayload` JSON the device writes for a wallpaper.
    ///
    /// Built by hand rather than through `JSONSerialization` for one reason:
    /// key order.  The reference emits it with `json.dumps(...,
    /// separators=(",", ":"))`, which preserves insertion order, and a row this
    /// port writes should be comparable with one upstream would have written.
    ///
    /// The three timestamps are three separate `time.time()` calls in the
    /// reference — not one clock read with offsets — so they are three clocks
    /// here too.
    private static func usageMetadataJSON() -> String {
        let now = Date().timeIntervalSince1970
        return "{\"creationDate\":\(now),"
            + "\"extensionAvailable\":true,"
            + "\"attributeType\":\"PRPosterRoleAttributeTypeUsageMetadata\","
            + "\"lastActivatedDate\":\(Date().timeIntervalSince1970 + 0.0001),"
            + "\"lastSelectedDate\":\(Date().timeIntervalSince1970 + 0.00001)}"
    }

    // MARK: - SQLite plumbing

    private enum Binding {
        case text(String)
        case integer(Int)
    }

    /// A read handle to a database, whether or not its journal sidecars exist.
    ///
    /// Read-only first, because that is what every reader below does. A
    /// WAL-mode database *without* a `-wal`/`-shm` pair beside it cannot be read
    /// that way, though: SQLite needs the shared-memory file to take a read
    /// mark and will not create one for a reader, so the first statement fails
    /// with SQLITE_CANTOPEN. The handle is also lazy — `sqlite3_open_v2`
    /// returns SQLITE_OK before it touches the file — so that failure only
    /// surfaces on the first statement, never at open. That is exactly the
    /// shape of a store we have just prepared for delivery: `fold` checkpoints
    /// every page into the main file and leaves the sidecars as zero-byte
    /// companions the restore carries separately. Probe, and retry read-write
    /// so SQLite can create whatever it needs.
    private static func open(_ path: String) -> OpaquePointer? {
        for flags in [SQLITE_OPEN_READONLY, SQLITE_OPEN_READWRITE] {
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
                sqlite3_close(db)
                continue
            }
            var statement: OpaquePointer?
            let status = sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1",
                                           -1, &statement, nil)
            sqlite3_finalize(statement)
            if status == SQLITE_OK { return db }
            sqlite3_close(db)
        }
        return nil
    }

    /// A read-only handle *without* the probe above, for `isEncrypted`: telling
    /// an encrypted payload from a WAL-mode one means reading the failure, and
    /// `open` reports both as "will not open".
    private static func openReadOnly(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func tableNames(_ db: OpaquePointer) -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'",
                                 -1, &statement, nil) == SQLITE_OK else { return [] }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { names.append(String(cString: text)) }
        }
        return names
    }

    private static func tableExists(_ db: OpaquePointer, _ table: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                                 -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(statement, 1, table, -1, transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// One integer column of one row, `nil` when the row or the value is absent.
    private static func scalarInt(_ db: OpaquePointer, _ sql: String,
                                  _ bindings: [Binding] = []) throws -> Int? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DriftError("PosterBoard 查询失败：\(sql) —— "
                + String(cString: sqlite3_errmsg(db)))
        }
        bind(statement, bindings)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(statement, 0) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// One text column of one row, `nil` when the row or the value is absent.
    private static func scalarText(_ db: OpaquePointer, _ sql: String,
                                   _ bindings: [Binding] = []) throws -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DriftError("PosterBoard 查询失败：\(sql) —— "
                + String(cString: sqlite3_errmsg(db)))
        }
        bind(statement, bindings)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(statement, 0) == SQLITE_NULL { return nil }
        guard let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private static func run(_ db: OpaquePointer, _ sql: String,
                            _ bindings: [Binding] = []) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DriftError("PosterBoard 写入失败：\(sql) —— "
                + String(cString: sqlite3_errmsg(db)))
        }
        bind(statement, bindings)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DriftError("PosterBoard 写入失败：\(sql) —— "
                + String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Preserve the existing database family before the first write. Missing
    /// sidecars remain absent; no replacement or zero-byte sidecars are created.
    private static func backupDatabaseFamily(
        database: URL,
        backupRoot: URL,
        log: (String) -> Void
    ) throws -> URL {
        let manager = FileManager.default
        var mainIsDirectory: ObjCBool = false
        guard manager.fileExists(atPath: database.path, isDirectory: &mainIsDirectory),
              !mainIsDirectory.boolValue else {
            throw DriftError("设备现有 PosterBoard SQLite 主库不存在：\(database.path)")
        }
        try manager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let backup = backupRoot.appendingPathComponent(
            "before-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: backup, withIntermediateDirectories: false)

        var manifest = [
            "PosterBoard live database family backup",
            "createdAt=\(ISO8601DateFormatter().string(from: Date()))",
            "source=\(database.path)"
        ]
        for suffix in ["", "-wal", "-shm"] {
            let name = database.lastPathComponent + suffix
            let source = URL(fileURLWithPath: database.path + suffix)
            let destination = backup.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
                if suffix.isEmpty {
                    throw DriftError("数据库备份失败：主库在复制前消失。")
                }
                manifest.append("\(name)=absent")
                continue
            }
            let values = try source.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  !isDirectory.boolValue else {
                throw DriftError("数据库备份拒绝非普通文件或符号链接：\(source.path)")
            }
            let sourceAttributes = try manager.attributesOfItem(atPath: source.path)
            let sourceBytes = (sourceAttributes[.size] as? NSNumber)?.int64Value ?? 0
            try manager.copyItem(at: source, to: destination)
            let attributes = try manager.attributesOfItem(atPath: destination.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes == sourceBytes else {
                throw DriftError("数据库族备份大小不一致：\(name)，源 \(sourceBytes)，备份 \(bytes)。")
            }
            manifest.append("\(name)=copied,\(bytes) bytes")
        }

        try Data((manifest.joined(separator: "\n") + "\n").utf8).write(
            to: backup.appendingPathComponent("backup-manifest.txt"),
            options: .atomic
        )
        log("SQLite 原样备份已完成：\(backup.path)")
        log("SQLite 备份清单：\(manifest.dropFirst(3).joined(separator: "；"))")
        return backup
    }

    /// Collect every integrity_check result row for a clear diagnostic.
    private static func integrityCheck(_ db: OpaquePointer) throws -> String {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &statement, nil)
        guard status == SQLITE_OK else {
            throw DriftError("SQLite integrity_check 无法执行（rc=\(status)）："
                + String(cString: sqlite3_errmsg(db)))
        }
        var messages: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let value = sqlite3_column_text(statement, 0) {
                    messages.append(String(cString: value))
                }
            case SQLITE_DONE:
                return messages.isEmpty ? "无返回行" : messages.joined(separator: "；")
            default:
                throw DriftError("SQLite integrity_check 读取失败："
                    + String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// A row is registered only when poster, usage metadata and role membership
    /// agree on the descriptor UUID and provider. The SELECTED row is optional.
    private static func registeredKeys(
        on db: OpaquePointer,
        items: [PosterBoardConfigItem]
    ) throws -> Set<String> {
        var result: Set<String> = []
        for item in items {
            let posterRows = try scalarInt(
                db,
                "SELECT COUNT(*) FROM poster WHERE UUID = ? AND providerId = ?",
                [.text(item.uuid), .text(item.extensionID)]
            ) ?? 0
            let usageRows = try scalarInt(
                db,
                "SELECT COUNT(*) FROM posterAttributes WHERE posterUUID = ? AND roleId = ? "
                    + "AND attributeIdentifier = ?",
                [.text(item.uuid), .text("PRPosterRoleLockScreen"),
                 .text("PRPosterRoleAttributeTypeUsageMetadata")]
            ) ?? 0
            let membershipRows = try scalarInt(
                db,
                "SELECT COUNT(*) FROM posterRoleMembership WHERE posterUUID = ? AND roleId = ?",
                [.text(item.uuid), .text("PRPosterRoleLockScreen")]
            ) ?? 0
            if posterRows == 1, usageRows > 0, membershipRows > 0 {
                result.insert("\(item.extensionID)/\(item.uuid)")
            }
        }
        return result
    }

    private static func bind(_ statement: OpaquePointer?, _ bindings: [Binding]) {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, transient)
            case .integer(let value): sqlite3_bind_int64(statement, index, Int64(value))
            }
        }
    }

    /// `sqlite3_changes`, for the update-then-insert pattern above.
    private static func changes(_ db: OpaquePointer) -> Int {
        Int(sqlite3_changes(db))
    }
}
