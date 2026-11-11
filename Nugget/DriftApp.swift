import SwiftUI
import Minimuxer

@main
struct DriftApp: App {
    init() {
        // The vendor's protocol logging, at its default (on). The
        // development-mode switch that used to gate this was removed with
        // the tweak system in 2.0.0; with no dev mode the behaviour is the
        // old "dev mode off" behaviour — restore the vendor default.
        MinimuxerLogging.setLogging(true)

        // The tunnel address is not user-editable in Drift: detection always
        // uses the LocalDevVPN defaults, so clear any override an earlier
        // build's editor may have stored.
        Tunnel.resetToDefaults()

        // Older builds pulled the device's photos and videos into the
        // container's media store partway through a flash; feedback #27
        // removed the step, and anything still parked there is a leftover
        // copy with nothing pointing at it. Reclaim it at launch — only the
        // container's copies; the device's own library is never involved.
        let reclaimedMedia = DriftEngine.reclaimResidualMediaStore()
        if reclaimedMedia > 0 {
            AppLog.write("AFC media: 已清理旧版拉进容器的媒体副本，回收 "
                + ByteCountFormatter.string(fromByteCount: reclaimedMedia, countStyle: .file)
                + "（\(reclaimedMedia) 字节，仅 App 容器内的副本，设备相册原件未动）")
        }

        // AirLift's log sink, installed at launch for two reasons.  The library
        // is linked into the binary, and a launch is the only moment a static
        // archive's symbols are proven good: if the linker or the packager had
        // dropped a member that dyld needs, the app would die here rather than
        // on a Wallet page.  And the sink is a one-shot `al_log_init` — a second
        // call returns "already subscribed" and logs nothing — so it belongs
        // where it can only happen once.
        if Airlift.install() {
            AppLog.write("AirLift: log sink installed (AirTraffic escape available on iOS 27+)")
        } else {
            AppLog.write("AirLift: log sink already installed by the library")
        }
        // Referenced so the linker keeps `_ALGetGrappaToken`: the FFI looks it
        // up with `dlsym(RTLD_DEFAULT, …)` when it writes, and an unreferenced
        // symbol would be stripped and the write would fail on
        // `SyncFailed` with no token to blame.
        Airlift.installGrappaTokenProvider()

        // Drift uses the external tunnel only (LocalDevVPN or a similar app):
        // it starts no tunnel server of its own. Log the tunnel verdict at
        // launch — on device the console is not reachable, and the tunnel
        // state is the first thing a failed run needs to show in the app log.
        AppLog.write("Tunnel status: \(Tunnel.describe()) — external tunnel (LocalDevVPN) mode")
    }
    var body: some Scene {
        WindowGroup {
            DriftRootView()
        }
    }
}