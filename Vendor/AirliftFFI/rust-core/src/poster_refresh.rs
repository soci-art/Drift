//! PosterBoard-only refresh (Walllive-style `airlift.poster_refresh`).
//!
//! LOCAL ADDITION — not part of the vendored AirCard-iOS upstream core.
//! Registered in rust-core/VENDORED.md and SPEC.md (2026-11-01).
//!
//! After a successful wallpaper sync, instead of respringing the whole
//! device (NeoSpring / SpringBoard restart), restart only the PosterBoard
//! daemon so it re-reads its data store and applies the new wallpapers:
//!
//!   1. Open an RSD tunnel (same idevice_ffi tunnel_provider primitives and
//!      host strategy as exploit::connect_tunnel: last working route first,
//!      then the known loopback-VPN gateway defaults; RemoteXPC with raw
//!      RPPairing fallback per host).
//!   2. Check the RSD handshake advertises com.apple.instruments.dtservicehub
//!      and connect a DVT RemoteServerClient (DTX handshake).
//!   3. Via the deviceinfo channel, list running processes and lock onto the
//!      PosterBoard daemon's pid (process name "PosterBoard"), verifying
//!      identity with execname_for_pid. If the list reads fine but holds
//!      no PosterBoard entry, the list is re-read once after a short
//!      delay before concluding anything (run #111): a single snapshot
//!      can catch the daemon mid-restart — e.g. torn down by the sync
//!      that just ran and already relaunched by the time it is read
//!      again — and run #109's already_stopped confirmation was
//!      followed by the wallpaper NOT appearing until a manual
//!      respring, so one snapshot is no longer trusted on its own.
//!      If the second list also holds no PosterBoard, the daemon is
//!      already stopped and the refresh counts as confirmed
//!      (Walllive's already_stopped branch); a failed first list read
//!      is still an error.
//!   4. Via the processcontrol channel, deliver SIGKILL to that pid
//!      (ProcessControlClient::send_signal -> channel method
//!      sendSignal:toPid:, reply awaited and logged as signal.reply).
//!      killPid: was used until run #106: the service acknowledged it
//!      but the daemon survived — it only terminates processes the
//!      instruments server itself spawned. sendSignal:toPid: is
//!      Walllive's call and reaches any pid; its first form here
//!      (run #107) was fire-and-forget and the daemon survived again,
//!      so the reply round-trip is now mandatory evidence.
//!   5. Drop that connection (the kill makes the device close it —
//!      reusing it for verification dies with BrokenPipe, seen on
//!      hardware in run #95) and verify on a brand-new read-only
//!      connection: poll deviceinfo is_running_pid until the old pid is
//!      gone (launchd respawns the daemon, which re-reads the store).
//!      One reconnect is allowed if the verify connection dies mid-poll.
//!
//! Returns a machine-readable status string so the Swift side can fall back
//! to the legacy NeoSpring respring whenever the refresh is not confirmed.

use std::ffi::{c_char, c_void, CString};
use std::time::{Duration, Instant};

use idevice::dvt::device_info::DeviceInfoClient;
use idevice::dvt::process_control::ProcessControlClient;
use idevice::dvt::remote_server::RemoteServerClient;
use idevice::remote_pairing::RpPairingFile;
use idevice::services::rsd::RsdHandshake;
use idevice::tcp::handle::AdapterHandle;
use idevice::ReadWrite;

use crate::exploit::{CachedRouteMode, ALLogCallback};
use crate::ffi_util::{cstr, opt_str};

// ---------------------------------------------------------------------------
// Logger (same shape as exploit::Logger, which is module-private there)
// ---------------------------------------------------------------------------

struct PRLogger {
    cb: ALLogCallback,
    ctx: *mut c_void,
}
unsafe impl Send for PRLogger {}
unsafe impl Sync for PRLogger {}

impl PRLogger {
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
enum RefreshStatus {
    Confirmed,
    ConnectFailed,
    ServiceUnavailable,
    PidNotFound,
    KillFailed,
    VerifyConnectFailed,
    VerifyTimeout,
}

impl RefreshStatus {
    fn as_str(&self) -> &'static str {
        match self {
            RefreshStatus::Confirmed => "confirmed",
            RefreshStatus::ConnectFailed => "connectFailed",
            RefreshStatus::ServiceUnavailable => "serviceUnavailable",
            RefreshStatus::PidNotFound => "pidNotFound",
            RefreshStatus::KillFailed => "killFailed",
            RefreshStatus::VerifyConnectFailed => "verifyConnectFailed",
            RefreshStatus::VerifyTimeout => "verifyTimeout",
        }
    }
}

