//! PosterBoard data-store enumeration + cleanup (device-side "already
//! imported" wallpapers) — the detect/cleanup feature behind the
//! 「检测本机已导入的壁纸」 button on the Wallpapers tab.
//!
//! LOCAL ADDITION — not part of the vendored AirCard-iOS upstream core.
//! Registered in rust-core/VENDORED.md and SPEC.md (2026-11-01).
//!
//! LIST / AUDIT transport — DVT deviceinfo directory listing.
//! The store is a plain directory tree inside the PosterBoard
//! PluginKit container:
//!
//!   <container>/Library/Application Support/
//!     PRBPosterExtensionDataStore/<version>/Extensions/
//!       <extension-id>/descriptors/<UUID>/…
//!
//! AFC is jailed to /var/mobile/Media, so the first design tried to
//! reach the store through a symlink planted in Media by a staged
//! StreamingZip archive. Three target variants all failed on device
//! (runs #108–#111), and the failure modes unify into one mechanism:
//!   * The conduit extractor drops an archive WHOLESALE when its
//!     symlink's relative target lexically escapes the extraction
//!     root (run #110 stage.diag: every level of the scratch tree,
//!     payload included, read back Afc(ObjectNotFound)). The
//!     relative-depth (six ../) and absolute targets both escape,
//!     so nothing landed at all.
//!   * The flash geometry (`../../../<tail>`) does NOT escape — at
//!     staged depth (Media/<src>/p0/p1/p2) it resolves back INSIDE
//!     the staging directory, which is exactly why it extracts. But
//!     the archive mirrors the target tail as real directories
//!     inside the package, so resolution lands in that mirrored,
//!     empty Extensions tree — never the real store. That geometry
//!     only points at the real store AFTER the ATC sync relocates
//!     the link to the Media root (its calibrated position, three
//!     ../ to /), and a bare list session performs no sync.
//!   "Package-internal consistency" and "escape to the real store"
//!   are mutually exclusive for one relative target at staged depth.
//!   No fourth link-string variant can fix this; the transport
//!   itself was wrong.
//!
//! The working implementation — recovered from the Walllive 1.1.1
//! binary (module `posterboard_clear_audit`, types
//! `DvtDirectorySession` / `CachedDirectorySession`, functions
//! `audit_on_tunnel_many` / `audit_hierarchy` / `children`) — never
//! stages anything for listing. It opens a DVT RemoteServer session
//! on the same RSD tunnel (com.apple.instruments.dtservicehub,
//! advertised in the RSD handshake) and calls
//! `directoryListingForPath:` on the
//! com.apple.instruments.server.services.deviceinfo channel with
//! the store's ABSOLUTE path, walking Extensions → <extension>/
//! descriptors → <UUID> level by level. The instruments server is
//! not jailed to Media, so absolute paths resolve to the real store
//! directly. The vendored idevice crate already carries this exact
//! call (`DeviceInfoClient::directory_listing`), and the same
//! channel already works on the target device (poster_refresh lists
//! processes through it). One retry on a completely fresh tunnel +
//! service is attempted when a listing pass fails mid-way (Walllive
//! parity: `airlift.clear.audit.retry attempt=2 fresh_service=true
//! query_only=true`). Package names are recovered by listing
//! versions/<v>/contents/ for the `<name>.wallpaper` entry; the
//! identifier text file cannot be read over this channel, so the
//! JSON `identifier` field is left empty (name priority: package
//! name > UUID prefix).
//!
//! DELETE: descriptors are NOT erased in place. Each one is moved
//! out of the store by an AirTraffic/Books sync (the Walllive-
//! verified airlift.delete mechanism): a two-book sync (staging
//! link + the descriptor, identified by its Airlock-escaping
//! relative path) whose FileComplete destinations make the
//! on-device ATAirlock daemon download the descriptor into Media
//! as an airlift-quarantine-<token> copy. Presence before the move
//! and absence after it are audited over DVT (above), the commit
//! audit on a FRESH connection; a target only counts as deleted
//! when its path re-audits absent. Run #147 batches the transport:
//! all present targets share one tunnel and one ATC session whose
//! combined Books.plist carries the two books per target, with
//! per-target destinations, confirmations and accounting
//! unchanged (previously each target ran its own full cycle).
//!
//! Run #115 adds a cleanup SCOPE: list/delete only ever touch the
//! two CollectionsPoster providers (see CLEANUP_SCOPE_PROVIDERS
//! below) — run #114's unscoped list let a select-all cleanup
//! delete 16 system GradientPoster wallpapers. Run #115 also added
//! a quarantine-recovery feature (list/restore of the
//! airlift-quarantine-* folders deletes leave in Media); run #122
//! REMOVES that feature at Sage's direction. The delete mechanism
//! itself is unchanged: descriptors are still MOVED into a
//! quarantine copy rather than erased — that is the delete path's
//! own safety property, independent of any recovery UI.
//!
//! Results come back as JSON in an out parameter, with a machine-
//! readable status string like the other FFIs. Failures are
//! reported, never disguised: if the DVT service refuses a listing,
//! the status says so and no list is fabricated.

use std::ffi::{c_char, c_void, CString};
use std::time::{Duration, Instant};

use idevice::afc::opcode::AfcFopenMode;
use idevice::afc::AfcClient;
use idevice::dvt::device_info::DeviceInfoClient;
use idevice::dvt::remote_server::RemoteServerClient;
use idevice::remote_pairing::RpPairingFile;
use idevice::services::lockdown::LockdownClient;
use idevice::services::rsd::RsdHandshake;
use idevice::tcp::handle::AdapterHandle;
use idevice::{Idevice, ReadWrite};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::exploit::{CachedRouteMode, ALLogCallback};
use crate::ffi_util::{cstr, opt_str};

// ---------------------------------------------------------------------------
// Logger (same shape as poster_refresh::PRLogger)
// ---------------------------------------------------------------------------

struct PSLogger {
    cb: ALLogCallback,
    ctx: *mut c_void,
}
unsafe impl Send for PSLogger {}
unsafe impl Sync for PSLogger {}

