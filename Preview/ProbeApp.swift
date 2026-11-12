import SwiftUI

/// DriftUIPreview — the simulator-only shell for the route-1 UI check
/// (Grace, 2026-11-12). It compiles Drift's real display files — theme,
/// tutorial pages, About page — with canned channel states, so CI can
/// screenshot them on iOS 17 / 18 / 26 simulators and the pre-glass
/// systems' own UI (#242) can be looked at before a build ships.
///
/// The engine and its FFI libraries have no simulator slices, so this
/// shell is display-only by construction: nothing here can flash, pair
/// or touch a device. It is never part of the shipped app.
///
/// The screen is chosen with the `-ProbeScreen` launch argument:
/// tutorial / local / norespring / respring / about / theme.
@main
struct ProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeRoot() }
    }
}

private struct ProbeRoot: View {
    private var screen: String {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-ProbeScreen"), index + 1 < args.count {
            return args[index + 1]
        }
        return "tutorial"
    }

    /// A plausible phone: local channel ready, tunnel channels set up
    /// short of pairing — the mix that shows every pill kind at once.
    private static let cannedStates: [TutorialChannel: TutorialChannelState] = [
        .noRespring: .needsSetup,
        .respring: .needsSetup,
        .local: .ready,
    ]

    var body: some View {
        switch screen {
        case "local":
            NavigationStack { DriftTutorialChannelView(channel: .local, state: .ready) }
        case "norespring":
            NavigationStack { DriftTutorialChannelView(channel: .noRespring, state: .needsSetup) }
        case "respring":
            NavigationStack { DriftTutorialChannelView(channel: .respring, state: .systemBlocked) }
        case "about":
            DriftAboutView()
        case "theme":
            ProbeThemeScreen()
        default:
            NavigationStack { DriftTutorialView(states: Self.cannedStates) }
        }
    }
}

/// The theme surfaces on their own: background, cards, pills and both
/// button treatments — the exact things #242 forks per system.
private struct ProbeThemeScreen: View {
    var body: some View {
        ZStack {
            DriftBackground()
            ScrollView {
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("界面元件").font(.headline)
                        HStack(spacing: 8) {
                            DriftPill(text: "可用", tint: .green)
                            DriftPill(text: "需要配对和隧道", tint: .orange)
                            DriftPill(text: "不可用")
                        }
                        Text("卡片、角标和按钮在这个系统上的样子。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .driftCard()

                    NativePrimaryButton(title: "刷入", systemImage: "paintbrush.pointed") {}
                    Button("普通按钮") {}
                        .driftGlassButton()
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
            }
        }
    }
}

/// Probe-only stand-in for the two strings DriftAboutView reads from
/// LegacyConversionCopy. The real enum lives in PosterBoardTendie.swift,
/// which the preview target deliberately does not compile (the pack
/// machinery cannot link for the simulator). The words are the app's
/// own zh-Hans catalog values, verbatim — what the About page shows.
enum LegacyConversionCopy {
    static var why: String {
        "老包用的是 WWDC22 时代的布局。iOS 27 的壁纸库读不了这种布局：不转换直接刷进去，不会报错，也永远不会显示。转换就是把包改写成 iOS 27 能读的新布局。"
    }

    static var versions: String {
        "要不要转换只看大版本：iOS 26 全系列原生能读老包，不需要转换、也不会弹询问；iOS 27 起全系列都需要转换。与小版本和 build 号无关。iOS 26 以下：不支持。"
    }
}
