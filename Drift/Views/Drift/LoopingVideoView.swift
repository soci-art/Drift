import AVFoundation
import SwiftUI
import UIKit

/// A silent, looping, control-less video (collection #234): the tutorial's
/// gesture film. `AVPlayerLooper` on a queue player gives a gapless loop
/// with no seek bar and no chrome — the page treats it like an animated
/// picture, which is what it is for.
struct LoopingVideoView: View {
    /// Bundle resource name without extension (an .mp4 in the app bundle).
    let resource: String

    var body: some View {
        if let url = Bundle.main.url(forResource: resource, withExtension: "mp4") {
            LoopingPlayerView(url: url)
        }
    }

    private struct LoopingPlayerView: UIViewRepresentable {
        let url: URL

        func makeUIView(context: Context) -> PlayerUIView {
            PlayerUIView(url: url)
        }

        func updateUIView(_ uiView: PlayerUIView, context: Context) {}

        static func dismantleUIView(_ uiView: PlayerUIView, coordinator: ()) {
            uiView.stop()
        }
    }

    private final class PlayerUIView: UIView {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?

        init(url: URL) {
            super.init(frame: .zero)
            looper = AVPlayerLooper(player: player,
                                    templateItem: AVPlayerItem(url: url))
            player.isMuted = true
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            player.play()
        }

        /// #315: the loop used to play forever, including after the
        /// tutorial page was left — a muted film nobody was watching
        /// still cost battery and decode time. Playback now follows
        /// the window: on screen plays, off screen pauses.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { player.play() } else { player.pause() }
        }

        func stop() { player.pause() }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override class var layerClass: AnyClass { AVPlayerLayer.self }

        private var playerLayer: AVPlayerLayer {
            // swiftlint:disable:next force_cast — layerClass above fixes the type.
            layer as! AVPlayerLayer
        }
    }
}