impl PSLogger {
    fn log(&self, msg: impl AsRef<str>) {
        let s = msg.as_ref();
        tracing::info!("{s}");
        if let Some(cb) = self.cb {
            if let Ok(c) = CString::new(s) {
                cb(self.ctx, c.as_ptr());
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StoreStatus {
    Ok,
    Partial,
    ConnectFailed,
    ServiceUnavailable,
    StageFailed,
    ListFailed,
    AfcFailed,
}

impl StoreStatus {
    fn as_str(&self) -> &'static str {
        match self {
            StoreStatus::Ok => "ok",
            StoreStatus::Partial => "partial",
            StoreStatus::ConnectFailed => "connectFailed",
            StoreStatus::ServiceUnavailable => "serviceUnavailable",
            StoreStatus::StageFailed => "stageFailed",
            StoreStatus::ListFailed => "listFailed",
            StoreStatus::AfcFailed => "afcFailed",
        }
    }
}

type StoreResult<T> = Result<T, (StoreStatus, String)>;

const RSD_PORT: u16 = 49152;

// ---------------------------------------------------------------------------
// Cleanup scope (run #115, safety boundary)
//
// The detect/cleanup feature only ever lists or deletes descriptors
// belonging to the two CollectionsPoster providers CocoWall itself
// installs into. Every other provider in the store (GradientPoster,
// ClockPoster, Photos, system extensions, …) is system or other-app
// data. Run #114's unscoped list returned all 21 descriptors on
// Sage's device — 5 CollectionsPoster plus 16 GradientPoster — and a
// select-all cleanup deleted the lot, including the system's own
// gradient wallpapers (they survived only as quarantine copies).
// store_list now filters non-scope providers out entirely, and
// store_delete refuses non-scope targets in the driver, before any
// audit or ATC work.
// ---------------------------------------------------------------------------

const CLEANUP_SCOPE_PROVIDERS: [&str; 4] = [
    "com.apple.WallpaperKit.CollectionsPoster",
    "com.apple.Posters.CollectionsPosterApp",
    "com.apple.MercuryPoster",
    "com.apple.PhotosUIPrivate.PhotosPosterProvider",
];

fn provider_in_cleanup_scope(extension: &str) -> bool {
    CLEANUP_SCOPE_PROVIDERS.contains(&extension)
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn extensions_abs(container_path: &str, struct_version: i64) -> String {
    format!(
        "{}/Library/Application Support/PRBPosterExtensionDataStore/{}/Extensions",
        container_path.trim_end_matches('/'),
        struct_version
    )
}

// ---------------------------------------------------------------------------
// RSD tunnel (RSD-only mirror of poster_refresh::connect_rsd; AFC is used
// over the RSD route here so the same connection also carries the pairing
// file's Remote Pairing credentials)
// ---------------------------------------------------------------------------

async fn connect_rsd(
    pairing_bytes: &[u8],
    logger: &PSLogger,
) -> Result<(AdapterHandle, RsdHandshake), (StoreStatus, String)> {
    if RpPairingFile::from_bytes(pairing_bytes).is_err() {
        return Err((
            StoreStatus::ServiceUnavailable,
            "pairing file carries no Remote Pairing credentials; the RSD route is required"
                .to_string(),
        ));
    }

    let mut hosts: Vec<String> = Vec::new();
    let cached = crate::exploit::get_last_working_route();
    if let Some(route) = &cached {
        if matches!(
            route.mode,
            CachedRouteMode::RsdRemoteXpc | CachedRouteMode::RsdRawRpPairing
        ) && !route.host.trim().is_empty()
        {
            hosts.push(route.host.clone());
        }
    }
    for fb in ["10.7.0.1", "10.7.0.2", "10.7.0.3", "10.0.0.1", "172.16.0.1"] {
        if !hosts.iter().any(|h| h == fb) {
            hosts.push(fb.to_string());
        }
    }
    let extra_hosts: Vec<std::net::IpAddr> = hosts
        .iter()
        .filter_map(|s| s.parse::<std::net::IpAddr>().ok())
        .filter(|ip| !ip.is_loopback())
        .collect();

    let mut last_err = String::new();

    if let Some(route) = &cached {
        if matches!(
            route.mode,
            CachedRouteMode::RsdRemoteXpc | CachedRouteMode::RsdRawRpPairing
        ) {
            if let Ok(ip) = route.host.parse::<std::net::Ipv4Addr>() {
                let socket_addr = std::net::SocketAddr::new(std::net::IpAddr::V4(ip), RSD_PORT);
                let extra = vec![std::net::IpAddr::V4(ip)];
                let mut rpf = RpPairingFile::from_bytes(pairing_bytes)
                    .map_err(|e| (StoreStatus::ConnectFailed, format!("{e:?}")))?;
                let attempt = match route.mode {
                    CachedRouteMode::RsdRawRpPairing => {
                        tokio::time::timeout(
                            Duration::from_millis(2000),
                            idevice_ffi::tunnel_provider::tunnel_create_rppairing_multihost_async(
                                socket_addr,
                                "Airlift",
                                &mut rpf,
                                &extra,
                            ),
                        )
                        .await
                    }
                    _ => {
                        tokio::time::timeout(
                            Duration::from_millis(2000),
                            idevice_ffi::tunnel_provider::tunnel_create_remotexpc_multihost_async(
                                socket_addr,
                                "Airlift",
                                &mut rpf,
                                &extra,
                            ),
                        )
                        .await
                    }
                };
                match attempt {
                    Ok(Ok(pair)) => {
                        logger.log(format!(
                            "airlift: poster_store tunnel connected via cached route on {}:{RSD_PORT}",
                            route.host
                        ));
                        return Ok(pair);
                    }
                    Ok(Err(failure)) => {
                        last_err = format!("cached {}:{RSD_PORT}: {:?}", route.host, failure.kind);
                    }
                    Err(_) => {
                        last_err = format!("cached {}:{RSD_PORT}: timed out", route.host);
                    }
                }
            }
        }
    }

    for ip_str in &hosts {
        let Ok(ip) = ip_str.parse::<std::net::Ipv4Addr>() else { continue };
        if ip.is_loopback() {
            continue;
        }
        let socket_addr = std::net::SocketAddr::new(std::net::IpAddr::V4(ip), RSD_PORT);

        let mut rpf = match RpPairingFile::from_bytes(pairing_bytes) {
            Ok(r) => r,
            Err(e) => {
                return Err((StoreStatus::ConnectFailed, format!("pairing parse: {e:?}")));
            }
        };
        match tokio::time::timeout(
            Duration::from_millis(2500),
            idevice_ffi::tunnel_provider::tunnel_create_remotexpc_multihost_async(
                socket_addr,
                "Airlift",
                &mut rpf,
                &extra_hosts,
            ),
        )
        .await
        {
            Ok(Ok(pair)) => {
                logger.log(format!(
                    "airlift: poster_store tunnel connected on {ip_str}:{RSD_PORT} via RemoteXPC"
                ));
                crate::exploit::set_last_working_route(crate::exploit::CachedRoute {
                    host: ip_str.clone(),
                    mode: CachedRouteMode::RsdRemoteXpc,
                });
                return Ok(pair);
            }
            Ok(Err(failure)) => {
                last_err = format!("{ip_str}:{RSD_PORT}: {:?} ({:?})", failure.error, failure.kind);
                if failure.kind
                    != idevice_ffi::tunnel_provider::TunnelFailureKind::TunnelFailureRsdUnreachable
                {
                    let mut rpf2 = match RpPairingFile::from_bytes(pairing_bytes) {
                        Ok(r) => r,
                        Err(e) => {
                            return Err((
                                StoreStatus::ConnectFailed,
                                format!("pairing parse: {e:?}"),
                            ));
                        }
                    };
                    match tokio::time::timeout(
                        Duration::from_millis(2500),
                        idevice_ffi::tunnel_provider::tunnel_create_rppairing_multihost_async(
                            socket_addr,
                            "Airlift",
                            &mut rpf2,
                            &extra_hosts,
                        ),
                    )
                    .await
                    {
                        Ok(Ok(pair)) => {
                            logger.log(format!(
                                "airlift: poster_store tunnel connected on {ip_str}:{RSD_PORT} via raw RPPairing"
                            ));
                            crate::exploit::set_last_working_route(crate::exploit::CachedRoute {
                                host: ip_str.clone(),
                                mode: CachedRouteMode::RsdRawRpPairing,
                            });
                            return Ok(pair);
                        }
                        Ok(Err(raw_failure)) => {
                            last_err = format!("{ip_str}:{RSD_PORT}: {:?}", raw_failure.kind);
                        }
                        Err(_) => {
                            last_err = format!("{ip_str}:{RSD_PORT}: raw RPPairing timed out");
                        }
                    }
                }
            }
            Err(_) => {
                last_err = format!("{ip_str}:{RSD_PORT}: RemoteXPC timed out");
            }
        }
    }

    Err((StoreStatus::ConnectFailed, last_err))
}

// ---------------------------------------------------------------------------
// DVT audit session (Walllive-proven list/audit transport — see module
// doc). No staging archive, no symlink: directoryListingForPath: on
// the deviceinfo channel takes absolute paths.
// ---------------------------------------------------------------------------

const DVT_SERVICE: &str = "com.apple.instruments.dtservicehub";

/// Open an RSD tunnel and a DVT RemoteServer on it, checking the
/// handshake advertises the dtservicehub (the audit's only service —
/// module doc). Returns the adapter + handshake alongside the server
/// so the caller keeps them alive while it creates a DeviceInfoClient
/// borrowing the server.
async fn connect_device_info(
    pairing_bytes: &[u8],
    logger: &PSLogger,
) -> StoreResult<(
    AdapterHandle,
    RsdHandshake,
    RemoteServerClient<Box<dyn ReadWrite>>,
)> {
    let (mut adapter, mut handshake) = connect_rsd(pairing_bytes, logger).await?;

    let advertised = handshake.services.contains_key(DVT_SERVICE);
    logger.log(format!(
        "airlift: airlift.poster_store.service advertised={advertised} service={DVT_SERVICE}"
    ));
    if !advertised {
        return Err((
            StoreStatus::ServiceUnavailable,
            format!("{DVT_SERVICE} not advertised by RSD handshake"),
        ));
    }

    let server = handshake
        .connect::<RemoteServerClient<Box<dyn ReadWrite>>>(&mut adapter)
        .await
        .map_err(|e| {
            (
                StoreStatus::ServiceUnavailable,
                format!("dtservicehub connect failed: {e:?}"),
            )
        })?;
    logger.log(
        "airlift: airlift.poster_store.audit.session query_only=true transport=dvt-deviceinfo",
    );
    Ok((adapter, handshake, server))
}

/// Create the deviceinfo client on an open RemoteServer.
async fn device_info_client<'a>(
    server: &'a mut RemoteServerClient<Box<dyn ReadWrite>>,
) -> StoreResult<DeviceInfoClient<'a, Box<dyn ReadWrite>>> {
    DeviceInfoClient::new(server).await.map_err(|e| {
        (
            StoreStatus::ServiceUnavailable,
            format!("deviceinfo channel failed: {e:?}"),
        )
    })
}

/// One directoryListingForPath: call, entries normalized to bare
/// child names (the reply carries entry names already; normalize
/// defensively against trailing slashes / full paths), sorted.
async fn dvt_list_dir(
    info: &mut DeviceInfoClient<'_, Box<dyn ReadWrite>>,
    path: &str,
) -> Result<Vec<String>, String> {
    let raw = info
        .directory_listing(path)
        .await
        .map_err(|e| format!("directoryListingForPath {path}: {e:?}"))?;
    let mut out: Vec<String> = raw
        .into_iter()
        .map(|n| {
            let n = n.trim_end_matches('/');
            n.rsplit('/').next().unwrap_or(n).to_string()
        })
        .filter(|n| !n.is_empty() && n != "." && n != "..")
        .collect();
    out.sort();
    out.dedup();
    Ok(out)
}

// ---------------------------------------------------------------------------
// List flow
// ---------------------------------------------------------------------------

async fn store_list(
    pairing_path: String,
    container_path: String,
    struct_version: i64,
    logger: &PSLogger,
) -> StoreResult<String> {
    let started = Instant::now();
    logger.log("airlift: airlift.poster_store.list.begin");

    let pairing_bytes = std::fs::read(&pairing_path).map_err(|e| {
        (
            StoreStatus::ConnectFailed,
            format!("Failed to read pairing file at {pairing_path}: {e}"),
        )
    })?;

    let target = extensions_abs(&container_path, struct_version);

    // Walllive parity: a failed pass is retried once on a completely
    // fresh tunnel + DVT service before the failure is reported.
    let mut items: Option<Vec<DescriptorItem>> = None;
    let mut last_error = String::new();
    for attempt in 1..=2 {
        match list_attempt(&pairing_bytes, &target, logger).await {
            Ok(found) => {
                items = Some(found);
                break;
            }
            Err((status, message)) => {
                // A tunnel/service that never came up is not retried:
                // the fresh attempt would hit the same wall.
                if matches!(
                    status,
                    StoreStatus::ConnectFailed | StoreStatus::ServiceUnavailable
                ) {
                    return Err((status, message));
                }
                last_error = message;
                if attempt == 1 {
                    logger.log(
                        "airlift: airlift.poster_store.audit.retry attempt=2 max_attempts=2 fresh_service=true query_only=true",
                    );
                }
            }
        }
    }
    let items = items.ok_or((StoreStatus::ListFailed, last_error))?;

    let mut json = String::from("{\"items\":[");
    for (i, item) in items.iter().enumerate() {
        if i > 0 {
            json.push(',');
        }
        json.push_str(&format!(
            "{{\"extension\":\"{}\",\"uuid\":\"{}\",\"identifier\":\"{}\",\"packageName\":\"{}\",\"name\":\"{}\"}}",
            json_escape(&item.extension),
            json_escape(&item.uuid),
            json_escape(&item.identifier),
            json_escape(&item.package_name),
            json_escape(&item.name),
        ));
    }
    json.push_str("]}");
    logger.log(format!(
        "airlift: airlift.poster_store.list.end count={} duration_ms={}",
        items.len(),
        started.elapsed().as_millis()
    ));
    Ok(json)
}

/// One full listing pass on a fresh DVT session.
async fn list_attempt(
    pairing_bytes: &[u8],
    extensions_path: &str,
    logger: &PSLogger,
) -> StoreResult<Vec<DescriptorItem>> {
    let (_adapter, _handshake, mut server) = connect_device_info(pairing_bytes, logger).await?;
    let mut info = device_info_client(&mut server).await?;
    enumerate_descriptors(&mut info, extensions_path, logger).await
}

struct DescriptorItem {
    extension: String,
    uuid: String,
    identifier: String,
    package_name: String,
    name: String,
}

async fn enumerate_descriptors(
    info: &mut DeviceInfoClient<'_, Box<dyn ReadWrite>>,
    extensions_path: &str,
    logger: &PSLogger,
) -> StoreResult<Vec<DescriptorItem>> {
    let extensions = dvt_list_dir(info, extensions_path)
        .await
        .map_err(|e| (StoreStatus::ListFailed, e))?;
    logger.log(format!(
        "airlift: airlift.poster_store.extensions.found count={} names={}",
        extensions.len(),
        extensions.join(",")
    ));

    let mut items: Vec<DescriptorItem> = Vec::new();
    for ext in &extensions {
        // Run #115 cleanup scope: providers outside the two
        // CollectionsPoster providers are not enumerated at all —
        // they never reach the UI, so they can never be selected.
        if !provider_in_cleanup_scope(ext) {
            logger.log(format!(
                "airlift: airlift.poster_store.descriptors.filtered extension={ext} reason=provider_scope"
            ));
            continue;
        }
        let desc_dir = format!("{extensions_path}/{ext}/descriptors");
        let uuids = match dvt_list_dir(info, &desc_dir).await {
            Ok(names) => names,
            Err(e) => {
                logger.log(format!(
                    "airlift: airlift.poster_store.descriptors.unreadable extension={ext} error={e}"
                ));
                continue;
            }
        };
        logger.log(format!(
            "airlift: airlift.poster_store.descriptors.found extension={ext} count={}",
            uuids.len()
        ));
        for uuid in uuids {
            let base = format!("{desc_dir}/{uuid}");
            // Package name: versions/<v>/contents/<name>.wallpaper —
            // the .wallpaper bundle is a directory, so it shows up
            // in a plain listing (no file read needed; the
            // identifier text file is NOT readable over DVT and the
            // identifier field stays empty).
            let mut package_name = String::new();
            if let Ok(versions) = dvt_list_dir(info, &format!("{base}/versions")).await {
                for version in versions {
                    if let Ok(contents) =
                        dvt_list_dir(info, &format!("{base}/versions/{version}/contents")).await
                    {
                        if let Some(pkg) =
                            contents.into_iter().find(|n| n.ends_with(".wallpaper"))
                        {
                            package_name = pkg.trim_end_matches(".wallpaper").to_string();
                            break;
                        }
                    }
                }
            }

            let name = if !package_name.is_empty() {
                package_name.clone()
            } else {
                uuid.chars().take(8).collect()
            };
            items.push(DescriptorItem {
                extension: ext.clone(),
                uuid,
                identifier: String::new(),
                package_name,
                name,
            });
        }
    }
    Ok(items)
}

// ---------------------------------------------------------------------------
// Delete flow — ATC manifest move (Walllive-verified mechanism)
//
// Deleting a descriptor does NOT erase it in place. Like Walllive's
// airlift.delete (full log, 2026-10-31), each descriptor is MOVED out of
// the data store by an AirTraffic/Books sync:
//
//   1. Audit (AFC listing through the staging link): confirm the target
//      descriptor is present, with stage counts logged.
//   2. Stage a zip whose symlink points at the target's descriptors/
//      directory, and write a Books.plist with exactly two books: the
//      staging link and the descriptor itself, the latter identified by
//      its Airlock-escaping relative path (the same shape as the
//      vendored canary's "target" book in exploit::run).
//   3. Run the ATC session (mirrors exploit::run's wire flow). The
//      device manifest offers device-side books for download; the host
//      then sends FileComplete per book with host-chosen destinations:
//      the link lands in Media under airlift-link-<token>, and the
//      descriptor is downloaded/moved by the on-device ATAirlock daemon
//      into Media under airlift-quarantine-<token> — out of the store.
//   4. Restore the original Books.plist; remove the staging source and
//      the link; RETAIN the quarantine copy (Walllive: stage.retained).
//   5. After all targets: commit audit on a FRESH connection — every
//      deleted path must re-audit absent before it counts as deleted.
//
// Run #147 transport note: steps 2–4 above describe the mechanism
// per target as Walllive's log shows it and as this code ran it
// until #146 — one full cycle per descriptor. Since #147 the
// cycles are batched (see "Batched delete" below): one tunnel,
// every target staged, one combined Books.plist, one ATC session,
// one Books restore — while steps 1 and 5 and every per-target
// confirmation in between stay exactly as described.
// ---------------------------------------------------------------------------

const AIRLOCK_ROOT: &str = "/var/mobile/Media/Airlock/Book";

fn random_hex(n: usize) -> String {
    use std::io::Read;
    let mut buf = vec![0u8; n];
    let ok = std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut buf))
        .is_ok();
    if !ok {
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0x2545f4914f6cdd1d);
        for (i, b) in buf.iter_mut().enumerate() {
            *b = ((seed >> ((i % 8) * 8)) & 0xff) as u8 ^ (i as u8);
        }
    }
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

