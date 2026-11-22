import Foundation
import Minimuxer

/// Stage 1: pull a real mobilebackup2 backup that deliberately excludes
/// photos, videos and app containers.
///
/// Two jobs, and only the first one is about data:
///   1. `FactoryInfo {Applications: {}}` + the mid-stream filter keep the pull
///      small — this is a *protective* backup, not a backup of value.
///   2. It is what triggers the device's Trust / backup-password dialog and
///      establishes an authorized mobilebackup2 session.  Without it iOS 27
///      refuses the later restore from an un-authorized session and just closes
///      the channel (BrokenPipe, no popup).
enum ProtectiveBackup {
    /// Run one protective backup into `<backupRoot>/<udid>/`.
    static func run(
        backupRoot: URL,
        udid: String,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        let minimuxer = Minimuxer.shared()
        AppLog.write("Creating protective backup (no photos/video) at \(backupRoot.path)…")

        // The Rust delegate callbacks are the ONLY host-side window into the
        // mobilebackup2 conversation.  Counting what the device streamed and how
        // far progress got separates "died before the first file" (request /
        // version-exchange / authorization phase) from "died mid-stream"
        // (transfer phase) — two completely different root causes that look
        // identical in the thrown error string.
        let trace = BackupTrace()
        let beat = Heartbeat()
        let stage = StageTimer("protective backup")
        // Prove the transfer is alive: the counters only move when the device
        // actually streams a file, so a heartbeat whose detail stops changing =
        // stalled.  The DL-message count is the second half of that: it moves
        // even in phases where the device uploads nothing but is clearly working.
        beat.start("protective backup") {
            trace.livenessLine() + ", " + WireCensus.healthLine()
        }

        do {
            // The device drops the mobilebackup2 channel as soon as the Trust /
            // backup-password dialog is answered ("Backup failed, error:
            // (Socket(... BrokenPipe, channel closed))").  Retry with escalating
            // recovery instead of aborting.
            try await ChannelRecovery.retry(
                label: "protective backup",
                attempts: 3,
                diagnostics: { await Diagnostics.report() },
                // Wipe ONLY on the first attempt.  The device decides what to
                // upload, so wiping the manifest baseline makes every retry a
                // FULL re-upload of the whole protective set — the single most
                // expensive thing this app does.  A retry on top of the partial
                // baseline is incremental instead.
                // Full backup + a real Manifest.db, on every attempt including
                // the first. Both are what makes the device upload anything at
                // all here: sparse would ask it to send only what a manifest
                // lists, and a manifest it cannot read aborts the transfer
                // before the first payload.
                beforeAttempt: { attempt in
                    if attempt == 1 {
                        try HostManifests.reset(backupRoot: backupRoot, udid: udid)
                    } else {
                        AppLog.write("keeping the partial baseline from attempt \(attempt - 1) "
                            + "(wiping it would force a full re-upload)")
                    }
                    let dir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
                    try HostManifests.ensure(deviceDir: dir, udid: udid, isFullBackup: true)
                    try HostManifests.writeSQLiteManifest(deviceDir: dir, ios27: true)
                    AppLog.write("host manifests ready: full backup, Manifest.db written "
                        + "(\((dir.appendingPathComponent("Manifest.db")).path))")
                }
            ) {
                // 120 s of *nothing* — no host callback AND no DeviceLink message
                // — is a wedged stream, not a slow one.  The idle clock is fed by
                // the Rust delegate callbacks (actual file traffic) plus the wire
                // markers in the Rust log, so a device that is merely busy
                // enumerating the host tree never trips it; if it does go quiet,
                // the out-of-band lockdown probe decides whether to keep waiting
                // (device alive, slow phase) or give up at once (device gone).
                // The ceiling is deliberately modest: a device-side phase that is
                // slow-but-alive resumes within minutes, and past that a fresh
                // attempt on the baseline already on disk beats more waiting — and
                // the run can be stopped by hand at any point anyway.
                try await StallGuard.run(
                    label: "protective backup",
                    idleSeconds: 120,
                    idle: { trace.lastActivityAt },
                    wire: { WireCensus.totals() },
                    probe: { await Diagnostics.deviceLivenessProbe() },
                    handshakeSilent: { RustLog.deviceSilentAtHandshake() }
                ) {
                    try await minimuxer.backupBackup(
                        backupRoot: backupRoot.path(percentEncoded: false),
                        sourceIdentifier: udid,
                        skipAppContainers: true,
                        shouldPreserve: { deviceName, file in
                            // Drift narrowing (Alpha restore line, 2026-11-19):
                            // the wire keeps backup-level metadata ONLY. Every
                            // payload — PosterBoard's included — is drained in
                            // transit; PosterBoard's payloads arrive through
                            // the dedicated fetch pull (PosterBoardBackup), and
                            // no other domain is restored by this line at all.
                            let keep = isMetadataFile(file)
                            trace.note(file: file, domain: deviceName, keep: keep)
                            return keep
                        },
                        onProgress: { overall in
                            // Forward on 5 % steps only.  The callback fires per
                            // file, and the callers used to log every single one:
                            // thousands of lines, and the one that mattered
                            // ("progress: 2 %") scrolled away before the failure.
                            if let step = trace.noteProgress(overall) {
                                AppLog.write("backup stream: \(step)% — \(trace.summary())")
                                onProgress?(overall)
                            }
                        },
                        // Host-side delegate decisions (which staged files we
                        // actually committed vs. deliberately never wrote) exist
                        // only inside the callbacks — pull them into the app log
                        // so a commit shortfall is never silent.
                        delegateLog: { line in AppLog.write(line) }
                    )
                }
                // The device commits a backup by moving every staged file out of
                // `<udid>/Snapshot/`. A non-empty staging tree afterwards means
                // the commit shortfalled — worth knowing before the restore
                // stage runs on top of it.
                // Marker, not decoration.  On 2026-09-19 a run reached 100 %,
                // the delegate logged `filtered payloads: 28490 … removed`, and
                // then goldennugget.log simply stopped — no `protective backup finished`,
                // no stage timer, no crash line.  That left the widest window in
                // this file unexplained: the crash was somewhere between the
                // Rust call's own teardown, the staging walk below, and the log
                // line after it.  This line splits that window in half, so the
                // next failure points at one side of it.
                AppLog.write("backup call returned — device commit done, checking the staging tree…")
                reportStagingLeftovers(backupRoot: backupRoot, udid: udid)
            }
            // A backup that kept nothing is not a successful backup. The pull
            // completes, the manifest is written, and the run then prunes an
            // empty set and restores nothing -- which looks identical to "the
            // backup did not happen" and says nothing about why. On iOS 27 this
            // is the failure mode when `shouldPreserve` no longer matches the
            // domain names the device reports, so the sample lines go out with
            // the error: they are the only record of what the device called the
            // domains that got dropped.
            guard trace.kept > 0 else {
                // Two failures look identical from the outside and need opposite
                // fixes, so they are named separately rather than guessed at:
                //
                //   total == 0  the host delegate never fired at all. The device
                //                streamed nothing we were asked to judge, so the
                //                filter is not what is wrong -- the transfer shape
                //                on iOS 27 is.
                //   total  > 0  the filter rejected every name the device used.
                //                The sample lines below are then the only record
                //                of what the device actually called its domains.
                let cause = trace.total == 0
                    ? "the host keep-filter callback was never called, so the device streamed "
                        + "nothing to judge — the filter is not the problem. The device refused "
                        + "the session before naming a payload; host free space on the backup "
                        + "volume: \(Self.freeSpaceDescription()). A planned upload larger than "
                        + "that, even one this filter would have drained, is refused with "
                        + "MBErrorDomain/105 after DLMessagePurgeDiskSpace — the device measures "
                        + "what it would send against the volume the backup root lives on."
                    : "the keep-filter rejected all \(trace.total) name(s) the device used"
                AppLog.write("protective backup kept 0 of \(trace.total) file(s) — \(cause)")
                AppLog.write("domains: \(trace.domainSummary())")
                for line in trace.sampleLines() { AppLog.write(line) }
                if trace.total == 0 {
                    AppLog.write("Rust log tail, to see what the device did stream:")
                    AppLog.write(RustLog.excerpt())
                }
                beat.stop()
                stage.done("FAILED — kept 0 files")
                throw DriftRestoreError("Protective backup kept no files: \(cause). "
                    + "Domains: \(trace.domainSummary())")
            }
            AppLog.write("protective backup finished — \(trace.summary())")
            beat.stop()
            stage.done(trace.summary())
        } catch {
            beat.stop()
            stage.done("FAILED — \(trace.summary())")
            AppLog.write("protective backup FAILED — \(trace.summary())")
            for line in trace.sampleLines() { AppLog.write(line) }
            // The Rust side is the only place that knows WHY the flow died, and
            // every candidate has its own literal: RST (device reset), "timed
            // out after N retransmissions" (our writes unACKed -> dead path),
            // FIN (silent), or a delegate failure ("Failed to send file").
            AppLog.write(RustLog.excerpt())
            // `Socket(... BrokenPipe, "channel closed")` is jktcp's generic
            // report for "that TCP flow is gone" — the userspace stack drops its
            // per-port sender when the connection is torn down, so a DEVICE-SIDE
            // close and a local pump failure look identical here.  It therefore
            // cannot be read as "the device refused us".
            AppLog.write("note: \"channel closed\" is jktcp's generic flow-closed report — it does not "
                + "distinguish a device-side teardown from a local stack failure. See minimuxer.log "
                + "(Rust, DEBUG) for the real step.")
            throw error
        }
    }

