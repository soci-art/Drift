import SwiftUI

/// The 壁纸 tab (redesign, Grace, 2026-11-26): everything about the
/// wallpapers themselves lives here — making a video wallpaper, the
/// imported packs, and the on-device store manager. The flash page
/// keeps only picking and flashing.
///
/// The video studio keeps its own navigation stack, so it is
/// presented full-screen rather than pushed; the pack list and the
/// manager are plain pushed pages, like they were from Home.
struct WallpapersTabView: View {
    @Binding var selection: PosterBoardSelection
    @State private var imports: [PosterBoardTendie] = PosterBoardImports.load()
    @State private var showVideo = false

    var body: some View {
        NavigationStack {
            ZStack {
                DriftBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        videoEntryCard
                        packsEntryCard
                        managerEntryCard
                    }
                    .padding(16)
                    .driftPageWidth()
                }
            }
            .navigationTitle("壁纸")
            .navigationBarTitleDisplayMode(.large)
            .fullScreenCover(isPresented: $showVideo) {
                DriftVideoView(selection: $selection)
            }
            .onAppear {
                AppLog.op("打开壁纸页")
                imports = PosterBoardImports.load()
            }
        }
    }

    private var videoEntryCard: some View {
        Button {
            showVideo = true
        } label: {
            entryRow(icon: "film", tint: .purple,
                     title: "做视频壁纸",
                     note: "选视频、调整画面、解码成壁纸包")
        }
        .buttonStyle(.plain)
    }

    private var packsEntryCard: some View {
        NavigationLink {
            PackListView(imports: $imports, selection: $selection)
        } label: {
            entryRow(icon: "photo.on.rectangle.angled", tint: .blue,
                     title: "壁纸包",
                     note: imports.isEmpty
                         ? "还没有导入，点这里导入 .tendies 包"
                         : "已导入 \(imports.count) 个包")
        }
        .buttonStyle(.plain)
    }

    private var managerEntryCard: some View {
        NavigationLink {
            PosterBoardManagerView()
        } label: {
            entryRow(icon: "square.stack.3d.up", tint: .gray,
                     title: "本机壁纸管理",
                     note: "看已经刷进去的壁纸，也在这里删")
        }
        .buttonStyle(.plain)
    }

    /// One entry row in the settings-tile shape: a coloured rounded
    /// square, a title with one line of plain-words explanation, and
    /// a chevron.
    private func entryRow(icon: String, tint: Color, title: String,
                          note: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(note).font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }
}
