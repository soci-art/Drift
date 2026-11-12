import SwiftUI

@main
struct DriftApp: App {
    init() {
        // Deliberately almost empty (collection #227): everything
        // that used to run here — the media-store sweep, the native
        // log-sink installs, the tunnel verdict — ran on the main
        // thread before the first frame, inside the launch watchdog's
        // window, and a user on iOS 18 reported the app opening to a
        // black screen and dying. That work now runs after the first
        // frame, in `DriftLaunchTasks`. What stays is a UserDefaults
        // cleanup with no measurable cost:
        //
        // The tunnel address is not user-editable in Drift: detection
        // always uses the LocalDevVPN defaults, so clear any override
        // an earlier build's editor may have stored.
        Tunnel.resetToDefaults()
    }
    var body: some Scene {
        WindowGroup {
            DriftRootView()
        }
    }
}