    /// Free space on the volume the backup root lives on, as one printable line.
    ///
    /// The device's own free-space check measures this exact number, so every
    /// "the device offered nothing" message quotes it: with `MBErrorDomain/105`
    /// that figure is the whole explanation, and without it the same message
    /// sends the reader after the keep-filter. Read off the volume holding the
    /// app's Documents directory, which is where every backup root lives.
    static func freeSpaceDescription() -> String {
        let url = URL.documents
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let bytes = attrs[.systemFreeSize] as? NSNumber {
            return ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file)
        }
        return "unreadable"
    }

    /// Count what is left in the device's staging tree after the commit step.
    ///
    /// The device ends a backup with a `DLMessageMoveItems` batch that renames
    /// every file it staged under `<udid>/Snapshot/...` into its final shard
    /// path.  Files rejected by the mid-stream filter are deliberately never
    /// written, so the host skips their move (see `mb2_rename`); their rows are
    /// dropped by the prune because the payload is absent.  Anything else still
    /// sitting there is a genuine shortfall, and the restore that follows would be
    /// built on a partial backup — so report the size of the leftovers.
    private static func reportStagingLeftovers(backupRoot: URL, udid: String) {
        let snapshot = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
            .appendingPathComponent("Snapshot")
        let fm = FileManager.default
        guard fm.fileExists(atPath: snapshot.path) else {
            AppLog.write("staging: no Snapshot/ tree was left behind — the device drained it")
            return
        }
        var files = 0
        var dirs = 0
        if let walker = fm.enumerator(atPath: snapshot.path) {
            for case let item as String in walker {
                var isDir: ObjCBool = false
                let full = snapshot.appendingPathComponent(item).path
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue { dirs += 1 } else { files += 1 }
            }
        }
        if files == 0 {
            AppLog.write("staging: Snapshot/ still exists but holds no files (\(dirs) empty dirs) — "
                + "every staged payload landed")
        } else {
            AppLog.write("staging: ⚠️ \(files) file(s) left under Snapshot/ (\(dirs) dirs) — staged but "
                + "never committed. Filtered payloads are expected here; if the prune does not "
                + "account for them the restore will fail.")
        }
    }
}

