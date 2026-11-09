import SwiftUI

/// The four-tab shell. The wallpaper selection is hoisted here (the base
/// app's `RootView` did the same) so the wallpaper page and the video page
/// edit one selection and one run applies either.
///
/// Live detection (the tunnel, identity and pairing-record monitors) is
/// wired one level up, in `DriftRootView`, so it also runs while the
/// first-run guide — not this shell — is on screen.
struct DriftShell: View {
    @State private var selection = PosterBoardSelection()
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            DriftHomeView(selection: $selection)
                .tabItem { Label("壁纸", systemImage: "photo.on.rectangle.angled") }
                .tag(0)
            DriftVideoView(selection: $selection)
                .tabItem { Label("视频", systemImage: "film") }
                .tag(1)
            DriftAboutView()
                .tabItem { Label("说明", systemImage: "info.circle") }
                .tag(2)
            DriftSettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
        .task {
            var restored = PosterBoardSelection()
            restored.loadFromDisk()
            selection.video = restored.video
            selection.thumbnail = restored.thumbnail
        }
    }
}
