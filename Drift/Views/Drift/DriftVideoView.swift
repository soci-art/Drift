import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import PhotosUI

/// The video-wallpaper page: one video (+ its freeze frame, picked from
/// the video itself), the playback options with a plain explanation of
/// each, and its own apply. Which channel carries the video is the home
/// page's judgement — the pills at the top show the channel that can
/// actually run here and how it takes effect.
struct DriftVideoView: View {
    @EnvironmentObject private var session: DriftSession
    @EnvironmentObject private var identityMonitor: DeviceIdentityMonitor
    @ObservedObject private var tunnelMonitor = TunnelMonitor.shared
    @AppStorage(DriftJudge.manualKey) private var manualPickRaw: String?
    @Binding var selection: PosterBoardSelection

    @State private var importingVideo = false
    @State private var importingPhotos = false
    @State private var pickingFrame = false
    @State private var statusLine: String?
    @State private var videoPreview: UIImage?

    private var identity: DeviceIdentity { identityMonitor.current }
    private var manualPick: DriftMethodPick { DriftMethodPick.fromStored(manualPickRaw) }
    private var canApply: Bool {
        selection.video != nil && !session.running
            && (selection.loop || selection.thumbnail != nil)
    }

    /// The home judgement for a video-only selection: which channel
    /// would carry it right now.
    private var videoJudgement: DriftModeJudgement {
        var videoOnly = PosterBoardSelection()
        videoOnly.video = selection.video
        return DriftJudge.judge(identity: identity, selection: videoOnly,
                                pick: manualPick,
                                tunnelReady: tunnelMonitor.status == .ready)
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
                    importPicked(urls, into: PosterBoard.videoDirectory) { url in
                        selection.video = url
                        // A freeze frame belongs to its video: a new
                        // video invalidates the old pick.
                        selection.thumbnail = nil
                    }
                } onCancel: {
                    importingVideo = false
                }
            }
            .sheet(isPresented: $importingPhotos) {
                PhotoVideoPicker { result in
                    importFromPhotos(result)
                } onCancel: {
                    importingPhotos = false
                }
            }
            .sheet(isPresented: $pickingFrame) {
                if let video = selection.video {
                    VideoFramePickerView(videoURL: video) { image in
                        saveFreezeFrame(image)
                    }
                }
            }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            introPills
            Text("视频会在本机生成，再按上面显示的通道刷入。循环模式最多 400 帧；非循环是实况照片式（视频 + 一张定格帧）。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    /// Only the channel that can actually run is shown, with how it
    /// takes effect — never the whole list (Grace, 2026-11-19).
    private var introPills: some View {
        let judged = videoJudgement
        return HStack(spacing: 8) {
            if judged.useKernel {
                DriftPill(text: "内核直刷", tint: .green)
                DriftPill(text: "关闭 PosterBoard 后生效")
            } else if judged.isBlocked {
                DriftPill(text: "暂不可用", tint: .orange)
            } else {
                DriftPill(text: judged.mode.shortTitle, tint: .green)
                DriftPill(text: effectPillText(for: judged.mode))
            }
        }
    }

    private func effectPillText(for mode: PosterBoardApplyMode) -> String {
        switch mode {
        case .worseQuery: return "关闭 PosterBoard 后生效"
        case .direct: return "刷完即生效"
        case .airlift: return "注销后生效"
        case .backup: return "暂不可用"
        }
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
                    Text(selection.thumbnail != nil ? "定格帧：已从视频选取"
                         : (selection.loop ? "定格帧：循环模式不需要" : "定格帧：未选（非循环模式必须）"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Button { importingVideo = true } label: { Label("从文件选取", systemImage: "folder") }
                    .driftGlassButton()
                Button { importingPhotos = true } label: { Label("从照片选取", systemImage: "photo.on.rectangle") }
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
            HStack(spacing: 10) {
                Button { pickingFrame = true } label: { Label("选定格帧", systemImage: "photo") }
                    .driftGlassButton()
                    .disabled(selection.video == nil)
                Text("定格帧在视频里选，不用另外准备图片。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
        .task(id: selection.video) { await loadPreview() }
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("播放选项").font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 3) {
                Toggle("循环播放", isOn: $selection.loop)
                Text("开着：把视频逐帧存成会自己一直循环播放的壁纸，最多 400 帧。关掉：做成实况照片式壁纸，静止时显示定格帧、按住才动，要先选一张定格帧。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Toggle("倒放", isOn: $selection.reverse)
                Text("开着：帧的顺序倒过来播放，从最后一帧播回第一帧。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Toggle("前景层", isOn: $selection.foreground)
                Text("开着：视频盖到最前面，锁屏上的时钟会被视频挡住。关掉：时钟正常显示在视频上面。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Picker("帧计算", selection: $selection.calculationMode) {
                    ForEach(PosterBoardCalculationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text("线性：帧与帧之间平滑衔接，动作连贯。独立：每帧停住再跳到下一帧，是一格一格的效果。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            NativeNote("循环模式最多 400 帧、按原分辨率逐帧存，太长的视频会被拦下并说明。")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    private var applyCard: some View {
        VStack(spacing: 10) {
            NativePrimaryButton(title: session.running ? "刷入中…" : "按当前通道刷入视频壁纸",
                                systemImage: "film",
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
            if selection.video != nil && !selection.loop && selection.thumbnail == nil {
                NativeNote("非循环模式先选一张定格帧：在视频里挑一帧就行。")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    // MARK: - Actions

    private func runVideo() {
        var videoSelection = PosterBoardSelection()
        videoSelection.video = selection.video
        videoSelection.thumbnail = selection.thumbnail
        videoSelection.loop = selection.loop
        videoSelection.reverse = selection.reverse
        videoSelection.foreground = selection.foreground
        videoSelection.calculationMode = selection.calculationMode
        Task {
            var checked = DriftJudge.judge(
                identity: identity, selection: videoSelection, pick: manualPick,
                tunnelReady: tunnelMonitor.status == .ready)
            if checked.isBlocked || checked.mode != .worseQuery {
                if session.paired { await session.refreshIdentity() }
                checked = DriftJudge.judge(
                    identity: identity, selection: videoSelection, pick: manualPick,
                    tunnelReady: tunnelMonitor.status == .ready)
            }
            guard !checked.isBlocked else {
                session.errorText = checked.blockedReason
                return
            }
            if checked.useKernel {
                let outcome = await session.runKernelApply(identity: identity, selection: videoSelection)
                if outcome.ok { statusLine = outcome.message }
                else { statusLine = nil; session.errorText = outcome.message }
            } else {
                let outcome = await session.run(selection: videoSelection, mode: checked.mode,
                                                 pick: manualPick, identity: identity)
                if outcome.ok { statusLine = outcome.message }
                else { statusLine = nil; session.errorText = outcome.message }
            }
        }
    }

    private func importPicked(_ urls: [URL], into directory: URL,
                              assign: @escaping (URL?) -> Void) {
        guard let source = urls.first else { return }
        // #315: the copy used to run synchronously on the main
        // thread — a large picked video stalled the page until it
        // landed. The copy (and the security-scope dance around it)
        // runs detached now; only the assignment comes back to the
        // main actor.
        Task {
            let outcome: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    PosterBoard.clearFiles(in: directory)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let destination = directory.appendingPathComponent(source.lastPathComponent)
                    try FileManager.default.copyItem(at: source, to: destination)
                    return .success(destination)
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case .success(let destination):
                assign(destination)
            case .failure(let error):
                session.errorText = "拷贝素材失败：\(error.localizedDescription)"
            }
        }
    }

    /// A video picked from Photos: the system hands over a temporary
    /// file that disappears when the callback returns, so stage a copy
    /// first, then run it through the same import path as a file pick.
    private func importFromPhotos(_ result: PHPickerResult) {
        importingPhotos = false
        let provider = result.itemProvider
        let typeIdentifier = UTType.movie.identifier
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
            session.errorText = "这段视频读不出来，换一段试试。"
            return
        }
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
            guard let url else {
                Task { @MainActor in
                    session.errorText = "这段视频读不出来，换一段试试。"
                }
                return
            }
            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
            let base = provider.suggestedName ?? "照片视频"
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(base).\(ext)")
            try? FileManager.default.removeItem(at: staging)
            do {
                try FileManager.default.copyItem(at: url, to: staging)
            } catch {
                Task { @MainActor in
                    session.errorText = "拷贝素材失败：\(error.localizedDescription)"
                }
                return
            }
            Task { @MainActor in
                importPicked([staging], into: PosterBoard.videoDirectory) { url in
                    selection.video = url
                    selection.thumbnail = nil
                }
            }
        }
    }

    /// Save a frame picked from the video as the freeze frame.
    private func saveFreezeFrame(_ image: UIImage) {
        Task {
            let outcome: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    PosterBoard.clearFiles(in: PosterBoard.thumbnailDirectory)
                    try FileManager.default.createDirectory(at: PosterBoard.thumbnailDirectory,
                                                            withIntermediateDirectories: true)
                    guard let data = image.pngData() else {
                        throw NSError(domain: "DriftVideo", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "这一帧存不下来，换一帧试试。"])
                    }
                    let destination = PosterBoard.thumbnailDirectory
                        .appendingPathComponent("freeze-frame.png")
                    try data.write(to: destination)
                    return .success(destination)
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case .success(let destination):
                selection.thumbnail = destination
            case .failure(let error):
                session.errorText = "定格帧没存上：\(error.localizedDescription)"
            }
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

/// The system photo picker, limited to videos (Grace, 2026-11-19:
/// choosing a video must work from Photos as well as from Files).
private struct PhotoVideoPicker: UIViewControllerRepresentable {
    var onPick: (PHPickerResult) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .videos
        configuration.selectionLimit = 1
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoVideoPicker

        init(_ parent: PhotoVideoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            if let first = results.first {
                parent.onPick(first)
            } else {
                parent.onCancel()
            }
        }
    }
}

/// Pick the freeze frame from inside the video: scrub to the wanted
/// moment and confirm — no separate image file (Grace, 2026-11-19).
private struct VideoFramePickerView: View {
    let videoURL: URL
    var onConfirm: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var duration: Double = 0
    @State private var time: Double = 0
    @State private var confirming = false
    @State private var editing = false
    /// Live preview by player, not by extracted stills (Grace,
    /// 2026-11-20). Two still-based attempts failed on device: the
    /// per-tick decode trailed the finger (a finished frame was
    /// dropped whenever the slider had already moved on), and
    /// pre-rendering a whole filmstrip on open burned CPU alongside
    /// the drag decodes — lag and a hot phone. The paused player
    /// renders the scrub itself: the system video pipeline shows
    /// the frame at the slider position, and AVFoundation coalesces
    /// rapid seek requests on its own. Only the confirm step still
    /// extracts a still — once, at full resolution, exact frame.
    @State private var player = AVPlayer()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ZStack {
                    if duration > 0 {
                        PlayerLayerView(player: player)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxHeight: 420)
                Slider(value: $time, in: 0...max(duration, 0.1)) { isEditing in
                    editing = isEditing
                    if !isEditing { seek(exact: true) }
                }
                Text("第 \(String(format: "%.1f", time)) 秒 / 共 \(String(format: "%.1f", duration)) 秒")
                    .font(.caption).foregroundStyle(.secondary)
                Text("拖动滑杆挑一帧，停在想要的那一画面，再点「用这一帧」。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
            .navigationTitle("选定格帧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("用这一帧") { confirm() }
                        .disabled(duration <= 0 || confirming)
                }
            }
            .task { await load() }
            .onChange(of: time) { _, _ in
                if editing { seek(exact: false) }
            }
            .onDisappear { player.pause() }
        }
    }

    private func load() async {
        let asset = AVURLAsset(url: videoURL)
        let loaded = (try? await asset.load(.duration).seconds) ?? 0
        duration = loaded > 0 ? loaded : 0
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        player.pause()
        time = min(0.1, duration)
        seek(exact: true)
    }

    /// Point the paused player at the slider position. While the
    /// finger is moving the seek takes a loose tolerance, so the
    /// pipeline can land on a nearby frame fast; when the drag ends
    /// (and for the first frame) it seeks with zero tolerance, so
    /// what is on screen is exactly the frame confirm will extract.
    private func seek(exact: Bool) {
        let target = CMTime(seconds: time, preferredTimescale: 600)
        if exact {
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            let slack = CMTime(seconds: 0.35, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: slack, toleranceAfter: slack)
        }
    }

    private func confirm() {
        confirming = true
        Task {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            if let cg = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                onConfirm(UIImage(cgImage: cg))
                dismiss()
            }
            confirming = false
        }
    }
}

/// The paused player's picture: a plain AVPlayerLayer host with no
/// controls — the slider is the only control on this page.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        uiView.playerLayer.player = player
    }
}

private final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
