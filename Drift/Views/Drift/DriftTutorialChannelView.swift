import SwiftUI

/// One channel's tutorial page (collection #236, Grace 2026-11-12). All
/// three pages share one skeleton — status banner, 需要什么, 怎么刷,
/// 刷完怎么生效, 常见问题 — and differ only in their copy and in how the
/// wallpaper takes effect. The wording is the set Grace approved page by
/// page: plain words, no 改签 anywhere (#232), every page teaches where
/// the flashed wallpaper gets picked (#233), and the local page follows
/// the real flow — after a flash the app brings the wallpaper interface
/// to the front by itself (#235), then teaches the app-switcher flick
/// with the bundled film (#234).
struct DriftTutorialChannelView: View {
    let channel: TutorialChannel

    /// The channel's standing, judged by the caller when the tutorial
    /// was opened (see DriftTutorialView). Pure display, like the home.
    let state: TutorialChannelState

    var body: some View {
        ZStack {
            DriftBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    banner
                    section("需要什么") { checklistCard(lines: requirements) }
                    if channel.isTunnel {
                        section("先准备这两样") { prepareCards }
                    }
                    section("怎么刷") { stepsCard(steps: flashSteps) }
                    section("刷完怎么生效") { effectCard }
                    section("常见问题") { faqCard(items: faqs) }
                }
                .padding(16)
                .driftPageWidth()
            }
        }
        .navigationTitle(channel.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Status banner

    private var banner: some View {
        let (text, tint, icon) = bannerContent
        return HStack(spacing: 9) {
            Image(systemName: icon).font(.subheadline.weight(.bold))
            Text(text).font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var bannerContent: (String, Color, String) {
        switch state {
        case .ready:
            return (channel.isTunnel ? "你的手机能用这种方式，都准备好了"
                                     : "你的手机能用这种方式",
                    .green, "checkmark.circle.fill")
        case .needsSetup:
            return ("你的系统能用这种方式，还差配对和隧道",
                    .orange, "exclamationmark.triangle.fill")
        case .systemBlocked:
            return ("你的系统用不了这种方式",
                    .red, "xmark.circle.fill")
        case .groupBlocked:
            return ("你的系统在范围内，但签名没有能用的组，本机直刷用不了",
                    .orange, "exclamationmark.triangle.fill")
        }
    }

    // MARK: - Copy per channel

    private var requirements: [String] {
        switch channel {
        case .local:
            return [
                "证书签名（签名里要带能用的组；免费 ID 签没有能用的组，用不了）",
                "系统在 iOS 26.0 正式版到 iOS 27.2.1 正式版之间；iOS 27.2 beta 1 / beta 2、iOS 27.3 beta 1 也行",
                "不用配对、不用隧道，也不用连 Wi-Fi",
            ]
        case .noRespring, .respring:
            return [
                "配对文件（先配对一次，之后一直能用）",
                "隧道：刷的时候开着 LocalDevVPN，手机连着 Wi-Fi",
                "系统在 iOS 18.0 到 iOS 27.1 正式版之间；iOS 27.2 只支持 beta 1 / beta 2，iOS 27.2 正式版用不了",
                "签名不限：哪种签名装的都行",
            ]
        }
    }

    private var flashSteps: [String] {
        let third = switch channel {
        case .noRespring, .local:
            "点「刷入」，等它写完（手机保持解锁，别切走）"
        case .respring:
            "点「刷入」，等它写完（手机保持解锁，别切走；写完会提示你注销）"
        }
        return [
            "在壁纸页点「导入」，选一个 .tendies 壁纸包",
            "刷入方式选「\(channel.title)」",
            third,
        ]
    }

    private var faqs: [(String, String)] {
        let pickWallpaper = ("刷完了，去哪里设置壁纸？",
                             "长按锁屏，或者打开「设置 → 墙纸」，刚刷的壁纸就在列表里，点它设成当前壁纸就行。")
        switch channel {
        case .local:
            return [
                ("提示「没有能用的组」？",
                 "是签名不对。换成证书签名重新装一次 Drift 就行。"),
                ("刷完了，壁纸没变？",
                 "多半是只回了桌面、没划掉壁纸界面。按上面那一步，在后台里把它甩掉再看。"),
                pickWallpaper,
                ("第一次刷特别慢？",
                 "正常。第一次要在手机里找壁纸存放的位置，找到就会记住，之后再刷就快了。"),
            ]
        case .noRespring:
            return [
                ("隧道连不上？",
                 "先确认 LocalDevVPN 开着、Wi-Fi 连着；还不行就关掉 LocalDevVPN 再打开。再不行，重启一次手机——配对不用重做。"),
                ("刷完了，壁纸没变？",
                 "到主界面下面的「刷新与生效」里点一次「结束 PosterBoard」，再回锁屏看。"),
                pickWallpaper,
                ("每次刷都要配对吗？",
                 "不用。配对一次、文件导进来之后，一直能用。"),
            ]
        case .respring:
            return [
                ("注销是什么？会丢东西吗？",
                 "注销就是手机界面重启一遍，几秒钟就回来，App 和里面的东西都不受影响。这个方式写完必须注销一次才生效。"),
                ("刷完没有自动注销？",
                 "到主界面下面的「刷新与生效」里点「立即注销」，补一次就行。"),
                ("隧道连不上？",
                 "先确认 LocalDevVPN 开着、Wi-Fi 连着；还不行就关掉 LocalDevVPN 再打开。再不行，重启一次手机——配对不用重做。"),
                pickWallpaper,
                ("每次刷都要配对吗？",
                 "不用。配对一次、文件导进来之后，一直能用。"),
            ]
        }
    }

    // MARK: - Cards

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4).padding(.bottom, 7)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func checklistCard(lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold)).foregroundStyle(.green)
                        .padding(.top, 2)
                    Text(line).font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    private var prepareCards: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 11) {
                prepareCard(icon: "link", tint: .blue, title: "配对",
                            text: "在主界面点「导入配对文件」，或用无线配对。配一次就行。")
                prepareCard(icon: "wifi", tint: .green, title: "隧道",
                            text: "打开 LocalDevVPN 连上，手机保持连着 Wi-Fi 不要断。")
            }
            VStack(spacing: 11) {
                prepareCard(icon: "link", tint: .blue, title: "配对",
                            text: "在主界面点「导入配对文件」，或用无线配对。配一次就行。")
                prepareCard(icon: "wifi", tint: .green, title: "隧道",
                            text: "打开 LocalDevVPN 连上，手机保持连着 Wi-Fi 不要断。")
            }
        }
    }

    private func prepareCard(icon: String, tint: Color,
                             title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    private func stepsCard(steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.footnote.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.accentColor, in: Circle())
                    Text(step).font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    private func faqCard(items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.0).font(.subheadline.weight(.semibold))
                    Text(item.1).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    // MARK: - How it takes effect (the hero card, one shape per channel)

    @ViewBuilder
    private var effectCard: some View {
        switch channel {
        case .noRespring:
            heroCard(tint: .green, icon: "checkmark.circle.fill",
                     title: "刷完直接生效，什么都不用做") {
                Text("写完之后，Drift 会让壁纸界面自己重读一遍新壁纸，不用注销、不用划掉任何东西。最后长按锁屏（或打开「设置 → 墙纸」），选刚刷的这张设成当前壁纸就行。")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .respring:
            heroCard(tint: .purple, icon: "arrow.clockwise.circle.fill",
                     title: "写完注销一次，回来就生效") {
                numberedSteps([
                    "写完后 Drift 会提示你注销，点确认，手机界面会重启一遍（几秒钟，东西不丢）",
                    "回来之后，长按锁屏（或打开「设置 → 墙纸」），在列表里选刚刷的这张，设成当前壁纸",
                ], tint: .purple)
            }
        case .local:
            heroCard(tint: .blue, icon: "hand.tap.fill",
                     title: "把壁纸界面从后台划掉") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("刷完后，壁纸界面会自动打开，就是锁屏那个界面。接下来：")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    LoopingVideoView(resource: "PosterCloseGesture")
                        .frame(width: 200, height: 359)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    numberedSteps([
                        "从屏幕最下面往上滑，滑到一半停住别松手，会看到一排打开过的界面",
                        "找到壁纸那张卡片，把它往上甩出去",
                        "系统会自己重新打开壁纸界面、读入新壁纸",
                        "长按锁屏（或打开「设置 → 墙纸」），在列表里选刚刷的这张，设成当前壁纸",
                    ], tint: .blue)
                    Text("只滑回桌面不算关掉——它还留在后台，壁纸不会换。一定要在后台里把它甩掉。")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func heroCard<Content: View>(tint: Color, icon: String, title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.body.weight(.bold))
                Text(title).font(.body.weight(.bold))
            }
            .foregroundStyle(tint)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(tint.opacity(0.55), lineWidth: 1.6)
        )
    }

    private func numberedSteps(_ steps: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.footnote.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(tint, in: Circle())
                    Text(step).font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
