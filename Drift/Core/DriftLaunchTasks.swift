import Foundation
import Minimuxer

/// Launch work that used to run synchronously inside `DriftApp.init()`.
///
/// Collection #227 (2026-11-12): a user on iOS 18 reported the app
/// opening to a black screen and then dying. The two shapes that fit
/// that symptom are a first-render trap and the launch watchdog
/// killing an app whose first frame takes too long — and everything
/// in the old `init()` ran on the main thread, before the first
/// frame: a media-store sweep whose cost grows with whatever an old
/// build left in the container, plus two native-library installs.
/// None of it is needed to put the first frame on screen, so it all
/// lives here now, run once from the root view's launch task — after
/// the frame exists, in the same order, with the same log lines, so
/// log-based diagnosis sees no difference. The sweep itself is
/// detached onto a utility queue: it is pure housekeeping.
enum DriftLaunchTasks {
    private static var didRun = false

    /// One-shot. Called at the top of the root view's launch task,
    /// before the session bootstrap, so the vendor logging below is
    /// already on when the tunnel core starts.
    static func runAfterFirstFrame() {
        guard !didRun else { return }
        didRun = true

        // The vendor's protocol logging, at its default (on). The
        // development-mode switch that used to gate this was removed
        // with the tweak system in 2.0.0; with no dev mode the
        // behaviour is the old "dev mode off" behaviour — restore the
        // vendor default.
        MinimuxerLogging.setLogging(true)

        // AirLift's log sink. The original reasoning for installing it
        // in `init()` was that a launch proves the static archive's
        // symbols good before any flash can need them; that proof
        // still holds here — no flash can start before the launch
        // task has run — without putting the FFI call inside the
        // watchdog's window. The sink is a one-shot `al_log_init` — a
        // second call returns "already subscribed" and logs nothing —
        // so it belongs where it can only happen once.
        if Airlift.install() {
            AppLog.write("AirLift: log sink installed (AirTraffic escape available on iOS 27+)")
        } else {
            AppLog.write("AirLift: log sink already installed by the library")
        }
        // Referenced so the linker keeps `_ALGetGrappaToken`: the FFI
        // looks it up with `dlsym(RTLD_DEFAULT, …)` when it writes,
        // and an unreferenced symbol would be stripped and the write
        // would fail on `SyncFailed` with no token to blame.
        Airlift.installGrappaTokenProvider()

        // Drift uses the external tunnel only (LocalDevVPN or a
        // similar app): it starts no tunnel server of its own. Log
        // the tunnel verdict at launch — on device the console is not
        // reachable, and the tunnel state is the first thing a failed
        // run needs to show in the app log.
        AppLog.write("Tunnel status: \(Tunnel.describe()) — external tunnel (LocalDevVPN) mode")

        // Older builds pulled the device's photos and videos into the
        // container's media store partway through a flash; feedback
        // #27 removed the step, and anything still parked there is a
        // leftover copy with nothing pointing at it. Reclaim it —
        // only the container's copies; the device's own library is
        // never involved. The enumeration walks every leftover file,
        // which is exactly the kind of launch cost #227 is about, so
        // it runs detached and reports when it is done.
        Task.detached(priority: .utility) {
            let reclaimedMedia = DriftEngine.reclaimResidualMediaStore()
            if reclaimedMedia > 0 {
                AppLog.write("AFC media: 已清理旧版拉进容器的媒体副本，回收 "
                    + ByteCountFormatter.string(fromByteCount: reclaimedMedia, countStyle: .file)
                    + "（\(reclaimedMedia) 字节，仅 App 容器内的副本，设备相册原件未动）")
            }
        }
    }
}
