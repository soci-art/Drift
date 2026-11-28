import AVFoundation
import SwiftUI
import UIKit

/// The framing box for a video wallpaper (Grace, 2026-11-23).
///
/// Why this exists: the decode used to lay every video out centred
/// and cover-scaled, with the document taken from whatever screen
/// numbers the moment offered — a wide video on a tall (or tablet)
/// screen kept a strip the user never chose. Here the user chooses:
/// a box in the device screen's own shape stands over the playing
/// video, the video drags and pinches behind it, what is inside
/// the box is what the Lock Screen will show, and the decode writes
/// exactly that — same ruler for the box and for the geometry
/// (`PosterBoardVideo.deviceScreenPoints`), so the two cannot
/// drift apart.
///
/// The working values are kept in document points (the screen's
/// points), not view points, so a layout change mid-gesture cannot
/// rescale an adjustment already made.
struct VideoFramingView: View {
    let videoURL: URL
    let initial: PosterBoardFraming?
    let onDone: (PosterBoardFraming) -> Void

    @Environment(\.dismiss) private var dismiss

    /// The screen the box is shaped by — the same numbers the
    /// descriptor skeleton and caml write. Carried into the framing
    /// so a decode after a rotation still uses this ruler.
    private let metrics: PosterBoardScreenMetrics = PosterBoardVideo.deviceScreenMetrics()
    private var docW: Int { metrics.width }
    private var docH: Int { metrics.height }
    private var screenScale: Double { Double(metrics.scale) }

    /// The video's display size (after its rotation transform),
    /// loaded on appear; the box is inert until it lands.
    @State private var displaySize: CGSize = .zero
    /// Committed adjustment, in document points.
    @State private var scale: Double
    @State private var offsetDoc: CGSize
    /// In-flight gesture values, folded in on gesture end.
    @State private var pinch: Double = 1
    @State private var dragDoc: CGSize = .zero
    /// Set the moment the page is leaving: the live player comes
    /// out first, then the cover dismisses — a heavy player layer
    /// riding the dismissal animation smears across the page
    /// underneath (Grace's recording, 2026-11-23).
    @State private var leaving = false

    private func leave() {
        leaving = true
        DispatchQueue.main.async { dismiss() }
    }

    init(videoURL: URL,
         initial: PosterBoardFraming?,
         onDone: @escaping (PosterBoardFraming) -> Void) {
        self.videoURL = videoURL
        self.initial = initial
        self.onDone = onDone
        _scale = State(initialValue: initial?.scale ?? 1)
        _offsetDoc = State(initialValue: CGSize(width: initial?.offsetX ?? 0,
                                                height: initial?.offsetY ?? 0))
    }

    private var coverDoc: Double {
        guard displaySize.width > 0, displaySize.height > 0 else { return 1 }
        return max(Double(docW) / displaySize.width, Double(docH) / displaySize.height)
    }

    private var effScale: Double { min(max(scale * pinch, 1), 3) }

    private var effOffset: CGSize {
        clamped(offsetDoc + dragDoc, scale: effScale)
    }

