import CryptoKit
import Foundation
import Minimuxer
import SQLite3

/// An error whose message is meant for the user, in plain words.
///
/// The restore machinery's own error type (the reference's
/// `GoldenNuggetError` under a Drift name): the ported stages throw it,
/// and the funnel surfaces `localizedDescription` unchanged, so every
/// message written into it has to read as a sentence to the user.
struct DriftRestoreError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// SHA-256 fingerprint over one prepared restore package (plan,
/// 2026-11-19: the dry-run hash binding).
///
/// Computed at the end of a dry run over everything the write-back
/// would hand the device: the device identity, the iOS version and
/// build, the four backup-level metadata files, and every payload file
/// with its hash. The write-back recomputes it before restoring and
/// refuses on any difference — a package that changed after its dry
/// run is not the package that was audited.
struct RestoreFingerprint {
    let digest: String
    /// Payload files only (the metadata files are bound separately).
    let payloadFileCount: Int
    let payloadBytes: Int64

    var short: String { String(digest.prefix(8)) }

    /// Backup-level files at the device directory's root. They are
    /// bound into the fingerprint by name, never by the payload walk:
    /// `Manifest.db-shm` is a live index and is left out entirely, and
    /// the `-wal` sidecar is bound when present because a WAL-mode
    /// manifest's newest bytes can live there.
    private static let metadataNames: Set<String> = [
        "Manifest.db", "Manifest.db-shm", "Manifest.db-wal",
        "Manifest.plist", "Info.plist", "Status.plist",
    ]

    static func compute(deviceDir: URL, udid: String,
                        version: String, build: String) throws -> RestoreFingerprint {
        let fm = FileManager.default
        var lines: [String] = [
            "drift-restore-fingerprint v1",
            "udid=\(udid)",
            "version=\(version)",
            "build=\(build)",
        ]
        for name in ["Manifest.db", "Manifest.db-wal", "Manifest.plist",
                     "Info.plist", "Status.plist"] {
            let url = deviceDir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                lines.append("\(name)=\(try sha256Hex(of: url))")
            } else {
                lines.append("\(name)=absent")
            }
        }

        var payloads: [(path: String, hash: String, bytes: Int64)] = []
        if let walker = fm.enumerator(at: deviceDir, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walker {
                let rel = url.path.hasPrefix(deviceDir.path + "/")
                    ? String(url.path.dropFirst(deviceDir.path.count + 1))
                    : url.lastPathComponent
                // The staging tree is not package content: the manifest
                // never references it, and leftovers there are reported
                // by the pull itself.
                if rel == "Snapshot" || rel.hasPrefix("Snapshot/") { continue }
                if !rel.contains("/"), metadataNames.contains(rel) { continue }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                let bytes = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
                payloads.append((rel, try sha256Hex(of: url), bytes))
            }
        }
        payloads.sort { $0.path < $1.path }
        for payload in payloads {
            lines.append("file \(payload.path) \(payload.hash)")
        }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        return RestoreFingerprint(digest: digest,
                                  payloadFileCount: payloads.count,
                                  payloadBytes: payloads.reduce(0) { $0 + $1.bytes })
    }

    /// Chunked SHA-256 of one file (payloads can be tens of MB).
    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// What a dry run hands back: enough for the home page's dry-run card
/// and for the history entry the write-back eventually records.
struct RestoreDryRunReport {
    let version: String
    let buildVersion: String
    /// Files this run compiled for delivery (the wallpaper delta).
    let payloadCount: Int
    /// Payload files in the prepared package as a whole.
    let packageFileCount: Int
    let packageBytes: Int64
    let auditLine: String
    let fingerprintShort: String
    let packNames: [String]
    let packFiles: [String]

    /// The one-paragraph result the funnel returns for a dry run.
    var summaryLine: String {
        "干跑完成，还没有写回。拉取和对账都过了：将写回 \(packageFileCount) 个文件"
            + "（共 \(ByteCountFormatter.string(fromByteCount: packageBytes, countStyle: .file))），"
            + "指纹 \(fingerprintShort)。确认无误后，点主页干跑卡上的「确认写回」才会真正恢复。"
    }
}

