import SwiftUI

/// One channel's tutorial page (collection #236, Grace 2026-11-12). All
/// three pages share one skeleton — status banner, 需要什么, 怎么刷,
/// 刷完怎么生效, 常见问题 — and differ only in their copy and in how the
/// wallpaper takes effect. The wording is the set Grace approved page by
/// page: plain words only (#232), every page teaches where
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
                    if channel == .restore {
                        section("这是什么") {
                            checklistCard(lines: [
                                "把手机的备份拉下来，只把里面的壁纸换成你选的，再把备份写回去；数据和 App 都不动。",
                                "别的通道都用不了的时候走这条：比如 iOS 27.3 beta 2 起，其他方式全断了，只剩恢复刷。",
                            ])
                        }
                    }
                    section("需要什么") { checklistCard(lines: requirements) }
                    if channel.isTunnel {
                        section("先准备这两样") { prepareCards }
                    }
                    section("怎么刷") { stepsCard(steps: flashSteps) }
                    if channel == .restore {
                        section("注意") {
                            checklistCard(lines: [
                                "全程大约十分钟，拉取备份占大头；手机存储要留够空间。",
                                "中途断了不会把手机弄坏：重新刷一次就行。",
                                "刷完重启后会走一遍设置流程，是正常现象，手动走完就好。",
                            ])
                        }
                    }
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
        case .notEnabled:
            return ("这种方式还没打开",
                    .orange, "exclamationmark.triangle.fill")
        }
    }

    // MARK: - Copy per channel

    private var requirements: [String] {
        switch channel {
        case .local:
            return [
                "签名看系统：iOS 26.0–26.6.1 不挑签名、不用组，免费 ID 签也能用；其余系统要证书签名（带能用的组），免费 ID 签用不了",
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
        case .kernel:
            return [
                "先在「设置 → 实验性功能」里打开「内核直刷」开关（主页里能看到这一项，但不开开关刷不了，选了会先提醒你去打开）",
                "系统在 iOS 17.0 到 iOS 18.7.1 之间",
                "不用配对、不用隧道，也不用连 Wi-Fi",
                "签名不限：哪种签名装的都行",
            ]
        case .restore:
            return [
                "系统是 iOS 27（正式版和 beta 都行）",
                "不要求证书：免费 ID 签名也能用",
                "配对文件（先配对一次，之后一直能用）",
                "隧道：刷的时候开着 LocalDevVPN，手机连着 Wi-Fi",
                "刷之前先把手机整机备份到电脑，并关掉「查找」",
            ]
        }
    }

    private var flashSteps: [String] {
        if channel == .restore {
            return [
                "先把手机整机备份到电脑，并关掉「查找」；再打开 LocalDevVPN、确认配对文件已导入",
                "选壁纸：壁纸包在壁纸页勾选；视频先在视频页解码，再在选择页里选已解码的",
                "刷入方式选「恢复刷」，点「刷入」，看完弹窗点「确定刷入」",
                "等它跑完：先拉取备份、再写回，中途不要划掉 App、不要断 Wi-Fi 和 LocalDevVPN",
                "写回成功后，按提示重启手机",
                "重启后会走一遍设置流程，手动走完即可，数据和 App 都在",
                "回到桌面后检查描述文件还在不在，不在了就重新安装",
            ]
        }
        let third = switch channel {
        case .noRespring, .local, .kernel:
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
        case .restore:
            return [
                ("没关「查找」会怎样？",
                 "写回会被手机拒绝（错误 211），刷不进去。先到「设置 → 你的名字 → 查找」里关掉，刷完再打开。"),
                ("刷完描述文件不见了？",
                 "写回有时会把描述文件弄掉，原因还没查清。刷完到「设置 → 通用 → VPN 与设备管理」里看一眼，不在了就重新安装。"),
                ("走设置流程时要验证 Apple ID？",
                 "那是恢复后的固定一页，照常验证就行；验证的是你自己的账号，跟签名、证书没关系。"),
                ("要多久？",
                 "全程大约十分钟，大头在拉取备份。拉取时别划掉 App。"),
                pickWallpaper,
            ]
        case .kernel:
            return [
                ("选了「内核直刷」却刷不了？",
                 "多半是还没打开：先去「设置 → 实验性功能」里把「内核直刷」打开，再回来刷。"),
                ("提示用不了？",
                 "这个方式只支持 iOS 17 / 18：系统不在这个范围用不了，机型不在支持表里也用不了。"),
                ("刷完了，壁纸没变？",
                 "多半是只回了桌面、没划掉壁纸界面。按上面那一步，在后台里把它甩掉再看。"),
                pickWallpaper,
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
        case .restore:
            heroCard(tint: .red, icon: "arrow.counterclockwise.circle.fill",
                     title: "重启后走完设置流程就生效") {
                numberedSteps([
                    "写回成功后 Drift 会问你要不要重启，点重启（也可以自己手动重启）",
                    "重启后会走一遍设置流程，手动走完，数据和 App 都在",
                    "回到桌面后，长按锁屏（或打开「设置 → 墙纸」），在列表里选刚刷的这张，设成当前壁纸",
                    "最后检查一遍描述文件还在不在，不在了重新安装",
                ], tint: .red)
            }
        case .kernel:
            heroCard(tint: .orange, icon: "hand.tap.fill",
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
                    ], tint: .orange)
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