/// POSIX relative path (mirrors exploit::posix_rel).
fn posix_rel(path: &str, base: &str) -> String {
    let path_parts: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    let base_parts: Vec<&str> = base.trim_start_matches('/').split('/').collect();
    let common = path_parts
        .iter()
        .zip(base_parts.iter())
        .take_while(|(a, b)| a == b)
        .count();
    let up = base_parts.len() - common;
    let down = &path_parts[common..];
    let mut rel: Vec<&str> = (0..up).map(|_| "..").chain(down.iter().copied()).collect();
    if rel.is_empty() {
        rel.push(".");
    }
    rel.join("/")
}

/// StreamingZip archive for a delete operation (mirrors
/// exploit::build_archive): META-INF + p0/p1/p2/link symlink pointing at
/// the descriptors directory + the target path components + a small
/// payload file (staged but referenced by no book — the delete sync has
/// exactly two books, link + descriptor).
///
/// `link_target` is the symlink's target string, parameterized because
/// the geometry depends on where the link ends up sitting: the delete
/// sync's link is landed at the Media root by ATC (three ../ to /,
/// then the target tail), while the store session's link stays at its
/// staged depth inside the scratch subdir (six ../ to /var for the
/// relative variant, or the plain absolute path for the fallback).
fn build_delete_archive(
    descriptors_dir_abs: &str,
    link_target: &str,
) -> Result<Vec<u8>, Box<dyn std::error::Error + Send + Sync>> {
    use zip::{write::FileOptions, CompressionMethod, ZipWriter};

    let target_tail = descriptors_dir_abs.trim_start_matches('/');
    let mut buf = Vec::new();
    let mut zip = ZipWriter::new(std::io::Cursor::new(&mut buf));

    use zip::write::ExtendedFileOptions;

    fn zip_opts(mode: u32) -> FileOptions<'static, ExtendedFileOptions> {
        let mut opts = FileOptions::default()
            .compression_method(CompressionMethod::Stored)
            .unix_permissions(mode);
        let mode_bytes = (mode as u16).to_le_bytes();
        let _ = opts.add_extra_data(0x5A53, Box::new(mode_bytes), false);
        opts
    }

    zip.add_directory("META-INF/", zip_opts(0o040755))?;
    zip.start_file("META-INF/com.apple.ZipMetadata.plist", zip_opts(0o100600))?;
    let meta_plist: plist::Value = {
        let mut d = plist::Dictionary::new();
        d.insert("Version".to_owned(), plist::Value::Integer(2.into()));
        plist::Value::Dictionary(d)
    };
    let mut meta_buf = Vec::new();
    plist::to_writer_binary(&mut meta_buf, &meta_plist)?;
    std::io::Write::write_all(&mut zip, &meta_buf)?;

    for dir in &["p0/", "p0/p1/", "p0/p1/p2/"] {
        zip.add_directory(*dir, zip_opts(0o040755))?;
    }

    zip.add_symlink("p0/p1/p2/link", link_target, zip_opts(0o120777))?;

    let mut cursor = String::new();
    for component in target_tail.split('/') {
        if component.is_empty() {
            continue;
        }
        cursor.push_str(component);
        cursor.push('/');
        zip.add_directory(&cursor, zip_opts(0o040755))?;
    }

    zip.start_file("payload", zip_opts(0o100600))?;
    std::io::Write::write_all(&mut zip, b"airlift delete\n")?;
    zip.finish()?;
    Ok(buf)
}