/// The restore line's orchestration (Alpha research line only — the
/// engine reaches this type solely behind `DriftRestoreGate`).
///
/// Two phases, separately invoked, per the build plan:
///
///   * `dryRun` — strict preflight, the PosterBoard fetch (the run's
///     one and only backup session), the compile, the restore base
///     derived locally from the fetched manifest, prune + inject, the
///     against-disk audit and the fingerprint. It prepares a complete
///     restore package and then STOPS. Nothing is written back, and a
///     failed audit prepares nothing.
///   * `writeBack` — re-verifies the fingerprint against the package
///     still on disk, then restores through the vendored gateway
///     (success judged by the device's own verdict, never by the call
///     returning). Any mismatch voids the dry run.
///
/// The prepared state lives only in this instance: if the app dies,
/// the dry run is void and must be run again.
final class DriftRestoreService {
    private struct Prepared {
        let report: RestoreDryRunReport
        let fingerprint: RestoreFingerprint
        let backupRoot: URL
        let deviceDir: URL
        let udid: String
    }

    private var prepared: Prepared?

    // MARK: - Dry run

    func dryRun(selection: PosterBoardSelection,
                deviceVersion: String,
                buildVersion: String,
                onProgress: ((Double) -> Void)? = nil) async throws -> RestoreDryRunReport {
        prepared = nil

        // Scope of this line's first version (plan test protocol order:
        // ordinary packs, then video packs; resets and container packs
        // are later segments and stay refused here as well as in the
        // judge).
        guard !selection.fullReset, selection.resetModes.isEmpty else {
            throw DriftRestoreError("恢复刷这一版还不支持重置壁纸商店，这次停下。")
        }

        guard let udid = (try? await Minimuxer.shared().core.fetchUDID()) ?? nil,
              !udid.isEmpty else {
            throw DriftRestoreError("读不到设备标识，恢复刷停下。请确认 Wi-Fi 可用、LocalDevVPN 已连上、配对文件已选好，再重试。")
        }

        // The segment is judged by build number; unreadable means stop
        // (plan discipline). This line's first segment is iOS 27 only.
        guard !buildVersion.isEmpty else {
            throw DriftRestoreError("读不到设备的构建号，恢复刷按构建号判断系统段位，这次停下。请确认隧道已连上后重试。")
        }
        let major = Int(deviceVersion.split(separator: ".").first ?? "") ?? 0
        guard major == 27 else {
            throw DriftRestoreError("恢复刷这一版只开 iOS 27 这一段，这台是 iOS \(deviceVersion)，这次停下。")
        }

        // Encryption gate (revised 2026-11-20 after the first field log):
        // the lockdown preference is only a pre-screen — explicitly ON
        // stops here. Unreadable no longer stops: a device that never
        // made a computer backup answers the WillEncrypt query with
        // MissingValue (field log 2026-11-19, iPhone13,1 on iOS 27.0.1),
        // which the gateway folds into nil even though the device is not
        // encrypted, and the first build's hard stop turned that into a
        // dead end. The verdict then comes from the pulled backup itself:
        // the pull only reads, and an encrypted backup's device-produced
        // Manifest.db does not parse as SQLite — checked right after the
        // pull, before any pruning and long before any write-back.
        let encryptionPreference = await Diagnostics.backupEncryptionEnabled()
        if encryptionPreference == true {
            throw DriftRestoreError("这台设备开着「加密本地备份」，恢复刷用不了。请先在电脑的 Finder 或 iTunes 里关掉「加密本地备份」，再重试。")
        }
        AppLog.write(encryptionPreference == false
            ? "restore preflight: encrypted local backup = OFF"
            : "restore preflight: encryption preference unreadable — verdict deferred to the pulled manifest")

        let log: @Sendable (String) -> Void = { AppLog.write($0) }

        // The device's own PosterBoard store first (its database is
        // what a wallpaper is compiled against), then the compile.
        // This fetch is the dry run's ONLY backup session (build 4,
        // 2026-11-21): it streams the device's whole manifest, and the
        // restore base below is derived from what it brought back
        // instead of a second, protective session re-streaming the
        // same enumeration. Either way the pull ends — cleanly or in a
        // refusal like the field log's closing MBErrorDomain/205 — the
        // shortfall audit reconciles the pulled manifest against the
        // disk and names what the pull meant to keep but did not land,
        // so a refusal stops being a bare count.
        let fetched: PosterBoardBackup.Result
        do {
            fetched = try await PosterBoardBackup.fetch(
                backupRoot: AppPaths.posterBoardFetchRoot,
                udid: udid,
                ios27: true,
                preserveExisting: true,
                onProgress: onProgress,
                log: log)
        } catch {
            await Self.logPullShortfallAudit(
                deviceDir: AppPaths.deviceDir(backupRoot: AppPaths.posterBoardFetchRoot,
                                              udid: udid))
            throw error
        }
        await Self.logPullShortfallAudit(
            deviceDir: AppPaths.deviceDir(backupRoot: AppPaths.posterBoardFetchRoot,
                                          udid: udid))
        let payloads = try await PosterBoard.compile(
            selection: selection,
            templates: [],
            structureVersion: fetched.structureVersion,
            database: fetched.database,
            preservedPayloads: fetched.preservedPayloads,
            includeSnapshotFiles: fetched.snapshotDirectory == nil,
            deviceVersion: deviceVersion,
            workingDirectory: PosterBoard.workDirectory,
            log: log)
        guard !payloads.isEmpty else {
            throw DriftRestoreError("这次没有可刷入的内容，干跑停下。")
        }
        AppLog.write("restore dry run: compiled \(payloads.count) payload(s)")

        // Post-pull encryption verdict (see the preflight note above),
        // read off the manifest the fetch pull just brought back.
        // Nothing has been written to the device — the pull only reads —
        // so stopping here is still stopping before anything happened.
        guard Self.pulledManifestParses(
            deviceDir: AppPaths.deviceDir(backupRoot: AppPaths.posterBoardFetchRoot,
                                          udid: udid)) else {
            throw DriftRestoreError("拉回来的备份清单打不开，多半是这台设备开着「加密本地备份」。请先在电脑的 Finder 或 iTunes 里关掉「加密本地备份」，再重试；如果本来就没开，请把日志传上来。")
        }

        // The restore base, derived locally from the fetch pull (build
        // 4, 2026-11-21 — the two pulls merged into one session). The
        // dry run used to open a second backup session here (the
        // protective pull) whose only product the rest of the run
        // consumed was the device-produced Manifest.db in a root of
        // its own; that same manifest is already on disk in the fetch
        // root, so the base is now assembled, not pulled. The package
        // the prune below produces is unchanged: this root still holds
        // no PosterBoard payloads, so the domain's file rows drop at
        // prune time and are re-imported from the fetch snapshot by
        // the merge, exactly as when the base came from its own pull.
        let backupRoot = AppPaths.fullBackupRoot(udid: udid)
        try Self.deriveRestoreBase(
            backupRoot: backupRoot, udid: udid,
            from: AppPaths.deviceDir(backupRoot: AppPaths.posterBoardFetchRoot,
                                     udid: udid))

        // Prune to the single domain, merge the snapshot's native rows
        // for the delivering set, inject the compiled payloads.
        try await BackupInjector.pruneAndInject(
            backupRoot: backupRoot,
            udid: udid,
            tweakPayloads: payloads,
            posterBoardSnapshot: fetched.snapshotDirectory,
            prune: true)

        // The audit is a gate, not a report: an inconsistent package is
        // not prepared for write-back at all.
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        let audit = ManifestStore(deviceDir: deviceDir).auditAgainstDisk()
        AppLog.write(audit)
        guard audit.contains("— consistent") else {
            throw DriftRestoreError("干跑对账没过：恢复包和清单对不上，这次停下，没有准备写回。详情看日志。")
        }

        let fingerprint = try RestoreFingerprint.compute(
            deviceDir: deviceDir, udid: udid,
            version: deviceVersion, build: buildVersion)
        let report = RestoreDryRunReport(
            version: deviceVersion,
            buildVersion: buildVersion,
            payloadCount: payloads.count,
            packageFileCount: fingerprint.payloadFileCount,
            packageBytes: fingerprint.payloadBytes,
            auditLine: audit,
            fingerprintShort: fingerprint.short,
            packNames: selection.tendies.map(\.name),
            packFiles: selection.tendies.map { $0.url.lastPathComponent })
        prepared = Prepared(report: report, fingerprint: fingerprint,
                            backupRoot: backupRoot, deviceDir: deviceDir,
                            udid: udid)
        AppLog.write("restore dry run prepared: \(fingerprint.payloadFileCount) payload file(s), "
            + "fingerprint \(fingerprint.short) — awaiting the separate write-back confirmation")
        return report
    }

