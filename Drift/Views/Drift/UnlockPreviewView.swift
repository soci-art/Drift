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
                .scaleEffect(1.10 - 0.10 * progress)
            homeScreen(size)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func lockLayer(_ size: CGSize) -> some View {
        // Laid out the way the real lock screen is (Grace,
        // 2026-11-23): padlock over a centred date over a big
        // digital clock, the two round buttons in the bottom
        // corners, everything measured off this phone's screen.
        // The motion follows the real unlock too: the whole sheet
        // rides up under the finger, the clock runs ahead of the
        // wallpaper (parallax), swells a touch and blurs out
        // early; the wallpaper itself only fades at the very end.
        ZStack {
            wallpaper(image: payload.lockImage, video: payload.lockVideo, size: size)
                .scaleEffect(1 + 0.05 * progress)
            VStack(spacing: 0) {
                VStack(spacing: 3) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .padding(.bottom, 10)
                    TimelineView(.everyMinute) { _ in
                        VStack(spacing: 1) {
                            Text(Self.dateLine)
                                .font(.system(size: size.width * 0.049, weight: .medium))
                            Text(Self.timeLine)
                                .font(.system(size: size.width * 0.235, weight: .bold, design: .rounded))
                        }
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                .scaleEffect(1 + 0.10 * progress)
                .blur(radius: 7 * smooth(0.08, 0.55, progress))
                .opacity(Double(1 - smooth(0.04, 0.48, progress)))
                .offset(y: -0.16 * size.height * progress)
                Spacer()
                HStack {
                    lockCircle("flashlight.on.fill")
                    Spacer()
                    lockCircle("camera.fill")
                }
                .padding(.horizontal, size.width * 0.107)
                .padding(.bottom, size.height * 0.052)
                .opacity(Double(1 - smooth(0.0, 0.32, progress)))
            }
            .padding(.top, size.height * 0.105)
            .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .opacity(Double(1 - smooth(0.70, 1.0, progress)))
        .offset(y: -0.38 * size.height * progress)
        .allowsHitTesting(false)
    }

    private func lockCircle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20))
            .foregroundStyle(.white)
            .frame(width: 50, height: 50)
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

    // MARK: - Gesture

    /// The finger drives `progress` directly — the real unlock
    /// tracks 1:1 too. On release the predicted throw decides the
    /// end, and a spring with the system's heavy, quick settle
    /// carries it there.
    private var unlockGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStart == nil { dragStart = progress }
                let start = dragStart ?? 0
                progress = min(1, max(0, start - value.translation.height / 300))
            }
            .onEnded { value in
                let predicted = (dragStart ?? progress)
                    - value.predictedEndTranslation.height / 300
                let target: CGFloat = predicted > 0.45 ? 1 : 0
                dragStart = nil
                withAnimation(.spring(response: 0.5, dampingFraction: 0.83)) {
                    progress = target
                }
            }
    }

    // MARK: - Home screen furniture

    /// The home screen, measured off the real one: 60pt icons,
    /// four across, labels under, a frosted dock with four more.
    /// Icons cascade in the way the real unlock reads — each one
    /// a beat after the last, swelling from small as it lands.
    private func homeScreen(_ size: CGSize) -> some View {
        let icon: CGFloat = 60
        let gap = size.width * 0.077
        let edge = (size.width - 4 * icon - 3 * gap) / 2
        return VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(icon), spacing: gap), count: 4),
                      spacing: 26) {
                ForEach(Array(Self.apps.enumerated()), id: \.offset) { index, app in
                    let row = index / 4, col = index % 4
                    let local = smooth(0.30 + 0.055 * CGFloat(row) + 0.018 * CGFloat(col),
                                       0.86 + 0.055 * CGFloat(row) + 0.018 * CGFloat(col),
                                       progress)
                    VStack(spacing: 4) {
                        appIcon(app, size: icon)
                        Text(app.name)
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    }
                    .scaleEffect(0.55 + 0.45 * local)
                    .opacity(Double(local))
                    .offset(y: (1 - local) * 30)
                }
            }
            .padding(.horizontal, edge)
            Spacer()
            HStack(spacing: gap) {
                ForEach(Array(Self.dockApps.enumerated()), id: \.offset) { index, app in
                    let local = smooth(0.42 + 0.02 * CGFloat(index),
                                       0.97 + 0.02 * CGFloat(index), progress)
                    appIcon(app, size: icon)
                        .scaleEffect(0.55 + 0.45 * local)
                        .opacity(Double(local))
                        .offset(y: (1 - local) * 30)
                }
            }
            .padding(.horizontal, gap)
            .padding(.vertical, 16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .padding(.top, size.height * 0.068)
        .frame(width: size.width, height: size.height)
    }

    /// One icon, drawn the way the real app looks at a glance:
    /// its own colours and glyph. The calendar carries today's
    /// real date; the rest are symbols on the right ground. Not
    /// the apps' own artwork — close enough that the screen
    /// reads as the phone's home screen.
    private func appIcon(_ app: PreviewApp, size: CGFloat) -> some View {
        Group {
            if app.name == "日历" {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.225)
                        .fill(Color.white)
                    VStack(spacing: 0) {
                        Text(Self.weekdayLine)
                            .font(.system(size: size * 0.19, weight: .medium))
                            .foregroundStyle(.red)
                        Text(Self.dayLine)
                            .font(.system(size: size * 0.52, weight: .light))
                            .foregroundStyle(.black)
                    }
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.225)
                        .fill(LinearGradient(colors: [app.top, app.bottom],
                                             startPoint: .top, endPoint: .bottom))
                    Image(systemName: app.symbol)
                        .font(.system(size: size * 0.52, weight: .regular))
                        .foregroundStyle(app.glyph)
                }
            }
        }
        .frame(width: size, height: size)
    }

    private struct PreviewApp {
        let name: String
        let symbol: String
        let top: Color
        let bottom: Color
        let glyph: Color

        init(_ name: String, _ symbol: String, _ top: Color, _ bottom: Color,
             glyph: Color = .white) {
            self.name = name; self.symbol = symbol
            self.top = top; self.bottom = bottom; self.glyph = glyph
        }
    }

    private static let apps: [PreviewApp] = [
        .init("电话", "phone.fill", .init(red: 0.35, green: 0.85, blue: 0.38), .init(red: 0.16, green: 0.72, blue: 0.24)),
        .init("信息", "message.fill", .init(red: 0.35, green: 0.85, blue: 0.38), .init(red: 0.16, green: 0.72, blue: 0.24)),
        .init("Safari", "compass.drawing", .white, .white, glyph: .init(red: 0.05, green: 0.45, blue: 0.95)),
        .init("照片", "photo.on.rectangle.angled", .white, .white, glyph: .init(red: 0.95, green: 0.65, blue: 0.10)),
        .init("相机", "camera.fill", .init(red: 0.92, green: 0.92, blue: 0.94), .init(red: 0.80, green: 0.80, blue: 0.84), glyph: .init(red: 0.25, green: 0.25, blue: 0.28)),
        .init("地图", "map.fill", .init(red: 0.30, green: 0.85, blue: 0.40), .init(red: 0.10, green: 0.70, blue: 0.30)),
        .init("天气", "cloud.sun.fill", .init(red: 0.20, green: 0.55, blue: 0.95), .init(red: 0.10, green: 0.35, blue: 0.85)),
        .init("设置", "gearshape.fill", .init(red: 0.75, green: 0.75, blue: 0.78), .init(red: 0.55, green: 0.55, blue: 0.60), glyph: .init(red: 0.30, green: 0.30, blue: 0.33)),
        .init("日历", "", .white, .white),
        .init("音乐", "music.note", .init(red: 0.98, green: 0.35, blue: 0.45), .init(red: 0.90, green: 0.15, blue: 0.30)),
        .init("钱包", "wallet.pass.fill", .init(red: 0.13, green: 0.13, blue: 0.15), .init(red: 0.05, green: 0.05, blue: 0.07)),
        .init("计算器", "plus.forwardslash.minus", .init(red: 0.30, green: 0.30, blue: 0.32), .init(red: 0.16, green: 0.16, blue: 0.18)),
        .init("文件", "folder.fill", .white, .white, glyph: .init(red: 0.10, green: 0.50, blue: 0.95)),
        .init("提醒事项", "checklist", .white, .white, glyph: .init(red: 0.95, green: 0.55, blue: 0.10)),
        .init("指南针", "location.north.fill", .init(red: 0.13, green: 0.13, blue: 0.15), .init(red: 0.05, green: 0.05, blue: 0.07), glyph: .init(red: 0.95, green: 0.25, blue: 0.25)),
        .init("时钟", "clock.fill", .init(red: 0.10, green: 0.10, blue: 0.12), .init(red: 0.03, green: 0.03, blue: 0.05)),
    ]

    private static let dockApps: [PreviewApp] = [
        .init("电话", "phone.fill", .init(red: 0.35, green: 0.85, blue: 0.38), .init(red: 0.16, green: 0.72, blue: 0.24)),
        .init("Safari", "compass.drawing", .white, .white, glyph: .init(red: 0.05, green: 0.45, blue: 0.95)),
        .init("信息", "message.fill", .init(red: 0.35, green: 0.85, blue: 0.38), .init(red: 0.16, green: 0.72, blue: 0.24)),
        .init("音乐", "music.note", .init(red: 0.98, green: 0.35, blue: 0.45), .init(red: 0.90, green: 0.15, blue: 0.30)),
    ]

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

    private static var weekdayLine: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: Date())
    }

    private static var dayLine: String {
        String(Calendar.current.component(.day, from: Date()))
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