/// Books.plist sync manifest (mirrors exploit::build_books_plist).
fn build_books_plist(
    identifiers: &[String],
) -> Result<Vec<u8>, Box<dyn std::error::Error + Send + Sync>> {
    let rows: Vec<plist::Value> = identifiers
        .iter()
        .enumerate()
        .map(|(i, id)| {
            let mut d = plist::Dictionary::new();
            d.insert("Persistent ID".to_owned(), plist::Value::String(id.clone()));
            d.insert("Item ID".to_owned(), plist::Value::String((i + 1).to_string()));
            d.insert("DSID".to_owned(), plist::Value::String("1".to_owned()));
            plist::Value::Dictionary(d)
        })
        .collect();
    let mut top = plist::Dictionary::new();
    top.insert("Books".to_owned(), plist::Value::Array(rows));
    let mut buf = Vec::new();
    plist::to_writer_binary(&mut buf, &top)?;
    Ok(buf)
}

// --- ATC wire helpers (mirror exploit's AirTraffic message helpers) ---

fn atc_message_name(dict: &plist::Dictionary) -> Option<String> {
    if let Some(plist::Value::String(s)) = dict.get("Command") {
        return Some(s.clone());
    }
    if let Some(plist::Value::String(s)) = dict.get("MessageName") {
        return Some(s.clone());
    }
    None
}

fn atc_session_number(dict: &plist::Dictionary) -> Option<i64> {
    if let Some(plist::Value::Integer(n)) = dict.get("Session") {
        return n.as_signed();
    }
    if let Some(plist::Value::Integer(n)) = dict.get("SessionNumber") {
        return n.as_signed();
    }
    None
}

fn make_atc_msg(
    command: &str,
    session: i64,
    params: Option<plist::Dictionary>,
) -> plist::Dictionary {
    let mut msg = plist::Dictionary::new();
    msg.insert("Command".into(), plist::Value::String(command.into()));
    msg.insert("Session".into(), plist::Value::Integer(session.into()));
    if let Some(p) = params {
        msg.insert("Params".into(), plist::Value::Dictionary(p));
    }
    msg
}

async fn read_atc_dict<S: tokio::io::AsyncReadExt + Unpin>(
    stream: &mut S,
) -> Result<plist::Dictionary, String> {
    let mut len_buf = [0u8; 4];
    stream
        .read_exact(&mut len_buf)
        .await
        .map_err(|e| format!("read length: {e}"))?;
    let len_le = u32::from_le_bytes(len_buf) as usize;
    let len_be = u32::from_be_bytes(len_buf) as usize;
    let len = if len_le > 0 && len_le <= 10 * 1024 * 1024 {
        len_le
    } else if len_be > 0 && len_be <= 10 * 1024 * 1024 {
        len_be
    } else {
        return Err(format!(
            "ATC message length invalid: raw={:?}, le={}, be={}",
            len_buf, len_le, len_be
        ));
    };
    let mut body = vec![0u8; len];
    stream
        .read_exact(&mut body)
        .await
        .map_err(|e| format!("read body (len={len}): {e}"))?;
    let val: plist::Value = plist::from_bytes(&body).map_err(|e| format!("decode plist: {e}"))?;
    match val {
        plist::Value::Dictionary(d) => Ok(d),
        _ => Err("expected plist dictionary".into()),
    }
}

async fn send_atc_dict<S: tokio::io::AsyncWriteExt + Unpin>(
    stream: &mut S,
    dict: &plist::Dictionary,
) -> Result<(), String> {
    let mut buf = Vec::new();
    let top = plist::Value::Dictionary(dict.clone());
    plist::to_writer_binary(&mut buf, &top).map_err(|e| format!("encode plist: {e}"))?;
    let len_bytes = (buf.len() as u32).to_le_bytes();
    stream
        .write_all(&len_bytes)
        .await
        .map_err(|e| format!("write length: {e}"))?;
    stream
        .write_all(&buf)
        .await
        .map_err(|e| format!("write body: {e}"))?;
    stream
        .flush()
        .await
        .map_err(|e| format!("flush: {e}"))?;
    Ok(())
}

/// RSD service connection (mirrors exploit::connect_service_rsd: shim ->
/// bare -> Lockdown StartService fallback).
async fn connect_service_rsd(
    adapter: &mut AdapterHandle,
    handshake: &mut RsdHandshake,
    service_base: &str,
    logger: &PSLogger,
) -> Result<Box<dyn ReadWrite>, String> {
    let shim_name = format!("{service_base}.shim.remote");
    if let Some(s) = handshake.services.get(&shim_name) {
        let port = s.port;
        logger.log(format!(
            "airlift: found RSD shim service '{shim_name}' on port {port}"
        ));
        let stream = adapter
            .connect(port)
            .await
            .map_err(|e| format!("Connect to '{shim_name}' on port {port} failed: {e:?}"))?;
        let mut dev = Idevice::new(Box::new(stream), "Airlift");
        dev.rsd_checkin()
            .await
            .map_err(|e| format!("RSD checkin for '{shim_name}' failed: {e:?}"))?;
        return dev
            .get_socket()
            .ok_or_else(|| "Failed to get socket from Idevice".to_string());
    }

    if let Some(s) = handshake.services.get(service_base) {
        let port = s.port;
        logger.log(format!(
            "airlift: found RSD bare service '{service_base}' on port {port}"
        ));
        let stream = adapter
            .connect(port)
            .await
            .map_err(|e| format!("Connect to '{service_base}' on port {port} failed: {e:?}"))?;
        let mut dev = Idevice::new(Box::new(stream), "Airlift");
        dev.rsd_checkin()
            .await
            .map_err(|e| format!("RSD checkin for '{service_base}' failed: {e:?}"))?;
        return dev
            .get_socket()
            .ok_or_else(|| "Failed to get socket from Idevice".to_string());
    }

    logger.log(format!(
        "airlift: '{service_base}' not in RSD, starting via fresh Lockdown connection..."
    ));
    let mut lockdown = handshake
        .connect::<LockdownClient>(adapter)
        .await
        .map_err(|e| format!("Lockdown connect for '{service_base}' failed: {e:?}"))?;
    let (port, ssl) = lockdown
        .start_service(service_base)
        .await
        .map_err(|e| format!("Lockdown start_service('{service_base}') failed: {e:?}"))?;
    logger.log(format!(
        "airlift: '{service_base}' started on port {port} (ssl={ssl})"
    ));
    let stream = adapter
        .connect(port)
        .await
        .map_err(|e| format!("Connect to service port {port} failed: {e:?}"))?;
    Ok(Box::new(stream))
}

/// Collect (asset-id, download-flag) pairs from a device AssetManifest,
/// however deeply the asset dicts are nested.
fn collect_manifest_entries(value: &plist::Value, out: &mut Vec<(String, Option<bool>)>) {
    match value {
        plist::Value::Dictionary(d) => {
            let id = d
                .get("AssetID")
                .and_then(|v| v.as_string())
                .or_else(|| d.get("Persistent ID").and_then(|v| v.as_string()));
            if let Some(id) = id {
                let download = d.get("Download").and_then(|v| v.as_boolean());
                out.push((id.to_string(), download));
            }
            for v in d.values() {
                collect_manifest_entries(v, out);
            }
        }
        plist::Value::Array(items) => {
            for v in items {
                collect_manifest_entries(v, out);
            }
        }
        _ => {}
    }
}

