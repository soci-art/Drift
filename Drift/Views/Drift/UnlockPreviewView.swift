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
            wallpaper(image: payload.homeImage, video: nil)
                .scaleEffect(1.09 - 0.09 * progress)
            iconGrid
                .opacity(Double(smooth(0.45, 0.95, progress)))
                .offset(y: (1 - progress) * 24)
        }
    }

    private func lockLayer(_ size: CGSize) -> some View {
        ZStack {
            wallpaper(image: payload.lockImage, video: payload.lockVideo)
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
            .opacity(Double(max(0, 1 - progress * 2.2)))
            .offset(y: -52 * progress)
        }
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
                    Text("退出")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.4), in: Capsule())
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
    private func wallpaper(image: UIImage?, video: URL?) -> some View {
        if let video {
            UnlockLoopingPlayer(url: video)
                .ignoresSafeArea()
        } else if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
        } else {
            LinearGradient(colors: [.indigo, .purple.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    // MARK: - The icon grid (drawn furniture, generic apps)

    private struct AppIcon: Identifiable {
        let id = UUID()
        let name: String
        let symbol: String
        let color: Color
    }

    private static let apps: [AppIcon] = [
        .init(name: "电话", symbol: "phone.fill", color: Color(red: 0.20, green: 0.78, blue: 0.35)),
        .init(name: "信息", symbol: "message.fill", color: Color(red: 0.19, green: 0.82, blue: 0.35)),
        .init(name: "Safari", symbol: "safari.fill", color: Color(red: 0.04, green: 0.52, blue: 1.0)),
        .init(name: "邮件", symbol: "mail.fill", color: Color(red: 0.10, green: 0.45, blue: 0.95)),
        .init(name: "照片", symbol: "photo.fill", color: Color(red: 1.0, green: 0.62, blue: 0.04)),
        .init(name: "相机", symbol: "camera.fill", color: Color(red: 0.28, green: 0.28, blue: 0.29)),
        .init(name: "地图", symbol: "map.fill", color: Color(red: 0.19, green: 0.82, blue: 0.35)),
        .init(name: "时钟", symbol: "clock.fill", color: Color(red: 0.11, green: 0.11, blue: 0.12)),
        .init(name: "天气", symbol: "cloud.sun.fill", color: Color(red: 0.04, green: 0.52, blue: 1.0)),
        .init(name: "设置", symbol: "gearshape.fill", color: Color(red: 0.28, green: 0.28, blue: 0.29)),
        .init(name: "日历", symbol: "calendar", color: Color(red: 1.0, green: 0.23, blue: 0.19)),
        .init(name: "备忘录", symbol: "note.text", color: Color(red: 1.0, green: 0.84, blue: 0.04)),
        .init(name: "音乐", symbol: "music.note", color: Color(red: 0.99, green: 0.24, blue: 0.27)),
        .init(name: "钱包", symbol: "wallet.pass.fill", color: Color(red: 0.11, green: 0.11, blue: 0.12)),
        .init(name: "计算器", symbol: "calculator.fill", color: Color(red: 0.28, green: 0.28, blue: 0.29)),
        .init(name: "健康", symbol: "heart.fill", color: Color(red: 1.0, green: 0.18, blue: 0.33)),
        .init(name: "文件", symbol: "folder.fill", color: Color(red: 0.04, green: 0.52, blue: 1.0)),
        .init(name: "提醒事项", symbol: "checklist", color: Color(red: 1.0, green: 0.62, blue: 0.04)),
        .init(name: "指南针", symbol: "location.north.fill", color: Color(red: 0.04, green: 0.52, blue: 1.0)),
        .init(name: "录音机", symbol: "mic.fill", color: Color(red: 1.0, green: 0.23, blue: 0.19)),
    ]

    private static let dock: [AppIcon] = [
        .init(name: "", symbol: "phone.fill", color: Color(red: 0.20, green: 0.78, blue: 0.35)),
        .init(name: "", symbol: "safari.fill", color: Color(red: 0.04, green: 0.52, blue: 1.0)),
        .init(name: "", symbol: "message.fill", color: Color(red: 0.19, green: 0.82, blue: 0.35)),
        .init(name: "", symbol: "music.note", color: Color(red: 0.99, green: 0.24, blue: 0.27)),
    ]

    private var iconGrid: some View {
        VStack {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(62), spacing: 18), count: 4),
                      spacing: 20) {
                ForEach(Self.apps) { app in
                    VStack(spacing: 4) {
                        iconTile(app, size: 58)
                        Text(app.name)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    }
                }
            }
            .padding(.top, 78)
            Spacer()
            HStack(spacing: 22) {
                ForEach(Self.dock) { app in iconTile(app, size: 58) }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.22),
                        in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(.bottom, 22)
        }
        .padding(.horizontal, 24)
        .allowsHitTesting(false)
    }

    private func iconTile(_ app: AppIcon, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(app.color)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: app.symbol)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white))
    }

    // MARK: - Gesture

    private var unlockGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStart == nil { dragStart = progress }
                let start = dragStart ?? 0
                progress = min(1, max(0, start - value.translation.height / 300))
            }
            .onEnded { value in
                let start = dragStart ?? progress
                dragStart = nil
                let predicted = min(1, max(0, start - value.predictedEndTranslation.height / 300))
                let target: CGFloat = predicted > 0.45 ? 1 : 0
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                    progress = target
                }
                if target == 1 { AppLog.op("解锁预览：滑到桌面（\(payload.title)）") }
            }
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
        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm"
        return formatter.string(from: Date())
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
