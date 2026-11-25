import SwiftUI

/// The four-tab shell (redesign, Grace, 2026-11-26): 刷入 / 壁纸 /
/// 教程 / 设置. The selection state is hoisted here so the flash page
/// and the wallpaper page edit one shared state and share one judge —
/// but each page's run clips the payload to its own content (#343,
/// Grace, 2026-11-21): a wallpaper-page run carries only the checked
/// packs, a video-page run only the video, and neither page's
/// leftovers ride into the other's run.
///
/// The 说明 page (the version table) lives inside 设置 now, next to
/// 关于此 App; the tutorial has its own tab instead of an entry card
/// on the flash page.
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
                    .tabItem { Label("刷入", systemImage: "arrow.down.circle") }
                    .tag(0)
                WallpapersTabView(selection: $selection)
                    .tabItem { Label("壁纸", systemImage: "photo.on.rectangle.angled") }
                    .tag(1)
                TutorialTabView()
                    .tabItem { Label("教程", systemImage: "book") }
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
            restored.restorePickedFiles()
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

/// The tutorial as its own tab: the states snapshot is built from the
/// same live monitors the flash page reads, so the two never disagree.
private struct TutorialTabView: View {
    @EnvironmentObject private var identityMonitor: DeviceIdentityMonitor
    @ObservedObject private var tunnelMonitor = TunnelMonitor.shared

    var body: some View {
        NavigationStack {
            DriftTutorialView(states: DriftTutorialStates.current(
                identity: identityMonitor.current,
                tunnelReady: tunnelMonitor.status == .ready))
        }
    }
}