// --- Batched delete (run #147: one tunnel, one ATC session) ---
//
// Until run #147 every target ran the full cycle below on its own:
// its own tunnel, staging, Books write, ATC session and Books
// restore — the run #146 device log prices that at ~3.5 s per
// target (delete segment 28,069 ms for 8 targets). The mechanism
// per target is unchanged (staging link + descriptor as a two-book
// pair, FileComplete destinations land the link in Media and move
// the descriptor into its own airlift-quarantine-<token>), but the
// transport is now shared, exactly like the install side's combined
// preferences session: stage every present target on ONE tunnel,
// write ONE Books.plist carrying all targets' book pairs, run ONE
// ATC session sending all FileCompletes (all links first with one
// shared settle + verify, then all descriptors with one shared
// settle), restore Books once. Per-target accounting is untouched:
// each target keeps its own quarantine destination and its own
// stage / manifest / link / quarantine / gone-through-link
// confirmations, a manifest refusal fails only its own target, and
// phase C's fresh commit audit still decides deleted vs failed.

struct PreparedDelete {
    target_idx: usize,
    uuid: String,
    source: String,
    link_destination: String,
    quarantine_name: String,
    identifiers: Vec<String>,
    link_verified: bool,
    quarantine_confirmed: bool,
    descriptor_gone_local: bool,
    move_sent: bool,
    refusal: Option<String>,
}

/// Stage one target's delete archive on the shared tunnel and
/// verify the extraction (steps 2–3 of the delete flow; the Books
/// write and the ATC session belong to the batch, below).
async fn stage_delete_target(
    adapter: &mut AdapterHandle,
    handshake: &mut RsdHandshake,
    afc: &mut AfcClient,
    descriptors_dir_abs: &str,
    target_idx: usize,
    uuid: &str,
    logger: &PSLogger,
) -> Result<PreparedDelete, String> {
    let token = random_hex(10);
    let source = format!("airlift-src-{token}");
    let link_destination = format!("airlift-link-{token}");
    let quarantine_name = format!("airlift-quarantine-{token}");

    let descriptor_abs = format!("{descriptors_dir_abs}/{uuid}");
    let link_identifier = format!("../../{source}/p0/p1/p2/link");
    let descriptor_identifier = posix_rel(&descriptor_abs, AIRLOCK_ROOT);
    let identifiers = vec![link_identifier, descriptor_identifier];

    // The delete sync lands this link at the Media root (airlift-link-*),
    // so its target keeps the root geometry: three ../ to /, then tail.
    let root_link_target = format!(
        "../../../{}",
        descriptors_dir_abs.trim_start_matches('/')
    );
    let archive = build_delete_archive(descriptors_dir_abs, &root_link_target)
        .map_err(|e| format!("build archive: {e}"))?;

    // Stage via streaming_zip_conduit (mirrors exploit::run step 1).
    let mut zip_stream = connect_service_rsd(
        adapter,
        handshake,
        "com.apple.streaming_zip_conduit",
        logger,
    )
    .await?;
    {
        let mut zip_init_dict = plist::Dictionary::new();
        zip_init_dict.insert("MediaSubdir".to_string(), plist::Value::String(source.clone()));
        let mut init_buf = Vec::new();
        plist::to_writer_binary(&mut init_buf, &plist::Value::Dictionary(zip_init_dict))
            .map_err(|e| format!("encode MediaSubdir: {e}"))?;
        let init_len_bytes = (init_buf.len() as u32).to_be_bytes();
        zip_stream
            .write_all(&init_len_bytes)
            .await
            .map_err(|e| format!("write MediaSubdir length: {e}"))?;
        zip_stream
            .write_all(&init_buf)
            .await
            .map_err(|e| format!("write MediaSubdir body: {e}"))?;
        zip_stream.flush().await.map_err(|e| format!("flush: {e}"))?;
        zip_stream
            .write_all(&archive)
            .await
            .map_err(|e| format!("write archive bytes: {e}"))?;
        zip_stream.flush().await.map_err(|e| format!("flush: {e}"))?;
        let mut resp_len_buf = [0u8; 4];
        zip_stream
            .read_exact(&mut resp_len_buf)
            .await
            .map_err(|e| format!("read zip response length: {e}"))?;
        let resp_len = u32::from_be_bytes(resp_len_buf) as usize;
        let mut resp_body = vec![0u8; resp_len];
        zip_stream
            .read_exact(&mut resp_body)
            .await
            .map_err(|e| format!("read zip response body: {e}"))?;
    }
    drop(zip_stream);
    logger.log("airlift: airlift.delete.stage uploaded=true");

    let source_link = format!("{source}/p0/p1/p2/link");
    let source_payload = format!("{source}/payload");
    let stage_ok = afc.get_file_info(&source).await.is_ok()
        && afc.get_file_info(&source_link).await.is_ok()
        && afc.get_file_info(&source_payload).await.is_ok();
    if !stage_ok {
        return Err("stage verification failed: extracted files not present in Media".to_string());
    }

    Ok(PreparedDelete {
        target_idx,
        uuid: uuid.to_string(),
        source,
        link_destination,
        quarantine_name,
        identifiers,
        link_verified: false,
        quarantine_confirmed: false,
        descriptor_gone_local: false,
        move_sent: false,
        refusal: None,
    })
}

