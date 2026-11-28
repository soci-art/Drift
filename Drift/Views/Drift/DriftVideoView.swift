import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import Photos
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
    @State private var adjustingFrame = false
    @State private var previewingLock = false
    @State private var statusLine: String?
    @State private var videoPreview: UIImage?
    /// The note under the decode button, derived rather than
    /// stored: it shows exactly while the library really holds an
    /// item decoded from the currently picked video, so deleting
    /// the item (or clearing the video) takes the claim with it.
    private var decodeNote: String? {
        guard selection.video != nil, let name = selection.videoDisplayName
        else { return nil }
        return library.items.contains { $0.name == name }
            ? "解码完成，已存到「已解码的视频」，刷的时候选它就行。"
            : nil
    }
    @State private var showPicker = false
    /// The two "turn a system effect on" confirmations (Grace,
    /// 2026-11-28): flipping 景深 / 动态 on presents its sheet
    /// first; the switch only lands on 打开.
    @State private var confirmingDepthEffect = false
    @State private var confirmingMotionEffect = false
    @ObservedObject private var library = DecodedVideoLibrary.shared

    private var identity: DeviceIdentity { identityMonitor.current }
    private var manualPick: DriftMethodPick { DriftMethodPick.fromStored(manualPickRaw) }
    /// The decode takes the pick exactly as it stands: a video, and
    /// — in the non-loop shape — its freeze frame.
    private var canDecode: Bool {
        selection.video != nil && !session.running && !library.isDecoding
            && (selection.loop || selection.thumbnail != nil)
    }

    /// Turning a system effect ON goes through its explanation
    /// sheet first (Grace, 2026-11-28): the binding refuses the
    /// flip and presents the sheet; the switch lands only when
    /// the sheet's 打开 runs. Turning off is immediate.
    private var depthEffectBinding: Binding<Bool> {
        Binding(get: { selection.depthEffect },
                set: { newValue in
                    if newValue { confirmingDepthEffect = true }
                    else { selection.depthEffect = false }
                })
    }

    private var motionEffectBinding: Binding<Bool> {
        Binding(get: { selection.motionEffect },
                set: { newValue in
                    if newValue { confirmingMotionEffect = true }
                    else { selection.motionEffect = false }
                })
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
                        framingCard
                        optionsCard
                        decodeCard
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
                        selection.framing = nil
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
            .fullScreenCover(isPresented: $previewingLock) {
                if let video = selection.video {
                    VideoLockPreviewView(videoURL: video, framing: selection.framing)
                }
            }
            .fullScreenCover(isPresented: $adjustingFrame) {
                if let video = selection.video {
                    VideoFramingView(videoURL: video, initial: selection.framing) { framing in
                        selection.framing = framing
                        // Diagnosis (2026-11-26): the value the page is
                        // now holding, so the decode-start line can be
                        // checked against what the framing page handed
                        // back.
                        AppLog.info("视频页已记下画面调整：缩放 ×"
                            + "\(String(format: "%.3f", framing.scale))、偏移 ("
                            + "\(String(format: "%.1f", framing.offsetX)), "
                            + "\(String(format: "%.1f", framing.offsetY)))")
                    }
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
            Text("选好视频先解码存起来，刷的时候选已解码的，不用每次现等解码。循环模式最多 400 帧；非循环是实况照片式（视频 + 一张定格帧）。")
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
        case .backup: return "重启后生效"
        }
    }

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("素材").font(.subheadline.weight(.semibold))
                Spacer()
                if selection.video != nil {
                    Button(role: .destructive) {
                        PosterBoard.clearFiles(in: PosterBoard.videoDirectory)
                        PosterBoard.clearFiles(in: PosterBoard.thumbnailDirectory)
                        selection.video = nil
                        selection.thumbnail = nil
                        selection.framing = nil
                        videoPreview = nil
                    } label: { Image(systemName: "trash") }
                    .driftGlassButton()
                }
            }
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
                        .truncationMode(.middle)
                    Text(selection.thumbnail != nil ? "定格帧：已从视频选取"
                         : (selection.loop ? "定格帧：循环模式不需要" : "定格帧：未选（非循环模式必须）"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Button { importingVideo = true } label: {
                    Label("从文件选取", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .driftGlassButton()
                Button { importingPhotos = true } label: {
                    Label("从照片选取", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .driftGlassButton()
            }
            // Grace (2026-11-23): the frame pick aligns with the
            // rows around it — a full-width pill like the decode
            // button's row, not a hugging pill whose label starts
            // one padding further in than everything else.
            VStack(alignment: .leading, spacing: 6) {
                Button { pickingFrame = true } label: {
                    Label("选定格帧", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
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


    /// The decode step as its own card, below the framing card
    /// (Grace, 2026-11-23): the flow down the page is the order
    /// the work happens — pick, frame, then decode, and the
    /// decode carries the framing settled above it.
    private var decodeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("解码").font(.subheadline.weight(.semibold))
            // The decode section (Grace, 2026-11-22): decoding moves
            // off the flash run entirely — a heavy video's decode is
            // what used to kill a run minutes in. The product is
            // kept in the library below and flashed from the picker.
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    startDecode()
                } label: {
                    Group {
                        if library.isDecoding {
                            Label("解码中…", systemImage: "hourglass")
                        } else {
                            Label("开始解码", systemImage: "play.circle")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .driftGlassProminentButton()
                .disabled(!canDecode)
                Text("按上面的播放选项解码，改了选项要重新解码。")
                    .font(.caption).foregroundStyle(.secondary)
                if let decodeNote {
                    Text(decodeNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            NavigationLink {
                DecodedVideoListView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "film.stack")
                    Text("已解码的视频").font(.subheadline.weight(.medium))
                    Spacer()
                    Text(library.items.isEmpty
                         ? "还没有"
                         : "\(library.items.count) 个 · \(ByteCountFormatter.string(fromByteCount: library.totalBytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    /// Decode the current pick into the library. Errors land in the
    /// shared error slot, like a failed flash's do.
    private func startDecode() {
        Task {
            do {
                try await library.decode(selection: selection, preview: videoPreview)
            } catch {
                session.errorText = error.localizedDescription
            }
        }
    }

    /// The framing step (Grace, 2026-11-23): after the pick,
    /// before the decode — the decode is where the box's geometry
    /// is written into the product, so the adjustment has to be
    /// settled by then. The box only bites on the looping shape;
    /// the live-photo shape is laid out by the system.
    private var framingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("调整画面").font(.subheadline.weight(.semibold))
            Text(selection.framing?.isDefault == false
                 ? "已调整：按你定的样子生成、刷入"
                 : "还没调整：现在是居中裁剪")
                .font(.caption).foregroundStyle(.secondary)
            Text("按本机屏幕出框，框里就是刷上锁屏的样子：拖动移位置、双指缩放定裁剪，框外压暗的部分会被裁掉。循环模式用得上这个框；非循环（实况照片式）的画面由系统自己铺满。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { adjustingFrame = true } label: {
                    Label("调整", systemImage: "crop")
                        .frame(maxWidth: .infinity)
                }
                .driftGlassButton()
                .disabled(selection.video == nil)
                Button { previewingLock = true } label: {
                    Label("预览锁屏效果", systemImage: "lock.display")
                        .frame(maxWidth: .infinity)
                }
                .driftGlassButton()
                .disabled(selection.video == nil)
            }
            Text("预览只看锁屏：按本机屏幕大小，带着你定的框。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
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
                Toggle("景深效果", isOn: depthEffectBinding)
                Text("关着：画面照原样贴在锁屏上，和预览一致。开着：锁屏的时间能被画面里的主体挡住一部分，系统也会自己挪动、缩放画面，锁屏的样子可能和预览不完全一样。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .driftActionSheet(isPresented: $confirmingDepthEffect,
                              title: "打开景深效果",
                              message: "打开后，锁屏的时间可能会被画面里的主体挡住一部分，系统也会自己挪动、缩放画面，锁屏的样子可能和预览不完全一样。",
                              actions: [DriftSheetAction("打开") { selection.depthEffect = true }])
            VStack(alignment: .leading, spacing: 3) {
                Toggle("动态效果", isOn: motionEffectBinding)
                Text("关着：画面不动，和预览一致。开着：晃动手机时画面会跟着轻轻移位；为了移位不露边，系统会先把画面放大一点，锁屏的样子可能和预览不完全一样。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .driftActionSheet(isPresented: $confirmingMotionEffect,
                              title: "打开动态效果",
                              message: "打开后，晃动手机时锁屏画面会跟着轻轻移位；为了移位时不露边，系统会先把画面放大一点，锁屏的样子可能和预览不完全一样。",
                              actions: [DriftSheetAction("打开") { selection.motionEffect = true }])
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
            // Decode-first (Grace, 2026-11-22): there is no direct
            // flash of the current pick any more — every video flash
            // chooses a decoded product, so the decode never rides
            // inside a run.
            NativePrimaryButton(title: session.running ? "刷入中…" : "选择已解码的视频并刷入",
                                systemImage: "film",
                                running: session.running,
                                disabled: session.running) {
                showPicker = true
            }
            .navigationDestination(isPresented: $showPicker) {
                DecodedVideoPickerView()
            }
            if session.running {
                Button("取消") { session.cancelRun() }.driftGlassButton()
            }
            if let statusLine {
                Text(statusLine).font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            NativeNote("先在上面把视频解码存好，这里选已解码的刷入，刷的时候不再现解码。")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    // MARK: - Actions

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

    /// A video picked from Photos. Prefer the original asset resource:
    /// `loadFileRepresentation` with the generic movie type can hand
    /// back a system-transcoded 1080p copy (the 4K-in, 1080p-out case), so
    /// the primary route asks Photos for the original file. If the asset
    /// identifier or the read authorization is unavailable, fall back to
    /// the item provider with `.current` and the video's own type.
    @MainActor
    private func importFromPhotos(_ result: PHPickerResult) {
        importingPhotos = false
        if let identifier = result.assetIdentifier {
            Task { await importOriginalVideo(assetIdentifier: identifier, fallback: result) }
        } else {
            loadPhotoVideo(result)
        }
    }

    /// The original-resource route. `PHAssetResourceManager` writes the asset's
    /// own video file (not a compatible transcode) to a temporary path.
    @MainActor
    private func importOriginalVideo(assetIdentifier: String, fallback: PHPickerResult) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        var authorized = status == .authorized || status == .limited
        if status == .notDetermined {
            let granted = await withCheckedContinuation { (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) {
                    continuation.resume(returning: $0)
                }
            }
            authorized = granted == .authorized || granted == .limited
        }
        guard authorized else {
            DriftEngine.shared.log("Photos: 相册读取权限不可用，回退到系统提供的版本（可能被转码）")
            loadPhotoVideo(fallback)
            return
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
        guard let asset = assets.firstObject else {
            DriftEngine.shared.log("Photos: 找不到相册资源 \(assetIdentifier)，回退到系统提供的版本")
            loadPhotoVideo(fallback)
            return
        }
        let resources = PHAssetResource.assetResources(for: asset)
        // `.video` is the asset's current video resource. `.fullSizeVideo`
        // is the pre-adjustment original, which for an edited/cropped asset
        // is longer and can hit the 400-frame cap; use it only as a fallback.
        guard let resource = resources.first(where: { $0.type == .video })
                ?? resources.first(where: { $0.type == .fullSizeVideo }) else {
            DriftEngine.shared.log("Photos: 相册资源没有视频原片，回退到系统提供的版本")
            loadPhotoVideo(fallback)
            return
        }
        let filename = resource.originalFilename
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(base.isEmpty ? "photo-video" : base).\(ext.isEmpty ? "mov" : ext)")
        try? FileManager.default.removeItem(at: staging)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(
                    for: resource, toFile: staging, options: options) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            DriftEngine.shared.log("Photos: 读取原片失败（\(error.localizedDescription)），回退到系统提供的版本")
            loadPhotoVideo(fallback)
            return
        }
        DriftEngine.shared.log("Photos: 使用原片 \(filename)（\(resource.type.rawValue)）")
        importPicked([staging], into: PosterBoard.videoDirectory) { url in
            selection.video = url
            selection.thumbnail = nil
            selection.framing = nil
        }
    }

    /// Fallback: the item provider's current representation. Ask for a
    /// concrete movie type rather than `public.movie`, which is the generic
    /// request that lets the system pick a compatible (transcoded) copy.
    @MainActor
    private func loadPhotoVideo(_ result: PHPickerResult) {
        let provider = result.itemProvider
        let typeIdentifier = provider.registeredTypeIdentifiers.first {
            guard let type = UTType($0) else { return false }
            return type.conforms(to: .movie)
        } ?? UTType.movie.identifier
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
                    selection.framing = nil
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
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .videos
        configuration.selectionLimit = 1
        // Current, not compatible: a 4K source must not arrive as the
        // system's 1080p compatibility transcode. The original-asset
        // route above is the primary; this keeps the fallback honest too.
        configuration.preferredAssetRepresentationMode = .current
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
    /// renders the scrub itself — but the third attempt, one seek
    /// per slider tick, froze on device too (recording-verified:
    /// the preview tracked to 2.6 s, then froze while the slider
    /// swept 3.6→9.1 s, then snapped twice at the end): AVFoundation
    /// does NOT coalesce a 60 Hz seek flood; each new seek kills
    /// the previous one without freeing its decode work at once,
    /// so no frame ever lands. Round four (Grace + GPT cross-check,
    /// 2026-11-20) therefore schedules seeks like an editor:
    /// at most one seek in flight, the slider only ever records
    /// the LATEST target, a landed seek chains to that target,
    /// launches are rate-capped at ~12/s, and letting go runs one
    /// separate zero-tolerance seek once the in-flight one lands.
    /// Only the confirm step extracts a still — once, at full
    /// resolution, exact frame, independent of the preview.
    @State private var player = AVPlayer()
    /// Seek-scheduler state for the preview. `lastLanded` is the
    /// last target whose seek completed with finished == true —
    /// never read back from player.currentTime(), which during a
    /// seek does not say what is actually on screen.
    @State private var seekInFlight = false
    @State private var lastLanded: Double = -1
    @State private var lastSeekStart = Date.distantPast
    @State private var finishing = false
    @State private var generation = 0
    @State private var delayedPump: Task<Void, Never>?

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
                    if !isEditing { finishing = true }
                    pump()
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
            .onChange(of: time) { _, _ in pump() }
            .onDisappear {
                generation += 1
                delayedPump?.cancel()
                player.pause()
            }
        }
    }

    private func load() async {
        let asset = AVURLAsset(url: videoURL)
        let loaded = (try? await asset.load(.duration).seconds) ?? 0
        duration = loaded > 0 ? loaded : 0
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        player.pause()
        time = min(0.1, duration)
        finishing = true
        pump()
    }

    /// The seek scheduler. Invariants: at most one seek in flight;
    /// the target is always the slider's current value (latest
    /// wins, no queue); while dragging, launches are capped at
    /// ~12/s and land loose (0.35 s tolerance); when the drag ends,
    /// `finishing` makes the next launch a zero-tolerance seek to
    /// the final value, fired only after the in-flight one lands.
    private func pump() {
        guard !seekInFlight else { return }
        if finishing {
            fireSeek(target: time, exact: true)
            return
        }
        guard editing else { return }
        if abs(time - lastLanded) < 0.01 { return }
        let elapsed = Date().timeIntervalSince(lastSeekStart)
        if elapsed < 0.08 {
            delayedPump?.cancel()
            delayedPump = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64((0.08 - elapsed) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                pump()
            }
            return
        }
        fireSeek(target: time, exact: false)
    }

    private func fireSeek(target: Double, exact: Bool) {
        seekInFlight = true
        lastSeekStart = Date()
        let gen = generation
        let slack = CMTime(seconds: 0.35, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: exact ? .zero : slack,
                    toleranceAfter: exact ? .zero : slack) { finished in
            Task { @MainActor in
                // Stale completion from a previous page/video: the
                // state it would touch no longer exists.
                guard gen == generation else { return }
                seekInFlight = false
                if finished {
                    lastLanded = target
                    if exact { finishing = false }
                }
                pump()
            }
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
