import AVFoundation
import SwiftUI
import UIKit

/// The unlock preview (Grace, 2026-11-23, prerelease first): ONE
/// segment only — the lock screen, a finger swipe up, and the home
/// screen it lands on. She asked for exactly this stretch, judged on
/// a real device, and killed if it does not convince.
///
/// What is real and what is imitation: the wallpaper itself is the pack's own material (its lock
/// picture or video, its home picture), and a video keeps playing
/// under the finger. The phone's furniture — the clock, the icon
/// grid, the fade and scale of the unlock itself — is drawn by this
/// page in the system's manner; no app can replay SpringBoard's own
/// animation frame for frame, and this page does not pretend to.
/// Interactive (CA) packs show their stills here for now; driving
/// their state machine is a later step, judged separately.
struct UnlockPreviewPayload: Identifiable {
    let id = UUID()
    let title: String
    var lockImage: UIImage?
    var homeImage: UIImage?
    var lockVideo: URL?

    var hasContent: Bool { lockImage != nil || lockVideo != nil }

    /// Build a payload from a pack (off the main thread: the stage
    /// media extraction opens the archive).
    static func load(pack: PosterBoardTendie) async -> UnlockPreviewPayload? {
        let media = await Task.detached { PosterBoardPreview.stageMedia(for: pack) }.value
        let payload = UnlockPreviewPayload(title: pack.name,
                                           lockImage: media.lockImage,
                                           homeImage: media.homeImage,
                                           lockVideo: media.lockVideo)
        return payload.hasContent ? payload : nil
    }

    /// Build a payload from the video page's pick: the video itself
    /// on the lock screen, its freeze frame on the home screen.
    static func load(video: URL, thumbnail: URL?) -> UnlockPreviewPayload? {
        let image = thumbnail.flatMap { UIImage(contentsOfFile: $0.path) }
        let payload = UnlockPreviewPayload(title: video.lastPathComponent,
                                           lockImage: image,
                                           homeImage: image,
                                           lockVideo: video)
        return payload.hasContent ? payload : nil
    }
}

struct UnlockPreviewView: View {
    let payload: UnlockPreviewPayload
    @Environment(\.dismiss) private var dismiss

    /// 0 = lock screen, 1 = home screen. The finger drives it; the
    /// release decides which end it settles on.
    @State private var progress: CGFloat = 0
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                homeLayer(geo.size)
                lockLayer(geo.size)
                chrome(geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .background(Color.black)
            .contentShape(Rectangle())
            .gesture(unlockGesture)
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
    }

    // MARK: - Layers

    private func homeLayer(_ size: CGSize) -> some View {
        ZStack {
            wallpaper(image: payload.homeImage, video: nil, size: size)
                .scaleEffect(1.09 - 0.09 * progress)
            iconGrid
                .opacity(Double(smooth(0.45, 0.95, progress)))
                .offset(y: (1 - progress) * 24)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func lockLayer(_ size: CGSize) -> some View {
        ZStack {
            wallpaper(image: payload.lockImage, video: payload.lockVideo, size: size)
                .scaleEffect(1 + 0.06 * progress)
            // The clock and the bottom furniture leave early, the
            // wallpaper itself fades last — the order the real
            // unlock reads in.
            VStack {
                TimelineView(.everyMinute) { _ in
                    VStack(spacing: 2) {
                        Text(Self.dateLine)
                            .font(.system(size: 17, weight: .medium))
                        Text(Self.timeLine)
                            .font(.system(size: 76, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                }
                Spacer()
                HStack {
                    lockCircle("flashlight.on.fill")
                    Spacer()
                    lockCircle("camera.fill")
                }
                .padding(.horizontal, 46)
                .padding(.bottom, 30)
            }
            .padding(.top, 64)
            .frame(width: size.width, height: size.height)
            .opacity(Double(max(0, 1 - progress * 2.2)))
            .offset(y: -52 * progress)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .opacity(Double(1 - smooth(0.55, 1.0, progress)))
        .offset(y: -0.10 * size.height * progress)
        .allowsHitTesting(false)
    }

    private func lockCircle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(Color.black.opacity(0.35), in: Circle())
    }

    /// The furniture that belongs to neither screen: the way out,
    /// the home bar, and the one-line hint for the current end.
    private func chrome(_ size: CGSize) -> some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Label("退出", systemImage: "xmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(Color.black.opacity(0.55), in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer()
                if payload.lockVideo != nil {
                    Text("视频")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.4), in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            Spacer()
            if progress < 0.05 {
                VStack(spacing: 3) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 15, weight: .semibold))
                    Text("上滑解锁")
                        .font(.footnote.weight(.medium))
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 1)
                .padding(.bottom, 16)
            } else if progress > 0.95 {
                Text("下滑回到锁屏")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.4), in: Capsule())
                    .padding(.bottom, 16)
            }
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.white.opacity(0.9))
                .frame(width: 134, height: 5)
                .padding(.bottom, 8)
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private func wallpaper(image: UIImage?, video: URL?, size: CGSize) -> some View {
        // The frame is not decoration: an unframed resizable image
        // proposes its own pixel size to the stack, the stack grows
        // past the screen, and every centred element (the clock,
        // the icon grid, the exit button) lands off-centre — the
        // first trial build shipped exactly that.
        Group {
            if let video {
                UnlockLoopingPlayer(url: video)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func smooth(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    // MARK: - Clock lines

    private static var dateLine: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: Date())
    }

    private static var timeLine: String {
        // Built from components on purpose: a locale formatter
        // handed the trial build "凌晨2:02" — period text the real
        // lock clock shows small, here blown up and clipped. The
        // real clock face is digits; spell them out directly.
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// A silent looping player for the lock layer, gapless via
/// AVPlayerLooper, filling the screen the way a wallpaper does.
/// Same shape as the tutorial's LoopingVideoView, but URL-fed and
/// aspect-fill.
private struct UnlockLoopingPlayer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerUIView { PlayerUIView(url: url) }
    func updateUIView(_ uiView: PlayerUIView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerUIView, coordinator: ()) {
        uiView.stop()
    }

    final class PlayerUIView: UIView {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?

        init(url: URL) {
            super.init(frame: .zero)
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            player.isMuted = true
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            player.play()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { player.play() } else { player.pause() }
        }

        func stop() { player.pause() }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        override class var layerClass: AnyClass { AVPlayerLayer.self }
    }
}