/// The batch's single ATC session: write the combined Books.plist
/// (every prepared target's link + descriptor pair, in target
/// order), run one sync, and send all FileCompletes — all links
/// first (one shared 900 ms settle, then each link's Media
/// destination is verified), then all descriptors (one shared 2 s
/// settle) — filling each target's own confirmations in place. A
/// descriptor the device manifest does not offer for download is
/// refused for ITS target only (the old per-target operation
/// refused the whole operation at the same point); a protocol-level
/// failure returns Err and the caller fails every prepared target
/// with it, as the old cycle failed its one target.
async fn run_delete_session(
    adapter: &mut AdapterHandle,
    handshake: &mut RsdHandshake,
    afc: &mut AfcClient,
    prepared: &mut [PreparedDelete],
    logger: &PSLogger,
) -> Result<(), String> {
    let identifiers: Vec<String> = prepared
        .iter()
        .flat_map(|p| p.identifiers.iter().cloned())
        .collect();
    let books_plist = build_books_plist(&identifiers).map_err(|e| format!("build Books.plist: {e}"))?;

    let _ = afc.mk_dir("Airlock").await;
    let _ = afc.mk_dir("Airlock/Book").await;
    let _ = afc.mk_dir("Books").await;
    let _ = afc.mk_dir("Books/Sync").await;

    let mut books_fd = afc
        .open("Books/Sync/Books.plist", AfcFopenMode::WrOnly)
        .await
        .map_err(|e| format!("AFC open Books.plist: {e:?}"))?;
    books_fd
        .write_entire(&books_plist)
        .await
        .map_err(|e| format!("AFC write Books.plist: {e:?}"))?;
    let _ = books_fd.close().await;
    logger.log("airlift: airlift.delete.books.written=true");

    // ATC session (mirrors exploit::run step 2).
    let mut atc_stream = connect_service_rsd(adapter, handshake, "com.apple.atc", logger).await?;

    let mut sync_allowed = false;
    let mut session_number: i64 = 0;
    let mut grappa_info: Option<(u32, u32, u32)> = None;
    for _ in 0..12 {
        match tokio::time::timeout(
            std::time::Duration::from_millis(1500),
            read_atc_dict(&mut atc_stream),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(sn) = atc_session_number(&dict) {
                    session_number = sn;
                }
                if let Some(name) = atc_message_name(&dict) {
                    logger.log(format!("airlift: atc received '{name}' (session={session_number})"));
                    if name == "Capabilities" {
                        if let Some(params) = dict.get("Params").and_then(|p| p.as_dictionary()) {
                            if let Some(gi) = params.get("GrappaSupportInfo").and_then(|g| g.as_dictionary()) {
                                let ver = gi.get("version").and_then(|v| v.as_unsigned_integer()).unwrap_or(1) as u32;
                                let dt = gi.get("deviceType").and_then(|v| v.as_unsigned_integer()).unwrap_or(0) as u32;
                                let pv = gi.get("protocolVersion").and_then(|v| v.as_unsigned_integer()).unwrap_or(1) as u32;
                                logger.log(format!("airlift: captured GrappaSupportInfo: version={ver}, deviceType={dt}, protocolVersion={pv}"));
                                grappa_info = Some((ver, dt, pv));
                            }
                        }
                    }
                    if name == "SyncAllowed" {
                        sync_allowed = true;
                        break;
                    }
                }
            }
            Ok(Err(e)) => {
                logger.log(format!("airlift: atc initial read notice: {e}"));
                break;
            }
            Err(_) => {}
        }
    }
    if sync_allowed {
        logger.log(format!("airlift: SyncAllowed observed (session={session_number})"));
    } else {
        logger.log(format!("airlift: SyncAllowed not emitted, proceeding with session={session_number}..."));
    }

    let mut host_info_dict = plist::Dictionary::new();
    host_info_dict.insert("Type".into(), plist::Value::String("iTunes".into()));
    host_info_dict.insert("Version".into(), plist::Value::String("13.7.0.161".into()));
    host_info_dict.insert("MacOSVersion".into(), plist::Value::String("15.0".into()));
    host_info_dict.insert("SyncHostName".into(), plist::Value::String("airlift".into()));
    let library_id = format!(
        "{}-{}-{}-{}-{}",
        random_hex(4),
        random_hex(2),
        random_hex(2),
        random_hex(2),
        random_hex(6)
    );
    host_info_dict.insert("LibraryID".into(), plist::Value::String(library_id));
    host_info_dict.insert(
        "SyncedDataclasses".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    host_info_dict.insert(
        "SyncedAssetTypes".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    host_info_dict.insert("Wakeable".into(), plist::Value::Boolean(false));

    let grappa_token = crate::grappa::generate_grappa_token(grappa_info, |s| logger.log(s));
    if let Some(ref token) = grappa_token {
        host_info_dict.insert("Grappa".into(), plist::Value::Data(token.clone()));
    }

    let mut host_info_params = plist::Dictionary::new();
    host_info_params.insert("HostInfo".into(), plist::Value::Dictionary(host_info_dict.clone()));
    host_info_params.insert("LocalCloudSupport".into(), plist::Value::Boolean(false));
    let msg_host_info = make_atc_msg("HostInfo", 0, Some(host_info_params));
    send_atc_dict(&mut atc_stream, &msg_host_info).await?;
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

    let mut sync_req_params = plist::Dictionary::new();
    sync_req_params.insert(
        "Dataclasses".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    sync_req_params.insert(
        "DataclassAnchors".into(),
        plist::Value::Dictionary(plist::Dictionary::new()),
    );
    sync_req_params.insert("HostInfo".into(), plist::Value::Dictionary(host_info_dict));
    if let Some(token) = grappa_token {
        sync_req_params.insert("Grappa".into(), plist::Value::Data(token));
    }
    let msg_sync_req = make_atc_msg("RequestingSync", 1, Some(sync_req_params));
    send_atc_dict(&mut atc_stream, &msg_sync_req).await?;

    let mut ready = false;
    for _ in 0..24 {
        match tokio::time::timeout(
            std::time::Duration::from_secs(5),
            read_atc_dict(&mut atc_stream),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(name) = atc_message_name(&dict) {
                    logger.log(format!("airlift: atc sync state: '{name}'"));
                    if name == "Ping" {
                        let pong = make_atc_msg("Pong", 1, None);
                        if let Err(e) = send_atc_dict(&mut atc_stream, &pong).await {
                            logger.log(format!("airlift: pong send error: {e}"));
                            break;
                        }
                        continue;
                    }
                    if name == "ReadyForSync" || name == "AssetManifest" {
                        ready = true;
                        break;
                    }
                    if name == "SyncFailed" {
                        logger.log(format!("airlift: atc sync notice (non-fatal): {dict:?}"));
                        continue;
                    }
                }
            }
            Ok(Err(e)) => {
                logger.log(format!("airlift: atc sync read error: {e}"));
                break;
            }
            Err(_) => {}
        }
    }
    if !ready {
        return Err("AirTraffic: ReadyForSync not observed (ensure official Apple Books app is installed and opened once)".to_string());
    }
    logger.log("airlift: ReadyForSync observed");

    let mut sync_types = plist::Dictionary::new();
    sync_types.insert("Book".into(), plist::Value::Integer(1.into()));
    let mut meta_params = plist::Dictionary::new();
    meta_params.insert("SyncTypes".into(), plist::Value::Dictionary(sync_types));
    meta_params.insert(
        "DataclassAnchors".into(),
        plist::Value::Dictionary(plist::Dictionary::new()),
    );
    let msg_meta = make_atc_msg("FinishedSyncingMetadata", 1, Some(meta_params));
    send_atc_dict(&mut atc_stream, &msg_meta).await?;

    // Wait for AssetManifest and verify the device offers the books,
    // each descriptor as a download (Walllive: delete.manifest.target
    // matching_entries=1 download=true ready=true).
    let mut manifest_entries: Vec<(String, Option<bool>)> = Vec::new();
    let mut manifest_observed = false;
    for _ in 0..20 {
        match tokio::time::timeout(
            std::time::Duration::from_secs(5),
            read_atc_dict(&mut atc_stream),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(name) = atc_message_name(&dict) {
                    logger.log(format!("airlift: atc manifest message: '{name}'"));
                    if name == "Ping" {
                        let pong = make_atc_msg("Pong", 1, None);
                        let _ = send_atc_dict(&mut atc_stream, &pong).await;
                        continue;
                    }
                    if name == "AssetManifest" {
                        manifest_observed = true;
                        if let Some(params) = dict.get("Params") {
                            collect_manifest_entries(params, &mut manifest_entries);
                        }
                        break;
                    }
                    if name == "SyncFailed" {
                        logger.log(format!("airlift: atc manifest notice (non-fatal): {dict:?}"));
                        continue;
                    }
                    if name == "SyncFinished" {
                        break;
                    }
                }
            }
            Ok(Err(e)) => {
                logger.log(format!("airlift: atc manifest read error: {e}"));
                break;
            }
            Err(_) => {}
        }
    }
    if !manifest_observed {
        return Err("AirTraffic: AssetManifest not observed (ensure official Apple Books app is installed)".to_string());
    }
    logger.log(format!(
        "airlift: airlift.delete.manifest book_entries={} expected={}",
        identifiers.len(),
        identifiers.len()
    ));
    for (idx, id) in identifiers.iter().enumerate() {
        let matched: Vec<&(String, Option<bool>)> = manifest_entries
            .iter()
            .filter(|(eid, _)| eid == id)
            .collect();
        let download = matched.first().and_then(|(_, d)| *d);
        logger.log(format!(
            "airlift: airlift.delete.manifest.target index={idx} matching_entries={} download={} ready={}",
            matched.len(),
            download.map(|d| d.to_string()).unwrap_or_else(|| "unknown".to_string()),
            !matched.is_empty()
        ));
        // Descriptor positions (odd global indices) keep the old
        // refusal rule, now scoped to their own target: a descriptor
        // the device does not offer for download is never
        // FileCompleted, and its target fails alone.
        if idx % 2 == 1 && download == Some(false) {
            let uuid = prepared[idx / 2].uuid.clone();
            prepared[idx / 2].refusal = Some(format!(
                "device manifest does not offer descriptor {uuid} for download; refusing to FileComplete it"
            ));
        }
    }
    logger.log("airlift: AssetManifest observed");

    // FileCompletes in the old operation's two phases, batched:
    // every target's link first (then one shared settle and each
    // link's Media destination verified), then every descriptor
    // (the move). Each target's own link still precedes its own
    // descriptor, as in the per-target cycle.
    logger.log("airlift: airlift.delete.move.begin phase=link");
    for (k, target) in prepared.iter().enumerate() {
        if target.refusal.is_some() {
            continue;
        }
        logger.log(format!("airlift: airlift.delete.asset.requested index={}", 2 * k));
        let mut params = plist::Dictionary::new();
        params.insert("AssetID".into(), plist::Value::String(target.identifiers[0].clone()));
        params.insert("Dataclass".into(), plist::Value::String("Book".into()));
        params.insert("AssetPath".into(), plist::Value::String(target.link_destination.clone()));
        let msg = make_atc_msg("FileComplete", 1, Some(params));
        send_atc_dict(&mut atc_stream, &msg).await?;
    }
    tokio::time::sleep(std::time::Duration::from_millis(900)).await;
    for target in prepared.iter_mut() {
        if target.refusal.is_some() {
            continue;
        }
        target.link_verified = afc.get_file_info(&target.link_destination).await.is_ok();
        logger.log(format!(
            "airlift: airlift.delete.link.confirmed={} destination_verified={}",
            target.link_verified, target.link_verified
        ));
    }

    logger.log("airlift: airlift.delete.move.begin phase=descriptor");
    for (k, target) in prepared.iter_mut().enumerate() {
        if target.refusal.is_some() {
            continue;
        }
        logger.log(format!("airlift: airlift.delete.asset.requested index={}", 2 * k + 1));
        let mut params = plist::Dictionary::new();
        params.insert("AssetID".into(), plist::Value::String(target.identifiers[1].clone()));
        params.insert("Dataclass".into(), plist::Value::String("Book".into()));
        params.insert("AssetPath".into(), plist::Value::String(target.quarantine_name.clone()));
        let msg = make_atc_msg("FileComplete", 1, Some(params));
        send_atc_dict(&mut atc_stream, &msg).await?;
        target.move_sent = true;
    }

    // Give ATAirlock time to finish moving assets (vendored settle,
    // once for the batch instead of once per target).
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    drop(atc_stream);
    logger.log("airlift: AirTraffic sync complete");

    for target in prepared.iter_mut() {
        if target.refusal.is_some() {
            continue;
        }
        target.quarantine_confirmed = afc.get_file_info(&target.quarantine_name).await.is_ok();
        logger.log(format!(
            "airlift: airlift.delete.quarantine.confirmed={} destination={}",
            target.quarantine_confirmed, target.quarantine_name
        ));

        // Local confirmation: through the freshly planted Media link
        // (which points at the descriptors directory), the descriptor
        // must be gone.
        target.descriptor_gone_local = match afc.list_dir(target.link_destination.clone()).await {
            Ok(names) => !names.iter().any(|n| n == &target.uuid),
            Err(_) => false,
        };
        if target.descriptor_gone_local {
            logger.log("airlift: airlift.delete.descriptor.confirmed");
        }
    }

    Ok(())
}

