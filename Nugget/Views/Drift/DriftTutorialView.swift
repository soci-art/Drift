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
/// One distinction is made twice, in the route step AND in its own
/// step, because getting it wrong wastes a whole run: turning off
/// Find My iPhone is a restore-route chore ONLY. Direct flashes never
/// need it, and no line on this page says "before flashing, turn off
/// Find My" without naming the route.
struct DriftTutorialView: View {
    var body: some View {
        ZStack {
            DriftBackground()
            ScrollView {
                VStack(spacing: 14) {
                    intro
                    step(number: 1, title: "准备：打开隧道，导入配对",
                         text: "先打开 LocalDevVPN 并连上 Wi-Fi，隧道就通了（主页顶部会显示「隧道已连通」）。再导入配对文件——Drift 只收 .plist：可以在向导、主页或设置页点「导入配对文件」选它，也可以在「文件」App 里对配对文件点打开方式选 Drift，或者把 pairingfile.plist 放进 Drift 的文稿目录，App 会自己认出来；iOS 27 还能在设置页用「无线自配对」当场生成一份。第一次打开 App 时有设置向导，跟着它走完这一步。主页顶部三项——已配对、隧道已连通、设备系统版本——都显示出来了，就可以下一步。")
                    step(number: 2, title: "导入壁纸包",
                         text: "在壁纸页点「导入」选 .tendies 文件，或者在「文件」App 里对壁纸包点打开方式选 Drift。导入后列表里每个包都带预览图（从包里提取的）；纯动画、没有静态图的包显示占位图，不影响刷入。点包行左侧的圆圈勾选要刷的包；点行的其他地方进详情，详情里能改「刷完出现在哪里」。一次最多刷 10 张。")
                    step(number: 3, title: "选方式，点刷入",
                         text: "主页「本次刷入方式」卡会按读到的系统版本自动判断走哪种，并写明原因，也可以点卡上的菜单手动选。两种方式的区别：直刷只把壁纸写进壁纸商店，刷完注销让系统重读，不重启；恢复式把壁纸编进一份备份再写回设备，刷完会重启。手动选不能突破硬限制——视频包、容器包、还有系统版本不支持直刷的情况都只能走恢复式，硬选了卡上会用橙字说明并按恢复式处理。方式对了就点「刷入」；过程里保持手机解锁、隧道开着。直刷的话到这里就齐了，下面第四步不用看。")
                    findMyStep
                    step(number: 5, title: "视频壁纸",
                         text: "想刷视频就去视频页：选好视频、确认，剩下的和普通刷入一样。视频在任何系统上都只能走恢复式、刷完会重启，所以第四步的关「查找我的 iPhone」对视频一样要做。")
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
            Text("第一次用从第一步开始；平时刷入主要看第三、四步。系统范围、两种方式的完整对照在「说明」页，这里不重复。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    /// Step 4 gets its own card rather than the shared step shape: it is
    /// the one step whose omission fails the run outright (the device
    /// refuses the restore), so it carries the warning mark and the
    /// orange badge — and it is fenced to the restore route in its
    /// first and last sentences.
    private var findMyStep: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("4")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.orange, in: Circle())
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("用恢复式之前：先关掉「查找我的 iPhone」")
                    .font(.subheadline.weight(.semibold))
            }
            Text("这一步只针对恢复式，直刷不用关。凡是走恢复的——恢复式刷入、视频壁纸、重置壁纸商店、设置里的「恢复备份」——开始之前先去系统「设置 → 你的名字 → 查找 → 查找我的 iPhone」把它关掉：开着它，设备会直接拒绝恢复，壁纸一张都刷不进去。刷完之后可以再打开，不影响已经刷好的壁纸。直刷再说一遍：不用关，打开 Drift 就能刷，刷完只注销、不重启。")
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