    private func clamped(_ off: CGSize, scale s: Double) -> CGSize {
        let dw = displaySize.width * coverDoc * s
        let dh = displaySize.height * coverDoc * s
        let mx = max(0, (dw - Double(docW)) / 2)
        let my = max(0, (dh - Double(docH)) / 2)
        return CGSize(width: min(max(off.width, -mx), mx),
                      height: min(max(off.height, -my), my))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                let frame = frameRect(in: geo.size)
                let k = frame.width / Double(docW)   // view points per document point
                ZStack {
                    if displaySize != .zero {
                        if !leaving {
                            FramingPlayerView(url: videoURL,
                                              videoRect: videoRect(frame: frame))
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                        // Everything outside the box is what gets
                        // cut: dim it, so the cut is visible.
                        Path { path in
                            path.addRect(CGRect(origin: .zero, size: geo.size))
                            path.addRoundedRect(in: frame,
                                                cornerSize: CGSize(width: 18, height: 18))
                        }
                        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(Color.white, lineWidth: 2.5)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                        let points = corners(of: frame)
                        ForEach(0..<points.count, id: \.self) { i in
                            Circle().fill(Color.white).frame(width: 13, height: 13)
                                .position(points[i])
                        }
                    } else {
                        ProgressView().tint(.white)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard displaySize != .zero else { return }
                            dragDoc = CGSize(width: value.translation.width / k,
                                             height: value.translation.height / k)
                        }
                        .onEnded { _ in
                            offsetDoc = effOffset
                            dragDoc = .zero
                            // Diagnosis (2026-11-26): what each gesture
                            // actually committed, so a swallowed drag or
                            // pinch is visible in the log instead of
                            // looking like the user never adjusted.
                            AppLog.info("调整落定（拖动）：偏移 ("
                                + "\(String(format: "%.1f", offsetDoc.width)), "
                                + "\(String(format: "%.1f", offsetDoc.height)))")
                        })
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            guard displaySize != .zero else { return }
                            pinch = value.magnification
                        }
                        .onEnded { _ in
                            scale = effScale
                            offsetDoc = clamped(offsetDoc, scale: scale)
                            pinch = 1
                            AppLog.info("调整落定（缩放）：缩放 ×"
                                + "\(String(format: "%.3f", scale))、偏移 ("
                                + "\(String(format: "%.1f", offsetDoc.width)), "
                                + "\(String(format: "%.1f", offsetDoc.height)))")
                        })
            }
            VStack {
                HStack {
                    Button("取消") {
                        AppLog.op("调整画面取消，本次改动不保存")
                        leave()
                    }
                        .foregroundStyle(.white)
                    Spacer()
                    Text("调整画面").font(.headline).foregroundStyle(.white)
                    Spacer()
                    // Balances the leading button so the title centres.
                    Text("取消").opacity(0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                Spacer()
                Text("拖动移位置 · 双指缩放")
                    .font(.subheadline)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                Text("框外压暗的部分会被裁掉 · 按本机屏幕 \(pixelText) 出框")
                    .font(.caption).foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 8)
                HStack(spacing: 12) {
                    Button("还原居中") {
                        AppLog.op("调整画面还原居中")
                        withAnimation(.easeInOut(duration: 0.25)) {
                            scale = 1
                            offsetDoc = .zero
                            pinch = 1
                            dragDoc = .zero
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
                    Spacer()
                    Button("完成") {
                        // Diagnosis (2026-11-26): log the handed-back
                        // values AND the live gesture values side by
                        // side. 完成 passes the committed ones; if a
                        // drag or pinch never folded in, the two
                        // disagree here and the loss point is named
                        // instead of guessed.
                        AppLog.op("调整画面点完成：交回 "
                            + Self.describe(PosterBoardFraming(
                                scale: scale,
                                offsetX: offsetDoc.width,
                                offsetY: offsetDoc.height))
                            + "；当时手势实时值 缩放 ×"
                            + "\(String(format: "%.3f", effScale))、偏移 ("
                            + "\(String(format: "%.1f", effOffset.width)), "
                            + "\(String(format: "%.1f", effOffset.height)))")
                        onDone(PosterBoardFraming(scale: scale,
                                                  offsetX: offsetDoc.width,
                                                  offsetY: offsetDoc.height,
                                                  document: metrics))
                        leave()
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 30).padding(.vertical, 11)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 10)
            }
        }
        .task { await loadDisplaySize() }
        .onAppear {
            // Diagnosis (2026-11-26): the framing page used to leave
            // no trace in the log at all, so an "adjustments don't
            // take effect" report could not be reconstructed after
            // the fact. Record what the page opened with; the
            // gesture and 完成 lines below complete the sequence.
            AppLog.op("打开调整画面：\(videoURL.lastPathComponent)"
                + "（进来时：\(Self.describe(initial))）")
        }
    }

    /// One-line rendering of a framing for the log lines above.
    private static func describe(_ framing: PosterBoardFraming?) -> String {
        guard let framing else { return "无调整" }
        if framing.isDefault { return "默认（缩放 ×1.000、偏移 (0.0, 0.0)）" }
        return "缩放 ×\(String(format: "%.3f", framing.scale))、偏移 ("
            + "\(String(format: "%.1f", framing.offsetX)), "
            + "\(String(format: "%.1f", framing.offsetY)))"
    }

    private var pixelText: String {
        "\(Int((Double(docW) * screenScale).rounded()))×\(Int((Double(docH) * screenScale).rounded()))"
    }

    private func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }

    /// The box: the screen's aspect, as large as the stage allows
    /// with room kept for the bars above and below.
    private func frameRect(in size: CGSize) -> CGRect {
        let aspect = Double(docW) / Double(docH)
        let availW = size.width - 40
        let availH = size.height - 215
        var w = availW
        var h = w / CGFloat(aspect)
        if h > availH { h = availH; w = h * CGFloat(aspect) }
        return CGRect(x: (size.width - w) / 2, y: 84 + (availH - h) / 2,
                      width: w, height: h)
    }

    /// Where the video layer sits: cover-scaled, zoomed by the
    /// user's scale, centred on the box plus their offset.
    private func videoRect(frame: CGRect) -> CGRect {
        let k = frame.width / Double(docW)
        let cover = max(frame.width / displaySize.width, frame.height / displaySize.height)
        let w = displaySize.width * cover * effScale
        let h = displaySize.height * cover * effScale
        let cx = frame.midX + effOffset.width * k
        let cy = frame.midY + effOffset.height * k
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    private func loadDisplaySize() async {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize) else { return }
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let size = CGSize(width: abs(rect.width), height: abs(rect.height))
        guard size.width > 0, size.height > 0 else { return }
        displaySize = size
        // A saved framing was clamped against nothing before the
        // size landed; hold it inside the cover now.
        offsetDoc = clamped(offsetDoc, scale: scale)
    }
}

/// The video itself, on a layer whose frame SwiftUI sets: the
/// layer is given the exact rectangle the box math produced
/// (`.resize` does no second fitting of its own), so what plays
/// here is pixel-for-pixel what the geometry says.
private struct FramingPlayerView: UIViewRepresentable {
    let url: URL
    let videoRect: CGRect

    func makeUIView(context: Context) -> PlayerHostView {
        PlayerHostView(url: url)
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        uiView.setVideoRect(videoRect)
    }

    static func dismantleUIView(_ uiView: PlayerHostView, coordinator: ()) {
        uiView.stop()
    }
}

private final class PlayerHostView: UIView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let videoLayer = AVPlayerLayer()

    init(url: URL) {
        super.init(frame: .zero)
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.isMuted = true
        videoLayer.player = player
        videoLayer.videoGravity = .resize
        layer.addSublayer(videoLayer)
        isUserInteractionEnabled = false
        player.play()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setVideoRect(_ rect: CGRect) {
        // No animation: the layer tracks the finger.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = rect
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { player.play() } else { player.pause() }
    }

    func stop() { player.pause() }
}

private func + (lhs: CGSize, rhs: CGSize) -> CGSize {
    CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
}
