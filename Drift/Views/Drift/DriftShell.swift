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
        VStack(spacing: 0) {
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
            // #242: on the pre-glass systems the tab bar is pinned opaque
            // (their own classic look, stated rather than inherited); on
            // iOS 26+ the system's glass bar stands as designed.
            .modifier(LegacyTabBarBackground())
        }
        .task {
            var restored = PosterBoardSelection()
            restored.loadFromDisk()
            selection.video = restored.video
            selection.thumbnail = restored.thumbnail
        }
    }
}

/// The legacy tab bar treatment (#242): an opaque system-background bar
/// below iOS 26, untouched above it. (`toolbarBackground` is iOS 16+,
/// so the legacy branch is available on every system it serves.)
private struct LegacyTabBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if DriftTheme.legacyUI {
            content
                .toolbarBackground(.visible, for: .tabBar)
                .toolbarBackground(Color(.systemBackground), for: .tabBar)
        } else {
            content
        }
    }
}
