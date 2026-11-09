import SwiftUI

@main
struct DriftApp: App {
    init() {
        // Development mode's logging switch, applied at launch rather than when the
        // settings page is opened: it governs the protocol half of every run, and a
        // stored preference that only took effect once the user visited a page would
        // mean a session's minimuxer.log was recorded under the wrong setting.
        DevSettings.applyLoggingPreference()

        // Drift never writes the skip-setup files. Upstream defaults that
        // preference ON, and every backup-mode apply would otherwise add two
        // setup files the user never asked for — so where no value has ever
        // been stored, store OFF. A value set by hand is left alone.
        if UserDefaults.standard.object(forKey: "SkipSetupEnabled") == nil {
            UserDefaults.standard.set(false, forKey: "SkipSetupEnabled")
        }
        // The tunnel address is not user-editable in Drift: detection always
        // uses the LocalDevVPN defaults, so clear any override an earlier
        // build's editor may have stored.
        Tunnel.resetToDefaults()

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