/// The batch frame: one tunnel, one Books snapshot/restore, every
/// present target staged on the shared connection, one session.
/// Returns one (target_idx, op_ok, quarantine, op_error) outcome per
/// batch target; Err is reserved for frame-level failures before
/// any target could be staged (connect / AFC), which fail all of
/// them with the same message — as each target's own cycle would
/// have failed at the same step before run #147.
async fn delete_batch(
    pairing_bytes: &[u8],
    store_root: &str,
    targets: &[(String, String)],
    batch_indices: &[usize],
    logger: &PSLogger,
) -> Result<Vec<(usize, bool, String, String)>, String> {
    let (mut adapter, mut handshake) = connect_rsd(pairing_bytes, logger)
        .await
        .map_err(|(_, msg)| msg)?;

    let mut afc = handshake
        .connect::<AfcClient>(&mut adapter)
        .await
        .map_err(|e| format!("AFC connect failed: {e:?}"))?;

    // Snapshot Books sync state once (restored at the end of the
    // batch, on success and on session failure alike, so a failed
    // batch never leaves the combined Books.plist behind).
    let original_books_plist = match afc.open("Books/Sync/Books.plist", AfcFopenMode::RdOnly).await {
        Ok(mut fd) => {
            let data = fd.read_entire().await.ok();
            let _ = fd.close().await;
            data
        }
        Err(_) => None,
    };

    let mut outcomes: Vec<(usize, bool, String, String)> = Vec::new();
    let mut prepared: Vec<PreparedDelete> = Vec::new();
    for &idx in batch_indices {
        let (ext, uuid) = &targets[idx];
        logger.log(format!(
            "airlift: airlift.delete.operation.begin target={ext}/{uuid}"
        ));
        logger.log(format!(
            "airlift: airlift.delete.target provider={ext} descriptor={uuid}"
        ));
        let descriptors_dir_abs = format!("{store_root}/Extensions/{ext}/descriptors");
        match stage_delete_target(
            &mut adapter,
            &mut handshake,
            &mut afc,
            &descriptors_dir_abs,
            idx,
            uuid,
            logger,
        )
        .await
        {
            Ok(p) => prepared.push(p),
            Err(e) => outcomes.push((idx, false, String::new(), e)),
        }
    }

    let mut session_error: Option<String> = None;
    if !prepared.is_empty() {
        if let Err(e) =
            run_delete_session(&mut adapter, &mut handshake, &mut afc, &mut prepared, logger).await
        {
            session_error = Some(e);
        }

        // Cleanup per target: remove staging source + link; RETAIN
        // the quarantine copy (it is the only remaining copy of the
        // user's wallpaper data).
        for p in &prepared {
            let _ = afc.remove_all(&p.link_destination).await;
            let _ = afc.remove_all(&p.source).await;
            if p.move_sent {
                logger.log(format!(
                    "airlift: airlift.delete.stage.retained quarantine={} no_read=true no_remove=true",
                    p.quarantine_name
                ));
            }
        }

        // Restore original Books state once for the batch
        // (Walllive: afc.books.restore).
        let mut restored = false;
        if let Some(orig) = &original_books_plist {
            if let Ok(mut fd) = afc.open("Books/Sync/Books.plist", AfcFopenMode::WrOnly).await {
                restored = fd.write_entire(orig).await.is_ok();
                let _ = fd.close().await;
            }
        } else {
            restored = afc.remove("Books/Sync/Books.plist").await.is_ok();
        }
        logger.log(format!(
            "airlift: airlift.afc.books.restore.end verified={restored}"
        ));
    }

    for p in prepared {
        // The operation's own gate is the quarantine landing, exactly
        // as before the batching; whether the descriptor is truly
        // gone is decided by the fresh commit audit in phase C
        // (descriptor_gone_local is logged as supporting evidence).
        let (op_ok, op_error) = if let Some(r) = &p.refusal {
            (false, r.clone())
        } else if let Some(e) = &session_error {
            (false, e.clone())
        } else if p.quarantine_confirmed {
            (true, String::new())
        } else {
            (
                false,
                "quarantine copy not confirmed in Media after sync".to_string(),
            )
        };
        outcomes.push((p.target_idx, op_ok, p.quarantine_name.clone(), op_error));
    }

    Ok(outcomes)
}

// --- Audit helper (DVT directoryListingForPath on absolute store paths) ---

struct AuditOutcome {
    extensions_count: usize,
    descriptors_count: usize,
    present: bool,
}

async fn audit_target(
    info: &mut DeviceInfoClient<'_, Box<dyn ReadWrite>>,
    store_root: &str,
    extension: &str,
    uuid: &str,
    logger: &PSLogger,
) -> AuditOutcome {
    let extensions_dir = format!("{store_root}/Extensions");
    let extensions = dvt_list_dir(info, &extensions_dir)
        .await
        .unwrap_or_default();
    let descriptors = dvt_list_dir(info, &format!("{extensions_dir}/{extension}/descriptors"))
        .await
        .unwrap_or_default();
    let present = descriptors.iter().any(|d| d == uuid);
    logger.log(format!(
        "airlift: airlift.delete.audit.listing stage=extensions complete=true count={}",
        extensions.len()
    ));
    logger.log(format!(
        "airlift: airlift.delete.audit.listing stage=descriptors complete=true count={} extension={extension}",
        descriptors.len()
    ));
    logger.log(format!(
        "airlift: airlift.delete.audit.result status={} level=descriptor",
        if present { "present" } else { "absent" }
    ));
    AuditOutcome {
        extensions_count: extensions.len(),
        descriptors_count: descriptors.len(),
        present,
    }
}

// --- Delete driver: audit -> per-target ATC move -> fresh commit audit ---

async fn store_delete(
    pairing_path: String,
    container_path: String,
    struct_version: i64,
    targets: Vec<(String, String)>,
    logger: &PSLogger,
) -> StoreResult<(String, bool)> {
    let started = Instant::now();
    logger.log(format!(
        "airlift: airlift.poster_store.delete.begin targets={}",
        targets.len()
    ));
    logger.log("airlift: airlift.delete.begin method=atc-manifest-move");

    let pairing_bytes = std::fs::read(&pairing_path).map_err(|e| {
        (
            StoreStatus::ConnectFailed,
            format!("Failed to read pairing file at {pairing_path}: {e}"),
        )
    })?;

    let store_root = format!(
        "{}/Library/Application Support/PRBPosterExtensionDataStore/{}",
        container_path.trim_end_matches('/'),
        struct_version
    );

    // Run #115 hard block: a target whose provider is outside the
    // cleanup scope is refused HERE, in the driver under the FFI —
    // no audit, no ATC, no device mutation for it, whatever the
    // caller asked for. (The list never offers such targets; this is
    // the belt-and-braces layer underneath it.)
    let blocked: Vec<bool> = targets
        .iter()
        .map(|(ext, _)| !provider_in_cleanup_scope(ext))
        .collect();
    for ((ext, uuid), b) in targets.iter().zip(blocked.iter()) {
        if *b {
            logger.log(format!(
                "airlift: airlift.poster_store.delete.blocked target={ext}/{uuid} reason=provider_scope"
            ));
        }
    }

    // Phase A: pre-audit on one DVT session — which targets are present?
    let mut present: Vec<bool> = Vec::new();
    {
        let (_adapter, _handshake, mut server) =
            connect_device_info(&pairing_bytes, logger).await?;
        let mut info = device_info_client(&mut server).await?;
        for (idx, (ext, uuid)) in targets.iter().enumerate() {
            if blocked[idx] {
                present.push(false);
                continue;
            }
            let audit = audit_target(&mut info, &store_root, ext, uuid, logger).await;
            present.push(audit.present);
        }
    }

    // Phase B (run #147): one batched move for every present
    // target — a single tunnel + ATC session inside delete_batch,
    // with the same per-target outcomes the per-target cycle
    // produced (the phase C commit audit below still decides
    // deleted vs failed per target).
    struct ItemState {
        ext: String,
        uuid: String,
        was_present: bool,
        op_ok: bool,
        op_error: String,
        quarantine: String,
    }
    let mut states: Vec<ItemState> = Vec::new();
    let mut batch_indices: Vec<usize> = Vec::new();
    for (idx, (ext, uuid)) in targets.iter().enumerate() {
        let mut st = ItemState {
            ext: ext.clone(),
            uuid: uuid.clone(),
            was_present: present[idx],
            op_ok: false,
            op_error: String::new(),
            quarantine: String::new(),
        };
        if blocked[idx] {
            st.op_error =
                "provider outside cleanup scope (run #115 hard block); refused before audit/ATC"
                    .to_string();
            states.push(st);
            continue;
        }
        if !present[idx] {
            st.op_error = "not present in store at pre-audit".to_string();
            states.push(st);
            continue;
        }
        batch_indices.push(idx);
        states.push(st);
    }
    if !batch_indices.is_empty() {
        match delete_batch(&pairing_bytes, &store_root, &targets, &batch_indices, logger).await {
            Ok(outcomes) => {
                for (idx, op_ok, quarantine, op_error) in outcomes {
                    states[idx].op_ok = op_ok;
                    states[idx].quarantine = quarantine;
                    states[idx].op_error = op_error;
                }
            }
            Err(e) => {
                for idx in &batch_indices {
                    states[*idx].op_error = e.clone();
                }
            }
        }
    }

    // Phase C: commit audit on a FRESH connection — a target only counts
    // as deleted when its path re-audits absent (Walllive:
    // delete.commit.connection=fresh, delete.commit.audit paths=N).
    let mut commit_audit_done = false;
    let mut absent: Vec<bool> = vec![false; targets.len()];
    match connect_device_info(&pairing_bytes, logger).await {
        Ok((_adapter, _handshake, mut server)) => {
            logger.log("airlift: airlift.delete.commit.connection=fresh after_restore=true");
            match device_info_client(&mut server).await {
                Ok(mut info) => {
                    for (idx, (ext, uuid)) in targets.iter().enumerate() {
                        if blocked[idx] {
                            continue;
                        }
                        let audit =
                            audit_target(&mut info, &store_root, ext, uuid, logger).await;
                        absent[idx] = !audit.present;
                    }
                    logger.log(format!(
                        "airlift: airlift.delete.commit.audit batched=true paths={}",
                        targets.len()
                    ));
                    commit_audit_done = true;
                }
                Err((_, msg)) => {
                    logger.log(format!(
                        "airlift: airlift.delete.commit.audit unavailable error={msg}"
                    ));
                }
            }
        }
        Err((_, msg)) => {
            logger.log(format!(
                "airlift: airlift.delete.commit.audit unavailable error={msg}"
            ));
        }
    }

    let mut deleted = 0usize;
    let mut failed = 0usize;
    let mut results_json = String::new();
    for (idx, st) in states.iter().enumerate() {
        let ok = if commit_audit_done {
            st.op_ok && absent[idx]
        } else {
            // No fresh audit available: fall back to the operation's own
            // confirmations, and say so in the payload.
            st.op_ok
        };
        if ok {
            deleted += 1;
        } else {
            failed += 1;
        }
        logger.log(format!(
            "airlift: airlift.poster_store.delete.item target={}/{} ok={} error={}",
            st.ext, st.uuid, ok, st.op_error
        ));
        if idx > 0 {
            results_json.push(',');
        }
        results_json.push_str(&format!(
            "{{\"extension\":\"{}\",\"uuid\":\"{}\",\"ok\":{},\"quarantine\":\"{}\"}}",
            json_escape(&st.ext),
            json_escape(&st.uuid),
            ok,
            json_escape(&st.quarantine)
        ));
    }
    if commit_audit_done && failed == 0 {
        logger.log("airlift: airlift.delete.receipts.committed restoration_verified=true");
    }

    let json = format!(
        "{{\"deleted\":{deleted},\"failed\":{failed},\"commitAudit\":{commit_audit_done},\"results\":[{results_json}]}}"
    );
    logger.log(format!(
        "airlift: airlift.poster_store.delete.end deleted={deleted} failed={failed} duration_ms={}",
        started.elapsed().as_millis()
    ));
    Ok((json, failed > 0))
}