    /// Whether the device-produced `Manifest.db` in `deviceDir` is a
    /// readable SQLite database holding a `Files` table. An encrypted
    /// backup's manifest arrives encrypted end to end — it does not even
    /// carry the SQLite header — so this reads the device's own evidence
    /// rather than a preference the host asked about beforehand.
    private static func pulledManifestParses(deviceDir: URL) -> Bool {
        pulledManifestFilesCount(deviceDir: deviceDir) != nil
    }

    /// One stage of a failed SQLite call, in the log's own terms:
    /// result code, extended code and SQLite's message.
    private static func sqliteStage(_ db: OpaquePointer?, _ rc: Int32) -> String {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
        let extended = db.map { sqlite3_extended_errcode($0) } ?? rc
        return "rc \(rc), extended \(extended), \(message)"
    }

    /// Open the pulled manifest and count its `Files` rows, logging
    /// every stage that fails with SQLite's own error codes.
    ///
    /// Two passes on purpose (build 5, 2026-11-21). The first is the
    /// read-only open this gate used before, kept as a log-only probe:
    /// its failure code is the evidence for WHY a WAL-mode manifest
    /// refuses a read-only reader (SQLITE_READONLY_CANTINIT /
    /// _READONLY_RECOVERY), and dropping it would leave that diagnosis
    /// a guess. The verdict itself reads read-write, like the
    /// snapshot's own reader — a WAL-mode manifest needs its
    /// bookkeeping initialised before it can be read at all — and this
    /// copy is a working copy: the device can always pull it again.
    private static func pulledManifestFilesCount(deviceDir: URL) -> Int? {
        let url = deviceDir.appendingPathComponent("Manifest.db")
        let magic = Data("SQLite format 3\u{0}".utf8)
        guard let head = try? FileHandle(forReadingFrom: url) else { return nil }
        let first = try? head.read(upToCount: magic.count)
        try? head.close()
        guard first == magic else { return nil }

        var probe: OpaquePointer?
        let probeRC = sqlite3_open_v2(url.path, &probe, SQLITE_OPEN_READONLY, nil)
        if probeRC == SQLITE_OK, let probe {
            var probeStmt: OpaquePointer?
            let prepareRC = sqlite3_prepare_v2(probe, "SELECT COUNT(*) FROM Files",
                                               -1, &probeStmt, nil)
            if prepareRC != SQLITE_OK {
                AppLog.write("manifest probe: read-only prepare failed — "
                    + sqliteStage(probe, prepareRC))
            }
            sqlite3_finalize(probeStmt)
            sqlite3_close(probe)
        } else {
            AppLog.write("manifest probe: read-only open failed — "
                + sqliteStage(probe, probeRC))
            sqlite3_close(probe)
        }

        var db: OpaquePointer?
        let openRC = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
        guard openRC == SQLITE_OK, let db else {
            AppLog.write("manifest verdict: read-write open failed — "
                + sqliteStage(db, openRC))
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let prepareRC = sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM Files",
                                           -1, &stmt, nil)
        guard prepareRC == SQLITE_OK, let stmt else {
            AppLog.write("manifest verdict: prepare failed — "
                + sqliteStage(db, prepareRC))
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_ROW else {
            AppLog.write("manifest verdict: count step failed — "
                + sqliteStage(db, stepRC))
            return nil
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Assemble the restore base in `backupRoot` from a manifest a
    /// pull already brought back (build 4, 2026-11-21: the dry run's
    /// second session, retired). Fresh host seeds first — the same
    /// `reset` + full-backup `ensure` the protective pull seeded its
    /// own root with — then the device's own `Manifest.db`, with its
    /// WAL sidecars, copied over. No seed manifest is written: the
    /// empty SQLite database `writeSQLiteManifest` would plant exists
    /// only to be handed to a device at a session's start, and there
    /// is no session here.
    private static func deriveRestoreBase(backupRoot: URL, udid: String,
                                          from sourceDeviceDir: URL) throws {
        // Quiescence assertion (build 5, 2026-11-21): the copy below
        // must not lift a manifest whose WAL still holds unmerged
        // pages — copying the main file alone would silently drop
        // them. The pull session is over, so the device is not
        // writing; the only thing that could still hold the WAL open
        // is this app itself. Checkpoint explicitly, verify the
        // close, and refuse to copy while a non-empty -wal remains.
        let fmEarly = FileManager.default
        let sourceManifest = sourceDeviceDir.appendingPathComponent("Manifest.db")
        var qdb: OpaquePointer?
        let qOpenRC = sqlite3_open_v2(sourceManifest.path, &qdb,
                                      SQLITE_OPEN_READWRITE, nil)
        guard qOpenRC == SQLITE_OK, let qdb else {
            AppLog.write("restore base: quiescence open failed — "
                + sqliteStage(qdb, qOpenRC))
            sqlite3_close(qdb)
            throw DriftRestoreError("拉回来的备份清单还没写完，这次停下，没有准备写回。请把日志传上来。")
        }
        let checkpointRC = sqlite3_wal_checkpoint_v2(qdb, nil,
                                                     SQLITE_CHECKPOINT_TRUNCATE,
                                                     nil, nil)
        let qCloseRC = sqlite3_close(qdb)
        if checkpointRC != SQLITE_OK || qCloseRC != SQLITE_OK {
            AppLog.write("restore base: quiescence checkpoint rc \(checkpointRC), "
                + "close rc \(qCloseRC)")
        }
        let walURL = sourceDeviceDir.appendingPathComponent("Manifest.db-wal")
        let walSize = (try? fmEarly.attributesOfItem(atPath: walURL.path))?[.size] as? NSNumber
        if let walSize, walSize.int64Value > 0 {
            AppLog.write("restore base: the pulled manifest's WAL still holds "
                + "\(walSize.int64Value) byte(s) after checkpoint — refusing to copy")
            throw DriftRestoreError("拉回来的备份清单还没写完，这次停下，没有准备写回。请把日志传上来。")
        }

        try HostManifests.reset(backupRoot: backupRoot, udid: udid)
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        try HostManifests.ensure(deviceDir: deviceDir, udid: udid, isFullBackup: true)
        let fm = FileManager.default
        for name in ["Manifest.db", "Manifest.db-wal", "Manifest.db-shm"] {
            let source = sourceDeviceDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = deviceDir.appendingPathComponent(name)
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: source, to: destination)
        }
        AppLog.write("restore dry run: restore base derived from the fetch pull "
            + "(one backup session this run) — the device's Manifest.db copied "
            + "into the restore root")
    }

    /// Reconcile a pulled manifest against what actually landed on
    /// disk, and NAME the shortfall (build 4, 2026-11-21).
    ///
    /// The field log of 2026-11-20 ended a pull with the device
    /// refusing the backup (MBErrorDomain/205) over a commit shortfall
    /// of four files out of 26,976 — a count with no names, because
    /// nothing reconciled the manifest against the disk afterwards.
    /// This audit is that reconciliation, run on the fetch root
    /// whether the pull finished or refused: every file row the fetch
    /// filter meant to KEEP (a PosterBoard container file it could
    /// map) whose payload is not on disk is named, one log line each
    /// (first fifty). Rows in every other domain are drained by design
    /// and are only counted, per domain — their absence is the filter
    /// working, not a shortfall. Read-write open, like the snapshot's
    /// own reader: a WAL-mode manifest needs its bookkeeping
    /// initialised before it can be read at all.
    private static func logPullShortfallAudit(deviceDir: URL) async {
        guard pulledManifestParses(deviceDir: deviceDir) else {
            AppLog.write("pull audit: no readable pulled Manifest.db — nothing to reconcile")
            return
        }
        let container = (try? await Minimuxer.shared()
            .appFactoryEntry(bundleId: PosterBoard.bundleID))?["Container"] as? String ?? ""
        var db: OpaquePointer?
        let auditOpenRC = sqlite3_open_v2(
            deviceDir.appendingPathComponent("Manifest.db").path,
            &db, SQLITE_OPEN_READWRITE, nil)
        guard auditOpenRC == SQLITE_OK, let db else {
            AppLog.write("pull audit: could not open the pulled Manifest.db — "
                + sqliteStage(db, auditOpenRC))
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT fileID, domain, relativePath FROM Files WHERE flags = 1",
                                 -1, &stmt, nil) == SQLITE_OK, let stmt else {
            AppLog.write("pull audit: could not read the pulled manifest's file rows")
            return
        }
        defer { sqlite3_finalize(stmt) }
        let fm = FileManager.default
        var present = 0
        var suspects: [String] = []
        var drainedByDomain: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cID = sqlite3_column_text(stmt, 0),
                  let cDomain = sqlite3_column_text(stmt, 1),
                  let cPath = sqlite3_column_text(stmt, 2) else { continue }
            let fileID = String(cString: cID)
            let domain = String(cString: cDomain)
            let relativePath = String(cString: cPath)
            let landed = fm.fileExists(
                atPath: deviceDir.appendingPathComponent("\(fileID.prefix(2))/\(fileID)").path)
                || fm.fileExists(atPath: deviceDir.appendingPathComponent(fileID).path)
            if landed { present += 1; continue }
            if domain == PosterBoard.domain,
               PosterBoardSnapshot.relativePath(deviceName: domain + "/" + relativePath,
                                                container: container) != nil {
                suspects.append(relativePath)
            } else {
                drainedByDomain[domain, default: 0] += 1
            }
        }
        let drainedTotal = drainedByDomain.values.reduce(0, +)
        AppLog.write("pull audit: \(present) file payload(s) on disk; "
            + "\(suspects.count) PosterBoard file row(s) the pull meant to keep "
            + "are missing"
            + (drainedTotal > 0
                ? "; \(drainedTotal) other file row(s) drained by design"
                : ""))
        for name in suspects.prefix(50) {
            AppLog.write("pull audit: missing kept file — \(name)")
        }
        if suspects.count > 50 {
            AppLog.write("pull audit: … and \(suspects.count - 50) more missing kept file(s)")
        }
        if !drainedByDomain.isEmpty {
            let top = drainedByDomain.sorted { $0.value > $1.value }.prefix(5)
                .map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            AppLog.write("pull audit: drained rows by domain (top): \(top)")
        }
    }

    // MARK: - Write-back

    func writeBack() async throws {
        guard let prepared else {
            throw DriftRestoreError("还没有干跑结果，请先干跑一次。")
        }
        // Whatever happens from here, this dry run is spent: a package
        // is written back at most once, and a failed or refused
        // write-back is followed by a fresh dry run, never a retry on
        // the same prepared state.
        self.prepared = nil

        let now = try RestoreFingerprint.compute(
            deviceDir: prepared.deviceDir, udid: prepared.udid,
            version: prepared.report.version, build: prepared.report.buildVersion)
        guard now.digest == prepared.fingerprint.digest else {
            throw DriftRestoreError("干跑之后文件变了（指纹对不上），这次写回取消。请重新干跑一次。")
        }
        AppLog.write("restore write-back: fingerprint re-verified (\(now.short))")

        do {
            _ = try await ChannelRecovery.retry(
                label: "restore",
                attempts: 3,
                diagnostics: { await Diagnostics.report() }
            ) {
                try await RestoreRunner.run(backupRoot: prepared.backupRoot,
                                            sourceIdentifier: prepared.udid)
            }
        } catch {
            let raw = error.localizedDescription
            // The one refusal with a known user-side cause: Find My is
            // still on. There is no programmatic check for it anywhere
            // in the stack, so the device's 211 is where it surfaces.
            if raw.contains("211") {
                throw DriftRestoreError("设备拒绝了恢复，多半是「查找」还开着。先到设置里关掉「查找我的 iPhone」，再重新干跑一次。")
            }
            if raw.contains("205") {
                throw DriftRestoreError("设备说恢复包对不上（205），写回没有完成。请重新干跑一次；还是这样，就把日志包发出来排查。")
            }
            throw DriftRestoreError("写回失败：\(raw)")
        }
        AppLog.write("restore write-back: device confirmed completion")
    }

    /// Throw the prepared dry run away without writing it back. The
    /// working directories are left on disk; the next dry run resets
    /// both roots itself.
    func discard() {
        prepared = nil
    }
}
