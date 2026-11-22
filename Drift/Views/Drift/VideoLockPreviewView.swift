import AVFoundation
import SwiftUI
import UIKit

/// The video wallpaper's lock-screen preview (Grace, 2026-11-23).
///
/// The one preview that stays: the swipe-to-home unlock preview is
/// gone by her ruling — this shows the LOCK SCREEN ONLY, the way
/// the interactive wallpapers are previewed, at the device's own
/// screen size. The video plays behind a lock-screen face (date,
/// clock, the two round buttons, the home bar) laid out with the
/// real screen's proportions, and it honours the framing the user
/// set in the box: the picture sits exactly where the decode will
/// write it, so what is previewed is what gets flashed.
struct VideoLockPreviewView: View {
    let videoURL: URL
    let framing: PosterBoardFraming?

    @Environment(\.dismiss) private var dismiss
    @State private var displaySize: CGSize = .zero
    @State private var now = Date()

    private let docW: Int = PosterBoardVideo.deviceScreenPoints().width
    private let docH: Int = PosterBoardVideo.deviceScreenPoints().height

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if displaySize != .zero {
                    LockPreviewPlayerView(url: videoURL,
                                          videoRect: videoRect(in: geo.size))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                lockFace(in: geo.size)
                // The exit has to be findable (the build-2 lesson):
                // a labelled capsule, top right, always on top.
                VStack {
                    HStack {
                        Spacer()
                        Button { dismiss() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "xmark")
                                Text("退出")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color.black.opacity(0.45), in: Capsule())
                        }
                    }
                    Spacer()
                }
                .padding(.top, 54)
                .padding(.trailing, 18)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .task { await loadDisplaySize() }
        .task {
            // Keep the clock honest while the preview stands.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                now = Date()
            }
        }
    }

    /// The video's rect on this screen: the cover fit, with the
    /// user's framing applied in the document's own points — the
    /// same numbers the decode writes.
    private func videoRect(in size: CGSize) -> CGRect {
        let cover = max(size.width / displaySize.width, size.height / displaySize.height)
        let scale = framing?.scale ?? 1
        let w = displaySize.width * cover * scale
        let h = displaySize.height * cover * scale
        let k = size.width / Double(docW)
        let cx = size.width / 2 + (framing?.offsetX ?? 0) * k
        let cy = size.height / 2 + (framing?.offsetY ?? 0) * k
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// The lock-screen furniture, at the real screen's proportions
    /// (the same measures the retired unlock preview was rebuilt
    /// to): little lock, date over a big clock, the two round
    /// buttons in the bottom corners, the home bar.
    private func lockFace(in size: CGSize) -> some View {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        let hourText = template.contains("a") ? "\((hour + 11) % 12 + 1)" : "\(hour)"
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let dateText = "\(cal.component(.month, from: now))月\(cal.component(.day, from: now))日 "
            + weekdays[cal.component(.weekday, from: now) - 1]
        return ZStack {
            VStack(spacing: 0) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.bottom, 10)
                Text(dateText)
                    .font(.system(size: size.width * 0.049, weight: .medium))
                    .foregroundStyle(.white)
                Text("\(hourText):\(String(format: "%02d", minute))")
                    .font(.system(size: size.width * 0.235, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer()
            }
            .padding(.top, size.height * 0.105)
            VStack {
                Spacer()
                HStack {
                    roundButton("flashlight.off.fill")
                    Spacer()
                    roundButton("camera.fill")
                }
                .padding(.horizontal, size.width * 0.107)
                .padding(.bottom, 26)
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color.white)
                    .frame(width: 134, height: 5)
                    .padding(.bottom, 8)
            }
        }
    }

    private func roundButton(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20))
            .foregroundStyle(.white)
            .frame(width: 50, height: 50)
            .background(Color.black.opacity(0.35), in: Circle())
    }

    private func loadDisplaySize() async {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize) else { return }
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let size = CGSize(width: abs(rect.width), height: abs(rect.height))
        if size.width > 0, size.height > 0 { displaySize = size }
    }
}

/// The playing video on a layer whose frame is set from the
/// preview's own math (`.resize`: no second fitting), muted and
/// looping, like the framing page's player.
private struct LockPreviewPlayerView: UIViewRepresentable {
    let url: URL
    let videoRect: CGRect

    func makeUIView(context: Context) -> LockPlayerHostView {
        LockPlayerHostView(url: url)
    }

    func updateUIView(_ uiView: LockPlayerHostView, context: Context) {
        uiView.setVideoRect(videoRect)
    }

    static func dismantleUIView(_ uiView: LockPlayerHostView, coordinator: ()) {
        uiView.stop()
    }
}

private final class LockPlayerHostView: UIView {
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
