import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// The video-wallpaper page: one video (+ its freeze frame), the playback
/// options, and its own apply. Video can only travel the restore route, so
/// this page's run always restarts the device — the page says so up front.
struct DriftVideoView: View {
    @EnvironmentObject private var session: DriftSession
    @EnvironmentObject private var identityMonitor: DeviceIdentityMonitor
    @Binding var selection: PosterBoardSelection

    @State private var importingVideo = false
    @State private var importingFrame = false
    @State private var statusLine: String?
    @State private var videoPreview: UIImage?

    private var identity: DeviceIdentity { identityMonitor.current }
    private var canApply: Bool {
        session.paired && selection.video != nil && !session.running
            && (selection.loop || selection.thumbnail != nil)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DriftBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        introCard
                        filesCard
                        optionsCard
                        applyCard
                        // Collection #289 (Grace, 2026-11-13): no log
                        // card on the video page either — same ruling
                        // as the wallpaper page.
                    }
                    .padding(16)
                    .driftPageWidth()
                }
            }
            .navigationTitle("视频壁纸")
            .navigationBarTitleDisplayMode(.large)
            // UIKit pickers, not SwiftUI `fileImporter` — same reasoning as
            // the pairing import; see `DocumentPicker`.
            .sheet(isPresented: $importingVideo) {
                DocumentPicker(contentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]) { urls in
                    importingVideo = false
                    importPicked(urls, into: PosterBoard.videoDirectory) { selection.video = $0 }
                } onCancel: {
                    importingVideo = false
                }
            }
            .sheet(isPresented: $importingFrame) {
                DocumentPicker(contentTypes: [.image]) { urls in
                    importingFrame = false
                    importPicked(urls, into: PosterBoard.thumbnailDirectory) { selection.thumbnail = $0 }
                } onCancel: {
                    importingFrame = false
                }
            }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                DriftPill(text: "只能走恢复刷", tint: .orange)
                DriftPill(text: "刷完重启")
            }
            Text("视频壁纸要走恢复刷（刷完设备会重启）；循环模式会把视频逐帧存下，最多 400 帧；非循环是实况照片式（视频 + 一张定格帧）。"
                 + (DriftRestoreGate.isEnabled ? "" : "恢复刷已封存，所以视频壁纸现在刷不了。"))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("素材").font(.subheadline.weight(.semibold))
            HStack(spacing: 12) {
                Group {
                    if let videoPreview {
                        Image(uiImage: videoPreview).resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: [.indigo.opacity(0.35), .teal.opacity(0.3)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                    }
                }
                .frame(width: 54, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(selection.video?.lastPathComponent ?? "还没选视频")
                        .font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(selection.thumbnail.map { "定格帧：\($0.lastPathComponent)" }
                         ?? (selection.loop ? "定格帧：循环模式不需要" : "定格帧：未选（非循环模式必须）"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Button { importingVideo = true } label: { Label("选视频", systemImage: "film") }
                    .driftGlassButton()
                Button { importingFrame = true } label: { Label("选定格帧", systemImage: "photo") }
                    .driftGlassButton()
                if selection.video != nil {
                    Button(role: .destructive) {
                        PosterBoard.clearFiles(in: PosterBoard.videoDirectory)
                        PosterBoard.clearFiles(in: PosterBoard.thumbnailDirectory)
                        selection.video = nil
                        selection.thumbnail = nil
                        videoPreview = nil
                    } label: { Image(systemName: "trash") }
                    .driftGlassButton()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
        .task(id: selection.video) { await loadPreview() }
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("播放选项").font(.subheadline.weight(.semibold))
            Toggle("循环播放", isOn: $selection.loop)
            Toggle("倒放", isOn: $selection.reverse)
            Toggle("前景层", isOn: $selection.foreground)
            Picker("帧计算", selection: $selection.calculationMode) {
                ForEach(PosterBoardCalculationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            NativeNote("循环模式最多 400 帧、按原分辨率逐帧存，太长的视频会被拦下并说明。")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    private var applyCard: some View {
        VStack(spacing: 10) {
            NativePrimaryButton(title: session.running ? "刷入中…"
                                : DriftRestoreGate.isEnabled ? "刷入视频壁纸（将重启）" : "刷入视频壁纸",
                                systemImage: "restart",
                                running: session.running,
                                disabled: !canApply) {
                runVideo()
            }
            if session.running {
                Button("取消") { session.cancelRun() }.driftGlassButton()
            }
            if let statusLine {
                Text(statusLine).font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !DriftRestoreGate.isEnabled {
                NativeNote(DriftRestoreGate.notice)
            }
            if !session.paired {
                NativeNote("先在「壁纸」页或设置里导入配对文件。")
            } else if selection.video != nil && !selection.loop && selection.thumbnail == nil {
                NativeNote("非循环模式需要一张定格帧图片。")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    // MARK: - Actions

    private func runVideo() {
        // Feedback #30: video can only travel the restore route, so
        // while the gate is closed the tap only explains — nothing is
        // shaped into a run. (The session funnel refuses it too.)
        guard DriftRestoreGate.isEnabled else {
            session.noticeTitle = "恢复刷（已封存）"
            session.noticeText = DriftRestoreGate.notice
            return
        }
        var videoSelection = PosterBoardSelection()
        videoSelection.video = selection.video
        videoSelection.thumbnail = selection.thumbnail
        videoSelection.loop = selection.loop
        videoSelection.reverse = selection.reverse
        videoSelection.foreground = selection.foreground
        videoSelection.calculationMode = selection.calculationMode
        Task {
            let outcome = await session.run(selection: videoSelection, mode: .backup,
                                            pick: .auto, identity: identity)
            if outcome.ok {
                statusLine = outcome.message
            } else {
                statusLine = nil
                session.errorText = outcome.message
            }
        }
    }

    private func importPicked(_ urls: [URL], into directory: URL,
                              assign: (URL?) -> Void) {
        guard let source = urls.first else { return }
        do {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            PosterBoard.clearFiles(in: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: destination)
            assign(destination)
        } catch {
            session.errorText = "拷贝素材失败：\(error.localizedDescription)"
        }
    }

    private func loadPreview() async {
        guard let video = selection.video else { videoPreview = nil; return }
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 640)
        if let cg = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image {
            videoPreview = UIImage(cgImage: cg)
        }
    }
}