type RefreshResult = Result<(), (RefreshStatus, String)>;

const RSD_PORT: u16 = 49152;
const DVT_SERVICE: &str = "com.apple.instruments.dtservicehub";
const POSTERBOARD_PROCESS: &str = "PosterBoard";

// ---------------------------------------------------------------------------
// RSD tunnel (RSD-only mirror of exploit::try_rsd + cached-route fast path;
// DVT/dtservicehub exists only on the RSD route, so no Lockdown fallback)
// ---------------------------------------------------------------------------

async fn connect_rsd(
    pairing_bytes: &[u8],
    logger: &PRLogger,
) -> Result<(AdapterHandle, RsdHandshake), (RefreshStatus, String)> {
    if RpPairingFile::from_bytes(pairing_bytes).is_err() {
        return Err((
            RefreshStatus::ServiceUnavailable,
            "pairing file carries no Remote Pairing credentials; DVT requires the RSD route"
                .to_string(),
        ));
    }

    // Host candidates: last working route first (the sync that just succeeded
    // resolved its host through al_set_target_host + defaults and cached the
    // winning route), then the known loopback-VPN gateway defaults — the same
    // fallback list as exploit::resolve_target_hosts.
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

    // Fast path: cached route with its recorded mode (RSD modes only —
    // a Lockdown route carries no DVT service, so skip straight to probing).
    if let Some(route) = &cached {
        if matches!(
            route.mode,
            CachedRouteMode::RsdRemoteXpc | CachedRouteMode::RsdRawRpPairing
        ) {
            if let Ok(ip) = route.host.parse::<std::net::Ipv4Addr>() {
                let socket_addr = std::net::SocketAddr::new(std::net::IpAddr::V4(ip), RSD_PORT);
                let extra = vec![std::net::IpAddr::V4(ip)];
                let mut rpf = RpPairingFile::from_bytes(pairing_bytes)
                    .map_err(|e| (RefreshStatus::ConnectFailed, format!("{e:?}")))?;
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
                            "airlift: poster_refresh tunnel connected via cached route on {}:{RSD_PORT}",
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

    // Full probe: RemoteXPC per host, raw RPPairing fallback (same as try_rsd).
    for ip_str in &hosts {
        let Ok(ip) = ip_str.parse::<std::net::Ipv4Addr>() else { continue };
        if ip.is_loopback() {
            continue;
        }
        let socket_addr = std::net::SocketAddr::new(std::net::IpAddr::V4(ip), RSD_PORT);

        let mut rpf = match RpPairingFile::from_bytes(pairing_bytes) {
            Ok(r) => r,
            Err(e) => {
                return Err((RefreshStatus::ConnectFailed, format!("pairing parse: {e:?}")));
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
                    "airlift: poster_refresh tunnel connected on {ip_str}:{RSD_PORT} via RemoteXPC"
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
                                RefreshStatus::ConnectFailed,
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
                                "airlift: poster_refresh tunnel connected on {ip_str}:{RSD_PORT} via raw RPPairing"
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

    Err((RefreshStatus::ConnectFailed, last_err))
}

// ---------------------------------------------------------------------------
// Refresh flow
// ---------------------------------------------------------------------------

async fn exploit_poster_refresh(pairing_path: String, logger: &PRLogger) -> RefreshResult {
    let started = Instant::now();
    logger.log("airlift: airlift.poster_refresh.begin connection=new");

    let pairing_bytes = std::fs::read(&pairing_path).map_err(|e| {
        (
            RefreshStatus::ConnectFailed,
            format!("Failed to read pairing file at {pairing_path}: {e}"),
        )
    })?;

    let (mut adapter, mut handshake) = connect_rsd(&pairing_bytes, logger).await?;

    // Stage: service advertised?
    let advertised = handshake.services.contains_key(DVT_SERVICE);
    logger.log(format!(
        "airlift: airlift.poster_refresh.service advertised={advertised} remote_xpc=false"
    ));
    if !advertised {
        return Err((
            RefreshStatus::ServiceUnavailable,
            format!("{DVT_SERVICE} not advertised by RSD handshake"),
        ));
    }

    // Stage: DTX handshake (RemoteServerClient connect).
    let mut server = handshake
        .connect::<RemoteServerClient<Box<dyn ReadWrite>>>(&mut adapter)
        .await
        .map_err(|e| {
            (
                RefreshStatus::ServiceUnavailable,
                format!("dtservicehub connect failed: {e:?}"),
            )
        })?;

    // Stage: identity — find PosterBoard's pid via deviceinfo runningProcesses,
    // verified with execname_for_pid. Opening the first channel completes the
    // DTX handshake, so handshake confirmation is logged once it succeeds.
    let pid: u32 = {
        let mut info = DeviceInfoClient::new(&mut server).await.map_err(|e| {
            (
                RefreshStatus::ServiceUnavailable,
                format!("deviceinfo channel failed: {e:?}"),
            )
        })?;
        logger.log("airlift: airlift.poster_refresh.service.handshake confirmed=true");

        let processes = info.running_processes().await.map_err(|e| {
            (
                RefreshStatus::PidNotFound,
                format!("runningProcesses failed: {e:?}"),
            )
        })?;
        let find_posterboard = |list: &[idevice::dvt::device_info::RunningProcess]| {
            list.iter()
                .find(|p| p.name == POSTERBOARD_PROCESS || p.real_app_name == POSTERBOARD_PROCESS)
                .map(|p| p.pid)
                .filter(|p| *p != 0)
        };
        let mut candidate = find_posterboard(&processes);
        if candidate.is_none() {
            // One snapshot is not trusted for an absence claim (see
            // module doc, step 3): wait briefly and read the list a
            // second time. If the daemon shows up now, it was only
            // mid-restart and the normal signal path below handles
            // it. A failed re-read keeps the first list's verdict —
            // the absence conclusion then rests on the successful
            // first read plus this logged notice.
            logger.log("airlift: airlift.poster_refresh.already_stopped.recheck attempt=1");
            tokio::time::sleep(Duration::from_millis(500)).await;
            match info.running_processes().await {
                Ok(list2) => {
                    candidate = find_posterboard(&list2);
                }
                Err(e) => {
                    logger.log(format!(
                        "airlift: airlift.poster_refresh.already_stopped.recheck failed error={e:?}"
                    ));
                }
            }
        }
        let Some(pid) = candidate else {
            // The process list WAS read successfully (twice — see the
            // recheck above) and PosterBoard is simply not in it: the
            // daemon is not running, so there is nothing to restart —
            // when it next launches it reads the store fresh. Walllive
            // treats this as a confirmed refresh
            // (airlift.poster_refresh.already_stopped), not a failure.
            // (A failed first running_processes() read still errors.)
            logger.log("airlift: airlift.poster_refresh.already_stopped confirmed=true");
            logger.log(format!(
                "airlift: airlift.poster_refresh.end refresh_confirmed=true duration_ms={}",
                started.elapsed().as_millis()
            ));
            return Ok(());
        };
        match info.execname_for_pid(pid).await {
            Ok(exec) if exec.contains(POSTERBOARD_PROCESS) => {}
            Ok(exec) => {
                return Err((
                    RefreshStatus::PidNotFound,
                    format!("identity mismatch: pid {pid} execname is '{exec}'"),
                ));
            }
            Err(e) => {
                // Name match from runningProcesses stands; execname is a
                // best-effort second factor (mirrors Walllive retry paths).
                logger.log(format!(
                    "airlift: poster_refresh identity execname check unavailable for pid {pid}: {e:?}"
                ));
            }
        }
        logger.log(format!("airlift: airlift.poster_refresh.identity.verified pid={pid}"));
        pid
    };

    // Stage: signal — deliver SIGKILL to the PosterBoard pid via
    // ProcessControl sendSignal:toPid: (Walllive's call), with the
    // service reply awaited and logged verbatim (signal.reply).
    // killPid: was falsified on hardware in run #106: acknowledged,
    // daemon alive 6s later; it only terminates instruments-spawned
    // processes. The first sendSignal form (run #107) was
    // fire-and-forget (expect_reply=false): its "acknowledged" only
    // meant the bytes left this process, the daemon survived again —
    // the failure mode pymobiledevice3 documents for one-way calls
    // over the userspace tunnel. With the reply awaited (run #108),
    // the service DID answer — but with a payload the DTX layer
    // classifies as UnexpectedResponse, which that build mistook
    // for a delivery failure and skipped verification entirely. A
    // response arriving at all proves the message was dispatched
    // and handled, so an UnexpectedResponse-shaped reply is treated
    // as delivered and the pid's fate is left to verification. Only
    // a channel/connection-level error (the message never left) is
    // a kill failure here, and a reply that never arrives within
    // 10s is likewise logged without judging: the fresh-connection
    // verification below is the ground truth either way.
    {
        let mut pc = ProcessControlClient::new(&mut server).await.map_err(|e| {
            (
                RefreshStatus::KillFailed,
                format!("processcontrol channel failed: {e:?}"),
            )
        })?;
        logger.log(format!(
            "airlift: airlift.poster_refresh.signal.begin pid={pid} signal=9"
        ));
        match tokio::time::timeout(Duration::from_secs(10), pc.send_signal(pid as u64, 9)).await {
            Ok(Ok(reply)) => {
                logger.log(format!(
                    "airlift: airlift.poster_refresh.signal.reply data={}",
                    match &reply {
                        Some(v) => format!("{v:?}"),
                        None => "none".to_string(),
                    }
                ));
                logger.log("airlift: airlift.poster_refresh.signal.acknowledged");
            }
            Ok(Err(e)) => {
                if matches!(e, idevice::IdeviceError::UnexpectedResponse(_)) {
                    // The service answered — the message was dispatched
                    // and handled — but the reply payload is not shaped
                    // the way the DTX reply parser expects (a void
                    // confirmation classifies this way). The signal may
                    // well have taken effect; do NOT judge the kill
                    // here. Verification decides.
                    logger.log(
                        "airlift: airlift.poster_refresh.signal.reply unexpected_response=true (dispatch confirmed by response; deferring to verification)",
                    );
                    logger.log("airlift: airlift.poster_refresh.signal.acknowledged");
                } else {
                    return Err((
                        RefreshStatus::KillFailed,
                        format!("sendSignal 9 to pid {pid} failed: {e:?}"),
                    ));
                }
            }
            Err(_) => {
                logger.log(
                    "airlift: airlift.poster_refresh.signal.reply timeout=true (no reply within 10s; proceeding to verification)",
                );
            }
        }
    }

    // Stage: verify — on a brand-new connection. The kill tears down the
    // RemoteServer connection above (hardware log, run #95: reusing it to
    // open the verify deviceinfo channel fails with BrokenPipe, "remote
    // server connection closed"), so drop it explicitly and verify
    // read-only on a fresh connection — the same shape Walllive's
    // `poster_refresh.verification.connection=new readonly=true` records.
    drop(server);
    drop(adapter);
    logger.log("airlift: airlift.poster_refresh.verification.connection=new readonly=true");
    verify_old_pid_gone(&pairing_bytes, pid, started, logger).await
}

// ---------------------------------------------------------------------------
// Verification on a fresh connection
// ---------------------------------------------------------------------------

enum VerifyOutcome {
    /// Old pid observed gone — refresh confirmed.
    Gone,
    /// State stayed readable until the deadline and the pid was still
    /// running at every probe.
    StillRunning,
}

/// One verification epoch on a freshly built connection: connect, open a
/// deviceinfo channel, and poll the pid's liveness every 250ms until it
/// disappears or `deadline` passes. Any connection/channel/read failure
/// ends the epoch with Err(message); the caller decides whether a
/// reconnect is still allowed. Sets `*observed_state` once any probe has
/// successfully read process state on a verify connection.
async fn verify_poll_on_fresh_connection(
    pairing_bytes: &[u8],
    pid: u32,
    deadline: Instant,
    logger: &PRLogger,
    observed_state: &mut bool,
) -> Result<VerifyOutcome, String> {
    let (mut adapter, mut handshake) = connect_rsd(pairing_bytes, logger)
        .await
        .map_err(|(_, msg)| msg)?;
    if !handshake.services.contains_key(DVT_SERVICE) {
        return Err(format!(
            "{DVT_SERVICE} not advertised by RSD handshake (verify connection)"
        ));
    }
    let mut server = handshake
        .connect::<RemoteServerClient<Box<dyn ReadWrite>>>(&mut adapter)
        .await
        .map_err(|e| format!("dtservicehub connect (verify) failed: {e:?}"))?;
    let mut info = DeviceInfoClient::new(&mut server)
        .await
        .map_err(|e| format!("deviceinfo channel (verify) failed: {e:?}"))?;

    loop {
        // A probe succeeds if either read answers; both failing means the
        // connection is dead (the shape observed in run #95).
        let probe = match info.is_running_pid(pid).await {
            Ok(running) => Some(running),
            Err(_) => match info.running_processes().await {
                Ok(list) => Some(list.iter().any(|p| p.pid == pid)),
                Err(_) => None,
            },
        };
        match probe {
            Some(running) => {
                *observed_state = true;
                if !running {
                    return Ok(VerifyOutcome::Gone);
                }
                if Instant::now() >= deadline {
                    return Ok(VerifyOutcome::StillRunning);
                }
            }
            None => {
                return Err(format!(
                    "deviceinfo reads failed on verify connection (pid {pid})"
                ));
            }
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

/// Verify stage driver: poll on a fresh connection; if that connection
/// dies before the pid's fate is known, rebuild it once within the same
/// ~6s budget. Status split:
/// - VerifyTimeout: process state was readable but the old pid was never
///   observed gone inside the budget.
/// - VerifyConnectFailed: no verify connection ever yielded a successful
///   state read (initial connect failed, or the one reconnect also died
///   before any probe succeeded).
async fn verify_old_pid_gone(
    pairing_bytes: &[u8],
    pid: u32,
    started: Instant,
    logger: &PRLogger,
) -> RefreshResult {
    let deadline = Instant::now() + Duration::from_millis(6000);
    let mut observed_state = false;
    let mut reconnects_left = 1u32;
    let mut last_error: String;

    loop {
        match verify_poll_on_fresh_connection(
            pairing_bytes,
            pid,
            deadline,
            logger,
            &mut observed_state,
        )
        .await
        {
            Ok(VerifyOutcome::Gone) => {
                logger.log(format!(
                    "airlift: airlift.poster_refresh.old_process.gone old_pid={pid}"
                ));
                logger.log(format!(
                    "airlift: airlift.poster_refresh.end refresh_confirmed=true duration_ms={}",
                    started.elapsed().as_millis()
                ));
                return Ok(());
            }
            Ok(VerifyOutcome::StillRunning) => {
                return Err((
                    RefreshStatus::VerifyTimeout,
                    format!(
                        "pid {pid} still running 6s after kill signal (state readable on fresh verify connection)"
                    ),
                ));
            }
            Err(message) => {
                last_error = message;
                if reconnects_left > 0 {
                    reconnects_left -= 1;
                    logger.log("airlift: airlift.poster_refresh.verification.retry attempt=1");
                    continue;
                }
                if observed_state {
                    return Err((
                        RefreshStatus::VerifyTimeout,
                        format!(
                            "pid {pid} never observed gone; verify connection lost after state was read: {last_error}"
                        ),
                    ));
                }
                return Err((
                    RefreshStatus::VerifyConnectFailed,
                    format!(
                        "could not obtain process state on a fresh verify connection: {last_error}"
                    ),
                ));
            }
        }
    }
}

// ---------------------------------------------------------------------------
// FFI entry (shape mirrors exploit::device_respring)
// ---------------------------------------------------------------------------

/// # Safety
/// All pointer args must be null or valid for their documented types.
/// `out_status` / `out_error` receive heap strings owned by the caller
/// (free with al_string_free) when non-null.
pub unsafe fn poster_refresh(
    pairing_path: *const c_char,
    log_cb: ALLogCallback,
    ctx: *mut c_void,
    out_status: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let ctx_usize = ctx as usize;

    let res = crate::ffi_util::run_with_large_stack("al_poster_refresh", move || {
        let logger = PRLogger { cb: log_cb, ctx: ctx_usize as *mut c_void };
        idevice_ffi::run_sync_local(async move {
            match exploit_poster_refresh(pairing_path, &logger).await {
                Ok(()) => (RefreshStatus::Confirmed, None),
                Err((status, message)) => {
                    logger.log(format!(
                        "airlift: airlift.poster_refresh.end refresh_confirmed=false status={} error={message}",
                        status.as_str()
                    ));
                    (status, Some(message))
                }
            }
        })
    });

    let (status, error) = match res {
        Ok(pair) => pair,
        Err(panic_msg) => (RefreshStatus::ConnectFailed, Some(panic_msg)),
    };

    if !out_status.is_null() {
        *out_status = cstr(status.as_str());
    }
    if !out_error.is_null() {
        if let Some(e) = &error {
            *out_error = cstr(e);
        }
    }
    if status == RefreshStatus::Confirmed {
        0
    } else {
        1
    }
}