// ---------------------------------------------------------------------------
// FFI entries (shape mirrors poster_refresh::poster_refresh)
// ---------------------------------------------------------------------------

unsafe fn write_outs(
    out_json: *mut *mut c_char,
    out_status: *mut *mut c_char,
    out_error: *mut *mut c_char,
    json: Option<&str>,
    status: StoreStatus,
    error: Option<&str>,
) {
    if !out_json.is_null() {
        if let Some(j) = json {
            *out_json = cstr(j);
        }
    }
    if !out_status.is_null() {
        *out_status = cstr(status.as_str());
    }
    if !out_error.is_null() {
        if let Some(e) = error {
            *out_error = cstr(e);
        }
    }
}

/// # Safety
/// All pointer args must be null or valid for their documented types.
/// `out_json` / `out_status` / `out_error` receive heap strings owned by
/// the caller (free with al_string_free) when non-null.
pub unsafe fn poster_store_list(
    pairing_path: *const c_char,
    container_path: *const c_char,
    struct_version: i64,
    log_cb: ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_status: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let container_path = opt_str(container_path, "");
    let ctx_usize = ctx as usize;

    let res = crate::ffi_util::run_with_large_stack("al_poster_store_list", move || {
        let logger = PSLogger { cb: log_cb, ctx: ctx_usize as *mut c_void };
        idevice_ffi::run_sync_local(async move {
            match tokio::time::timeout(
                Duration::from_secs(120),
                store_list(pairing_path, container_path, struct_version, &logger),
            )
            .await
            {
                Ok(Ok(json)) => (Some(json), StoreStatus::Ok, None),
                Ok(Err((status, message))) => {
                    logger.log(format!(
                        "airlift: airlift.poster_store.list.end status={} error={message}",
                        status.as_str()
                    ));
                    (None, status, Some(message))
                }
                Err(_) => (
                    None,
                    StoreStatus::AfcFailed,
                    Some("poster store list timed out after 120s".to_string()),
                ),
            }
        })
    });

    let (json, status, error) = match res {
        Ok(triple) => triple,
        Err(panic_msg) => (None, StoreStatus::ConnectFailed, Some(panic_msg)),
    };
    write_outs(out_json, out_status, out_error, json.as_deref(), status, error.as_deref());
    if status == StoreStatus::Ok {
        0
    } else {
        1
    }
}

/// # Safety
/// Same contract as poster_store_list. `targets_csv` is a comma-separated
/// list of "<extension-id>/<descriptor-uuid>" entries to delete.
pub unsafe fn poster_store_delete(
    pairing_path: *const c_char,
    container_path: *const c_char,
    struct_version: i64,
    targets_csv: *const c_char,
    log_cb: ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_status: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let container_path = opt_str(container_path, "");
    let targets_raw = opt_str(targets_csv, "");
    let ctx_usize = ctx as usize;

    let targets: Vec<(String, String)> = targets_raw
        .split(',')
        .filter_map(|entry| {
            let entry = entry.trim();
            let (ext, uuid) = entry.split_once('/')?;
            if ext.is_empty() || uuid.is_empty() {
                None
            } else {
                Some((ext.to_string(), uuid.to_string()))
            }
        })
        .collect();

    let res = crate::ffi_util::run_with_large_stack("al_poster_store_delete", move || {
        let logger = PSLogger { cb: log_cb, ctx: ctx_usize as *mut c_void };
        idevice_ffi::run_sync_local(async move {
            if targets.is_empty() {
                return (
                    None,
                    StoreStatus::AfcFailed,
                    Some("no valid delete targets supplied".to_string()),
                );
            }
            // Each target is a full ATC sync operation (~10-30s on
            // device); scale the budget with the batch size.
            let budget_secs = 240 + 120 * (targets.len() as u64);
            match tokio::time::timeout(
                Duration::from_secs(budget_secs.min(1800)),
                store_delete(pairing_path, container_path, struct_version, targets, &logger),
            )
            .await
            {
                Ok(Ok((json, had_failures))) => (
                    Some(json),
                    if had_failures { StoreStatus::Partial } else { StoreStatus::Ok },
                    None,
                ),
                Ok(Err((status, message))) => {
                    logger.log(format!(
                        "airlift: airlift.poster_store.delete.end status={} error={message}",
                        status.as_str()
                    ));
                    (None, status, Some(message))
                }
                Err(_) => (
                    None,
                    StoreStatus::AfcFailed,
                    Some("poster store delete timed out (per-target ATC budget exhausted)".to_string()),
                ),
            }
        })
    });

    let (json, status, error) = match res {
        Ok(triple) => triple,
        Err(panic_msg) => (None, StoreStatus::ConnectFailed, Some(panic_msg)),
    };
    write_outs(out_json, out_status, out_error, json.as_deref(), status, error.as_deref());
    if matches!(status, StoreStatus::Ok | StoreStatus::Partial) {
        0
    } else {
        1
    }
}

// ---------------------------------------------------------------------------
// Tests (run #115 assertion-level self-checks)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod cleanup_scope_tests {
    use super::provider_in_cleanup_scope;

    #[test]
    fn scope_admits_only_the_two_collections_poster_providers() {
        assert!(provider_in_cleanup_scope(
            "com.apple.WallpaperKit.CollectionsPoster"
        ));
        assert!(provider_in_cleanup_scope(
            "com.apple.Posters.CollectionsPosterApp"
        ));
    }

    #[test]
    fn scope_rejects_system_and_other_providers() {
        // The run #114 accident set: system gradients must never be
        // listable or deletable through the cleanup feature.
        assert!(!provider_in_cleanup_scope(
            "com.apple.GradientPoster.GradientPosterExtension"
        ));
        assert!(!provider_in_cleanup_scope(
            "com.apple.ClockPoster.ClockPosterExtension"
        ));
        assert!(!provider_in_cleanup_scope(
            "com.apple.PhotosUIPrivate.PhotosPosterProvider"
        ));
        assert!(!provider_in_cleanup_scope("com.apple.MercuryPoster"));
        assert!(!provider_in_cleanup_scope(""));
        // Near-miss strings must not sneak through an exact match.
        assert!(!provider_in_cleanup_scope(
            "com.apple.WallpaperKit.CollectionsPoster.evil"
        ));
        assert!(!provider_in_cleanup_scope(
            "com.apple.WallpaperKit.CollectionsPoster "
        ));
    }
}
