import SwiftUI

/// The tutorial (feedback #29): Drift used in the order it is actually
/// used — connect, import, pick a route, flash — reached from Settings,
/// directly under the setup-guide row.
///
/// Division of labour with the About page: About keeps the facts
/// (coverage table, route behaviour, risks); this page teaches the
/// steps and only borrows a verdict in one line where a step depends
/// on it. Nothing here restates About's tables.
///
/// Step 4 used to teach the restore route's Find-My-iPhone chore.
/// Since feedback #30 the restore route is suspended (a confirmed
/// restore ended in a factory reset after reboot; cause under audit),
/// so step 4 is the suspension notice instead — the Find-My chore comes
/// back with the route, not before. What survives from the old step is
/// its fence: nothing on this page may read as restore being usable.
struct DriftTutorialView: View {
    var body: some View {
        ZStack {
            DriftBackground()
            ScrollView {
                VStack(spacing: 14) {
                    intro
                    step(number: 1, title: "准备：配对与隧道（本机直刷可跳过）",
                         text: "要用本机直刷的话，这一步可以跳过——它不需要配对文件，也不需要隧道，只要签名授予可用的 App Group（App 会在运行时读取签名实际给的组）。要用直刷免注销或 AirLift 时，先打开 LocalDevVPN 并连上 Wi-Fi，隧道就通了（主页「隧道方式前提」里会显示「隧道已连通」）。再导入配对文件——Drift 只收 .plist：可以在向导、主页或设置页点「导入配对文件」选它，也可以在「文件」App 里对配对文件点打开方式选 Drift，或者把 pairingfile.plist 放进 Drift 的文稿目录，App 会自己认出来；iOS 27 还能在设置页用「无线自配对」当场生成一份。第一次打开 App 有设置向导：本机直刷可用时完成按钮不会被配对/隧道挡住，不可用才需要走完这两步。")
                    step(number: 2, title: "导入壁纸包",
                         text: "在壁纸页点「导入」选 .tendies 文件，或者在「文件」App 里对壁纸包点打开方式选 Drift。导入后列表里每个包都带预览图（从包里提取的）；纯动画、没有静态图的包显示占位图，不影响刷入。点包行左侧的圆圈勾选要刷的包；点行的其他地方进详情，详情里能改「刷完出现在哪里」。一次最多刷 10 张。")
                    step(number: 3, title: "选方式，点刷入",
                         text: "主页「本次刷入方式」卡会按前提自动选一种，逐条写明每种方式可用/不可用的理由，也可以点卡上的菜单手动选。四种方式的区别：直刷免注销通过配对隧道写进商店容器，然后只重启 PosterBoard 守护进程，免注销生效，要配对、隧道和设备解锁；本机直刷在 App 内写进壁纸商店容器，写入不用配对、不用隧道，写完再按当时条件决定生效方式——配对、LocalDevVPN、Wi-Fi 齐全就免注销，否则只提示并给「手动注销」按钮，App 不自动注销；AirLift 直刷通过隧道写同一个容器，刷完注销、不重启；恢复式把壁纸编进备份再写回设备，刷完会重启。手动选也不能突破硬限制——视频包、容器包、带数据库的包都只能走恢复式。恢复式目前暂时停用（见第四步），所以只能走恢复式的情况现在都刷不了，能直刷的照常刷。点「刷入」后，用隧道的方式要保持手机解锁、隧道开着。")
                    restoreSuspendedStep
                    step(number: 5, title: "视频壁纸",
                         text: "想刷视频就去视频页：选好视频、确认，剩下的和普通刷入一样。视频在任何系统上都只能走恢复式、刷完会重启；恢复式停用期间，视频壁纸暂时刷不了。")
                    step(number: 6, title: "旧格式转换（一句带过）",
                         text: "iOS 27 上，旧格式的包要先转换成新格式才显示；勾选时 App 会问你一次、答案会记住，答错了在包的详情页「旧格式处理」里随时改。（iOS 26 不需要转换。）")
                    step(number: 7, title: "出问题怎么办",
                         text: "先看日志：主页底部就是运行日志，设置页「记录 → 运行日志」是同一份，失败原因一般写在最后几行。自己看不明白，就在设置页「记录」里点「打包分享记录」，把打好的整包发给帮你排查的人，不用一个个找文件。最常见的三种：提示隧道未连接——打开 LocalDevVPN、连上 Wi-Fi 再试；提示未配对或配对失效——重新导入一次 .plist 配对文件；刷到一半失败——保持手机解锁、别关隧道，重新刷一次。")
                }
                .padding(16)
            }
        }
        .navigationTitle("使用教程")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("照着这个顺序来，就能把壁纸刷进去。")
                .font(.headline)
            Text("第一次用从第一步开始；平时刷入主要看第三、四步。系统范围、四种方式的完整对照在「说明」页，这里不重复。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    /// Step 4 keeps its own card and the warning styling, but what it
    /// teaches changed with feedback #30: the restore route is
    /// suspended, so this step is the suspension notice. The old
    /// Find-My-iPhone chore is deliberately NOT taught here any more —
    /// it only matters on a route nobody may use until the gate
    /// reopens, and teaching it would read as restore being available.
    private var restoreSuspendedStep: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("4")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.orange, in: Circle())
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("恢复式暂时停用")
                    .font(.subheadline.weight(.semibold))
            }
            Text(DriftRestoreGate.notice + "只能走恢复式的内容——视频壁纸、重置壁纸商店、带数据库的容器包，以及直刷免注销、AirLift、本机直刷都不可用的系统上的普通包——这段时间都先放一放，等恢复式重新开放再刷。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    private func step(number: Int, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.accentColor, in: Circle())
                Text(title).font(.subheadline.weight(.semibold))
            }
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }
}
