# Vendored upstream core — AirliftFFI

The entire contents of this directory (`Cargo.toml`, `Cargo.lock`,
`src/`, `include/`, `vendor/`) are a verbatim copy of the `rust-core/`
directory of the AirCard-iOS project:

- Project: AirCard-iOS — https://github.com/Mak5er/AirCard-iOS
- Author: Johnny Franks (Mak5er)
- Upstream commit: 40640c4d827aeab8d798285b57d24fcf6be070d0 (v1.3.2)
- License: MIT License, Copyright (c) 2026 Johnny Franks (see the
  repository-root NOTICE and the upstream LICENSE)

Vendored on 2026-10-30, replacing CocoWall's own reimplemented write
path (tunnel / staging / AirTraffic sync), which behaved identically
in every audited respect yet failed to inject on device where the
upstream app succeeds on the same phone and package. From this point
the write path is the upstream implementation itself, not a rewrite.

Local modifications to the vendored tree: NONE until 2026-11-01. First
local source change, 2026-11-01 (Sage-approved poster_refresh feature,
registered in SPEC.md):

- ADDED `src/poster_refresh.rs` — new module implementing a
  PosterBoard-only refresh over the RSD tunnel (DVT
  com.apple.instruments.dtservicehub -> processcontrol channel ->
  killPid: on the PosterBoard daemon, then liveness verification via
  deviceinfo). Uses only the already-vendored `idevice` crate's DVT
  clients; no upstream file was altered to build it.
- `src/lib.rs` — pure additions only: `pub mod poster_refresh;` and the
  new FFI export `al_poster_refresh` (with its catch_unwind wrapper).
  No existing line changed.
- `include/airlift.h` — pure addition only: the `al_poster_refresh`
  declaration next to `al_device_respring`. No existing line changed.

Second local source change, 2026-11-01 (Sage-approved device poster
store detect/cleanup feature, registered in SPEC.md):

- ADDED `src/poster_store.rs` — new module implementing enumeration
  and deletion of the descriptors actually present in the device's
  PRBPosterExtensionDataStore, over the RSD tunnel. Enumeration and
  auditing go through AFC (com.apple.afc.shim.remote): a temporary
  symlink is planted in the AFC media jail pointing at the store's
  Extensions directory, and descriptors are listed/read through it.
  Planting mechanism (revised 2026-11-01, run #107 hardware log):
  the AFC MakeLink operation is refused by the RSD AFC service
  (OpNotSupported), so the link is planted the flash way — a
  StreamingZip archive (same builder shape as the delete staging)
  whose symlink entry streaming_zip_conduit extracts into a scratch
  Media subdir, then an AFC rename moves the extracted symlink to
  the Media root, the geometry its ../../../ target is calibrated
  for. (Revised again later the same day, run #108 hardware log:
  the rename step is refused too (InvalidArg) and the flash flow
  never renames — its root-level link is landed by the ATC sync —
  so the link now stays at its staged depth inside the scratch
  subdir and the archive's symlink target is computed for that
  depth: six ../ to /var plus the container tail (variant
  `relative-depth`); if that does not traverse, an archive with
  the plain absolute target is staged and tried in the same
  session (variant `absolute`). The archive builder's link target
  is a parameter; the delete flow passes the original
  root-calibrated target unchanged.) (Diagnostic revision, run
  #110: both #109 target variants failed the staged-presence
  check on device while the #108 archive passed it; the only
  staging delta is the symlink target string, and AFC
  get_file_info is lstat-like, so the conduit extractor
  dropping escape-target symlinks is the leading but unproven
  mechanism. plant_store_link's verification-failure branch
  now logs a level-by-level enumeration of the extracted
  staging tree (stage.diag lines) before cleanup; behavior
  otherwise unchanged.) (Third revision, run #111: the #110
  diag log settled it — for BOTH escaping-target variants the
  entire scratch tree (root, p0/p1/p2, payload) read back
  Afc(ObjectNotFound) across repeated rounds, while the flash
  staging with the ../../../ geometry extracts on the same
  device every time; line-by-line comparison against
  exploit.rs showed the upload wire steps (MediaSubdir init,
  archive write, 4-byte + body response read, drop, RSD
  connect_service, AFC verification client) were already
  identical, the ONLY functional delta being the archive's
  symlink target string, so the conduit evidently refuses or
  rolls back archives whose symlink target leaves the
  extraction root. Staging verification now matches exploit's
  three-object check (dir + link + payload), and the variant
  order is: `exploit-geometry` (../../../<tail>) first, the
  #109 `relative-depth` and `absolute` targets retained as
  fallbacks. Acceptance additionally requires listing through
  the planted link to return a NON-EMPTY Extensions listing:
  at staged depth the flash geometry resolves into the
  archive's own mirrored tail tree (empty at the Extensions
  level), which must not be enumerated as the store. The
  stage.diag logging is retained.) Deletion does NOT erase through AFC: each
  descriptor is moved out of the store by an AirTraffic/Books sync
  whose two books (staging link + the descriptor, identified by its
  Airlock-escaping relative path) make the on-device ATAirlock daemon
  download it into Media as an `airlift-quarantine-<token>` copy —
  the Walllive-verified airlift.delete mechanism; the ATC wire flow
  mirrors `exploit::run`'s, reusing the crate-public
  `crate::grappa::generate_grappa_token`. A fresh-connection audit
  must re-confirm each deleted path absent. Uses only the
  already-vendored `idevice` crate; no upstream file was altered.