// MARK: - The protective keep-set (mirrors GoldenNugget's filter)

extension ProtectiveBackup {
    /// The wire keep-set, narrowed to metadata for Drift's restore line.
    ///
    /// The reference keeps a protective set of payloads on the wire
    /// (SystemPreferences / Messages / slices of HomeDomain). Drift's
    /// restore touches exactly one domain — PosterBoard's — and those
    /// payloads arrive through the dedicated fetch pull, so here the only
    /// names preserved mid-stream are the backup-level metadata files
    /// (`isMetadataFile`); everything else is drained and never written.

    /// Backup metadata files always preserved regardless of the keep-set,
    /// mirroring pymobiledevice3's BACKUP_METADATA_FILES.
    static func isMetadataFile(_ name: String) -> Bool {
        let base = name.split(separator: "/").last.map(String.init) ?? name
        return ["Info.plist", "Manifest.plist", "Manifest.db",
                "Manifest.db-shm", "Manifest.db-wal", "Status.plist"].contains(base)
    }

}

// MARK: - The keep-set in MANIFEST coordinates (Drift: single-domain)
//
// The prune's row-level predicate, in the `(domain, relativePath)` pair a
// Manifest.db row carries. The reference's set spans several system domains
// because the reference restores them; Drift's restore line exists to change
// the wallpaper and nothing else, so the set is exactly one domain —
// PosterBoard's — root row included.
//
// Two layers, deliberately (plan, 2026-11-19): this predicate decides which
// rows may survive at all, and the prune's own payload test still applies on
// top of it — a `flags == 1` row whose payload is not on disk is dropped even
// in this domain (a file row without a payload is what the device reports as
// MBErrorDomain/205). PosterBoard's payloads are not in this backup root —
// they live in the fetch root — so at prune time the domain's file rows drop
// here and are re-imported from the snapshot by the merge that follows; its
// directory rows survive, which is the scaffolding the restore agent needs.
//
// Every other domain's rows are deleted from the manifest. That is safe to
// hand back only because the restore runs with RemoveItemsNotRestored=false
// (the vendored Rust default, verified): the device does not remove files a
// backup does not mention.

extension ProtectiveBackup {
    /// The one domain this line restores — kept whole, root row included.
    static func isProtectiveEntry(domain: String, relativePath: String) -> Bool {
        domain == PosterBoard.domain
    }

    /// The prune's row-level wrap: the PosterBoard domain, nothing else.
    static func keepsRow(domain: String, relativePath: String) -> Bool {
        isProtectiveEntry(domain: domain, relativePath: relativePath)
    }

    /// A stable fingerprint of the keep-set, so a retained baseline could tell
    /// whether the rules that produced it still name the same files. Only the
    /// rule inputs are hashed, in a fixed order.
    static var keepSetHash: String {
        ManifestStore.sha1Hex("domain:\(PosterBoard.domain)\nroot:\(PosterBoard.domain)")
    }
}
