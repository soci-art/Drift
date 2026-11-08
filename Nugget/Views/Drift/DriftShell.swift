import SwiftUI

/// The four-tab shell. The wallpaper selection is hoisted here (the base
/// app's `RootView` did the same) so the wallpaper page and the video page
/// edit one selection and one run applies either.
struct DriftShell: View {
    @EnvironmentObject private var session: DriftSession
    @Environment(\.scenePhase) private var scenePhase
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
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app: re-read the device rather than trusting
            // the snapshot (it may have rebooted or been swapped).
            if phase == .active {
                Task { await session.refreshIdentity() }
            }
        }
    }
}