- `src/poster_refresh.rs` — one branch added (same change series):
  in the identity stage, a successfully read process list with no
  PosterBoard entry now returns confirmed with an
  `already_stopped` log line (Walllive parity) instead of a
  pidNotFound failure. No other line changed. (Run #111: the
  absence verdict now requires a second process-list read 500ms
  after the first — logged as `already_stopped.recheck
  attempt=1` — because run #109's single-snapshot
  already_stopped confirmation was followed by the wallpaper
  not appearing until a manual respring; if the re-read finds
  PosterBoard, the normal signal path proceeds. The kill-path
  verification logic is unchanged.)
- `src/lib.rs` — pure additions only: `pub mod poster_store;` and the
  new FFI exports `al_poster_store_list` / `al_poster_store_delete`
  (with catch_unwind wrappers). No existing line changed.
- `include/airlift.h` — pure additions only: the two declarations
  next to `al_poster_refresh`. No existing line changed.

Third local source change, 2026-11-01 (poster_refresh signal fix,
registered in SPEC.md). This is the first change that touches a
vendored upstream file itself — additively only:

- `vendor/idevice/src/services/dvt/process_control.rs` — ADDED one
  method, `ProcessControlClient::send_signal(pid, signal)`, sending
  the DTX ProcessControl selector `sendSignal:toPid:` (aux args:
  signal first, then pid, mirroring the selector; wire shape mirrors
  the adjacent upstream `kill_app`). No existing line changed;
  `kill_app` (`killPid:`) is untouched. Reason: on hardware (run
  #106) `killPid:` was acknowledged by the service but did not
  terminate the PosterBoard daemon — it only takes effect on
  processes the instruments server itself spawned. Walllive's
  binary carries the `sendSignal:toPid:` selector string in its
  processcontrol cluster; it is the call that actually delivers
  the signal. (The DVT Channel inside ProcessControlClient is
  crate-private, so the vendored client is the only clean place
  to add the call.)
- `src/poster_refresh.rs` — the signal stage now calls
  `send_signal(pid, 9)` instead of `kill_app(pid)`; a send failure
  maps to status killFailed with the original error. Header docs
  corrected. Identity / already_stopped / fresh-connection verify /
  status honesty all unchanged.

Revision of the same addition, later the same day (run #107
hardware log; registered in SPEC.md in the signal-reply section):

- Upstream check: jkcoxson/idevice master @ 8970209 was cloned and
  its `idevice/src/services/dvt/process_control.rs` read line by
  line — upstream has NO sendSignal method at all (only `killPid:`
  at line 289); apart from this local addition the vendored file
  is byte-identical to upstream master. There is therefore no
  upstream form to port; the method stays a local addition.
- `send_signal` changed from the fire-and-forget form above
  (`call_method(..., expect_reply=false)`, returning `()`) to a
  request–reply form: `call_method_with_reply`, returning the
  reply payload as `Result<Option<Value>, IdeviceError>`. Selector
  and aux encoding unchanged (selector `sendSignal:toPid:`, aux
  [U32 signal, U32 pid]). Shape aligned with pymobiledevice3's
  ProcessControlService, which declares `sendSignal:toPid:`
  without `expects_reply=False` and documents its `kill()` as
  relying on the round-trip — a one-way call can be silently
  dropped over the userspace tunnel, leaving the target alive
  (observed verbatim in runs #106/#107).
- `src/poster_refresh.rs` — the signal stage awaits the reply
  under a 10s timeout, logs it verbatim as
  `airlift.poster_refresh.signal.reply data=…`, and only then logs
  signal.acknowledged; a reply timeout is logged and the flow
  proceeds to fresh-connection verification (the ground truth)
  instead of failing the kill outright; a transport-level error
  still maps to killFailed with the original error.

Second revision of the same addition, later the same day (run
#108 hardware log; registered in SPEC.md in the
receipt-classification section):

- The vendored `send_signal` body is unchanged. What the #108
  hardware log showed is a classification problem one layer up:
  the service DID reply (the message was dispatched and handled),
  but the DTX reply parser classified the payload as
  `IdeviceError::UnexpectedResponse`, and `poster_refresh.rs`
  mapped ANY send error to killFailed and skipped verification —
  the pid's fate was never checked.
- `src/poster_refresh.rs` now splits the awaited-reply result
  three ways: a parsed reply payload proceeds as before; an
  `UnexpectedResponse` error logs `signal.reply
  unexpected_response=true (dispatch confirmed by response;
  deferring to verification)` and proceeds to fresh-connection
  verification as if delivered; only channel/connection-level
  errors (the message never left) still map to killFailed with
  the original error. Verification alone decides the outcome.

Third revision of the same addition, later the same day (run
#111; registered in SPEC.md in the aux-encoding section):

- The aux ENCODING of `send_signal` changed: from raw integer
  primitives `[U32 signal, U32 pid]` (wire type 3) to
  NSKeyedArchiver-archived NSNumbers in type-0x02 buffer aux
  entries, via the in-tree `AuxValue::archived_value`
  (precedent: `energy_monitor::archive_pids`). Selector,
  argument order (signal, pid), and the awaited-reply call are
  unchanged. Basis, from pymobiledevice3 master
  (doronz88/pymobiledevice3 @ 5234545, read 2026-11-01):
  `services/dvt/instruments/process_control.py` declares
  `send_signal_to_pid_(self, sig: int, pid: int)` with plain
  `int` annotations, pointedly NOT the `PInt32` primitive
  wrapper it uses for `request_disable_memory_limits_for_pid_`
  in the same file; and `dtx/message_aux.py`'s
  `MessageAux.build` translates every non-primitive argument
  into an NSKeyedArchiver-encoded blob — so pymobiledevice3
  sends both values as archived NSNumbers. Hardware motive:
  with the U32-primitive shape the service twice rejected the
  message itself (UnexpectedResponse reply, run #108;
  server-side BrokenPipe the moment the signal was sent, run
  #110) while a string-argument call on the same channel
  worked — the message shape, not the transport, was refused.

Fourth local source change, 2026-11-01 (run #112, registered in
SPEC.md in the Walllive-transaction section):

- `src/exploit.rs` — pure additions only, no existing function
  changed: a Walllive-shaped install transaction
  (`exploit_flash_transaction` + `flash_transaction` FFI wrapper)
  that, inside one tunnel connection and one Books
  snapshot/restore cycle, injects one descriptor folder into the
  PRIMARY store spot only (mirror spot deferred), then writes the
  reload-preferences file to both preference targets in a single
  combined staging + AirTraffic session, then restores Books
  (with a read-back verify the older per-operation paths never
  did). New helpers: `wait_move_settle` (per-FileComplete AFC
  destination poll, Walllive's atc.move.settle wait),
  `stage_via_conduit`, `write_books_plist`,
  `restore_books_state`, `run_atc_asset_session`,
  `flash_transaction_phases`, and `build_archive_two_links`
  (archive with two symlinks in the same p0/p1/p2 directory —
  `link` and `link_1`, the shape Walllive's combined-preferences
  sync uses). The subsequent poster_refresh stays a separate
  FFI call: this surface has no persistent session handle, so
  Walllive's connection=reused refresh is not cloned.
- `src/lib.rs` — pure addition only: the
  `al_exploit_flash_transaction` export.
- `include/airlift.h` — pure addition only: the
  `al_exploit_flash_transaction` declaration.

Fifth local source change, 2026-11-01 (run #113, registered in
SPEC.md in the two-links dedupe section):

- `src/exploit.rs` — one-function fix inside the run-#112
  addition `build_archive_two_links`: its target-directory
  component loop wrote the directory chain of both preference
  tails in full, re-adding the shared prefix entries (`var/`,
  `var/mobile/`), and zip rejects duplicate entry names
  ("Duplicate filename") at local archive-build time — the
  #112 device run died there before upload. The loop now keeps
  a HashSet of already-added directory names and writes each
  shared directory once. The archive layout is otherwise
  unchanged: `link`/`link_1` symlink targets
  (`../../../<tail>`) and `payload_0`/`payload_1` are exactly
  as shipped in run #112.

Sixth local source change, 2026-11-01 (run #114, registered in
SPEC.md in the poster_store DVT transport section):

- `src/poster_store.rs` — the list/audit transport is replaced.
  Enumeration and both delete audits (pre-audit and fresh commit
  audit) no longer plant an AFC staging symlink: they open a DVT
  RemoteServer on the same RSD tunnel and call
  `directoryListingForPath:` (deviceinfo channel) with the
  store's absolute path, via the vendored
  `DeviceInfoClient::directory_listing` — the mechanism recovered
  from the Walllive 1.1.1 binary (its
  `posterboard_clear_audit` module, `DvtDirectorySession`). The
  staging machinery (`open_store_session`, `plant_store_link`,
  `upload_stage_archive`, the three symlink-target variants) is
  removed. Consequences: the list flow builds no archive and
  touches no Books state; the JSON `identifier` field is now
  empty (the identifier file is not readable over DVT; package
  names still come from listing versions/<v>/contents/). The
  delete MOVE itself is unchanged — `delete_operation` and
  `build_delete_archive` are byte-identical; only its audits
  moved from the AFC link to DVT. No vendored file changed; the
  #112/#113 transaction and signal code is untouched.

Seventh local source change, 2026-11-01 (run #115, registered in
SPEC.md in the cleanup-scope + quarantine-recovery section):

- `src/poster_store.rs` — (A) cleanup scope: list/delete are
  restricted to the two CollectionsPoster providers
  (`CLEANUP_SCOPE_PROVIDERS`, exact match); out-of-scope providers
  are filtered from enumeration and hard-blocked in the delete
  driver before any audit/ATC work, with `#[cfg(test)]`
  assertion-level tests for the predicate. (B) quarantine
  recovery: new `store_quarantine_list` (AFC scan of Media-root
  `airlift-quarantine-*` folders — descriptor-root shape
  detection, package name / descriptor identifier / provider
  guess reads) and `store_restore` with `restore_operation`, a
  line-level mirror of `delete_operation` running the same ATC
  mechanism in reverse (delete's operation and archive builder
  remain byte-identical), DVT-audited, with quarantine cleanup
  gated on the fresh audit. Two new module FFIs
  (`poster_store_quarantine_list`, `poster_store_restore`);
  matching wrappers in `src/lib.rs` and declarations in
  `include/airlift.h`. Restore is deliberately NOT scope-limited.
- `src/exploit.rs` — settle tri-state: `wait_move_settle` now
  returns `SettleOutcome` (log lines unchanged), and the combined
  preferences session's file assets settle via the new
  `wait_file_asset_settle` (directory-listing observation, 1500 ms
  budget, honest `skipped` outcome) instead of the destination
  poll that deterministically timed out at 5000 ms on device.
  The #111 signal encoding and the #112/#113 transaction skeleton
  are untouched; no vendored file changed.

Run #122 (2026-11-01) removes the run #121 (B) quarantine-recovery
surface again, on the project owner's decision that the feature is
not wanted: `store_quarantine_list`, `store_restore` and
`restore_operation` are deleted from `src/poster_store.rs`, the
FFIs `poster_store_quarantine_list` / `poster_store_restore` from
`src/poster_store.rs` and their `al_poster_store_*` wrappers from
`src/lib.rs`, and the declarations from `include/airlift.h`. The
(A) cleanup scope limit stays. `delete_operation` and
`build_delete_archive` remain byte-identical — delete still moves
descriptors into Media `airlift-quarantine-*` folders (a safety
property of the delete mechanism itself, not the removed restore
feature).

Run #147 (2026-11-03, Sage-approved wait/session optimization of
the measured flash/cleanup paths, registered in SPEC.md; timings
from the run #146 device log):

- `src/exploit.rs` — two constant-level changes inside the run
  #112 transaction path only. (A) `wait_file_asset_settle`: the
  file-asset listing-observation budget drops 1500 ms -> 150 ms
  (poll 100 ms -> 50 ms). Device evidence: the observation never
  once succeeded (16/16 waits burned the full budget and returned
  Skipped), so the wait was dead time, not verification; the
  outcome taxonomy, log lines, and the session verdict's
  independence from this wait are unchanged, as is
  `wait_move_settle` (5000 ms fallback). (B)
  `run_atc_asset_session`: the fixed post-session drain drops
  2 s -> 150 ms — the log shows it as the entire ~2 s silent tail
  of both sessions of every flash. The legacy per-operation paths
  keep their own 2 s sleeps untouched.
- `src/poster_store.rs` — the delete transport is batched:
  `delete_operation` (one full tunnel/ATC cycle per target) is
  replaced by `stage_delete_target` + `run_delete_session` +
  `delete_batch`, which share one tunnel, one Books
  snapshot/restore and one ATC session across all present
  targets, with a combined Books.plist carrying each target's
  link + descriptor pair. Per-target mechanism, quarantine
  destinations, confirmations, manifest-refusal behavior (now
  scoped to the refused target only), deleted/failed accounting
  and the run #115 scope hard block are unchanged; the batch also
  restores Books on session-failure exits (the per-target cycle
  skipped the restore on its error returns). No FFI signature
  changed; `src/lib.rs` and `include/airlift.h` untouched.

Apart from the additions registered above, everything else in this
tree remains a verbatim copy of upstream.
The other adaptations live outside this directory:

- `ci/build-rust-core.sh` builds this crate for `aarch64-apple-ios`
  and the app links `libairlift_ffi.a` directly (upstream packages an
  xcframework instead; the produced static library is the same).
- `Sources/App/GrappaHelper.h` / `GrappaHelper.m` are the upstream
  app-side helper, copied verbatim from the same commit — the core
  resolves its `ALGetGrappaToken` symbol at runtime via `dlsym`.
- The Swift call layer (`DeviceService.swift`, `TendiesFlash.swift`)
  mirrors upstream `TendiesEngine.swift`'s call sites and arguments.

---

Drift 2.0.0 transplant note (2026-11-11)
----------------------------------------
- `src/poster_store.rs` was transplanted verbatim from the CocoWall
  tree (soci-art/cocowall, `rust-core/src/poster_store.rs`), together
  with its `lib.rs` FFI exports (`al_poster_store_list`,
  `al_poster_store_delete`) and the matching `include/airlift.h`
  declarations.
- Drift-side local additions already present in this tree are kept
  as-is: the "Last working route cache" in `src/exploit.rs` and the
  `plist_ffi` `[patch.crates-io]` section in `Cargo.toml` were NOT
  touched by the transplant. `src/exploit.rs` and `Cargo.toml` are
  byte-identical to the Drift 1.3.0 baseline.
- Target-host interfaces NOT transplanted (ruling, 2026-11-11,
  FEEDBACK #60): the CocoWall-side `al_set_target_host`,
  `al_set_target_hosts` and `al_clear_target_hosts` FFI were briefly
  ported and then removed again, and `src/exploit.rs` was restored
  byte-identical to the 1.3.0 baseline. Rationale: Drift's own
  route-cache already pins the working host, `poster_store.rs` does
  not depend on the target-host symbols (it uses the route-cache
  group), nothing in Drift consumes those three FFI, and the wiring
  edit that would have connected them into the tunnel candidate walk
  was refused by the safety policy. This deviates from checklist
  §3.3's "five declarations" wording; only the two poster_store
  declarations are added, and this note is the record of record.

---

Drift local change, 2026-11-13 (collection #309, Grace-approved:
iOS 17 container-lookup fallback chain)
----------------------------------------
- `vendor/idevice/src/services/installation_proxy.rs` — pure
  addition: `get_apps_with_attributes`, a Lookup variant that can
  name a `ReturnAttributes` list in ClientOptions. `get_apps`
  itself is byte-unchanged.
- `src/exploit.rs` — `exploit_find_container` now walks five
  question shapes (historical Lookup/Any/all-attributes first,
  then narrower Lookup shapes, then a Browse pass), each on a
  fresh installation_proxy connection, each outcome logged; the
  container extraction and /private/var normalisation are the
  original code, moved into the per-attempt helper
  `find_container_attempt`. No other function changed. Reason:
  iOS 17.0's installation_proxy deterministically drops the
  connection on the historical ask (field logs, seven attempts);
  iOS 18 and 26/27 answer shape 0 and never reach the fallbacks.
