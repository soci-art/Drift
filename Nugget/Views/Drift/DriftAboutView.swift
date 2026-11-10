import SwiftUI

/// The About page: what Drift does, which systems it covers, how each
/// delivery route behaves, and every risk the feature list says must be
/// written down rather than engineered around. Static text on purpose —
/// it has to read the same offline, unpaired and mid-failure.
struct DriftAboutView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                DriftBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        intro
                        // Feedback #30: the suspension is stated first,
                        // before any row that describes the restore route
                        // as a way to flash — nothing below may read as
                        // "restore is available" while the gate is closed.
                        if !DriftRestoreGate.isEnabled {
                            DriftFactRow(title: "恢复式暂时停用",
                                         text: DriftRestoreGate.notice + "下面凡是写「恢复式」的地方都先按停用看：只能走恢复式的内容（视频壁纸、重置商店、系统不在直刷范围内的普通包）暂时都刷不了。")
                        }
                        rangeTable
                        DriftFactRow(title: "三种刷入方式",
                                     text: "本机直刷：在 App 内用 worse_query 取得壁纸商店容器的沙盒扩展，直接把壁纸写进去，不用配对文件、不用隧道，刷完注销、不重启。AirLift 直刷：通过隧道写进同一个容器，需要配对和 LocalDevVPN，刷完注销、不重启。恢复式：把壁纸编进一份在手机外合成的系统备份再恢复写回，覆盖全部受支持系统，刷完重启。视频壁纸和重置商店只能走恢复式。")
                        DriftFactRow(title: "系统范围",
                                     text: "本机直刷：iOS 26.0–26.7.2、27.0–27.2，且签名要带 App Group。AirLift：iOS 26.2–27.1、27.2 测试版 1/2。AirLift 在 27.2 测试版 3 起被关闭，27.3 以上两种直刷都不可用。App 会自动判断并写明理由；没有配对时，本机直刷按 App 自己的系统版本判断。")
                        DriftFactRow(title: "旧格式转换",
                                     text: LegacyConversionCopy.why + LegacyConversionCopy.versions)
                        DriftFactRow(title: "隧道",
                                     text: "借 LocalDevVPN（或同类隧道 App）建立：地址固定用默认值（本机 10.7.1.1、对端 10.7.0.1、端口 62078），在 LocalDevVPN 里填同样的值即可，需 Wi-Fi；隧道状态实时检测，App 打开之后再连上隧道也会自动识别并连接，不用重开 App。")
                        DriftFactRow(title: "签名",
                                     text: "Apple ID 免费签和付费证书都能用，功能无差别——但本机直刷是例外：它需要签名带 App Group，免费签拿不到，只能用付费证书并在开发者后台注册该 Group。免费签 7 天过期、重装会丢 App 内数据（配对和已导入的包要重新导入）；付费证书有效期长、更稳定。本 App 没有自己的隧道扩展，用不上付费证书的 VPN 权限。")
                        DriftFactRow(title: "风险与边界",
                                     text: "刷入时请保持解锁、隧道开着、配对有效；中途断开可能留下刷一半的状态。出现位置选错不报错、只是不显示。带数据库的容器包可能弄乱壁纸索引，清乱了用「重置壁纸商店」。刷入和清理全程不从设备拉取备份：壁纸数据库用本地缓存的副本，没有缓存时从零新建，设备上原有的壁纸可能不再被列出；已经存在的本地备份可以在设置里删除（写回设备的「恢复备份」属于恢复式，暂时停用）。一次最多刷 10 张。本 App 没有下载功能，壁纸包请自备。纯动画的包没有静态图，列表里用占位图显示。")
                        DriftFactRow(title: "基于",
                                     text: "Drift 是独立应用：只借用了 GoldenNugget 的原理与壁纸／连接层代码（沿用 AGPL-3.0 许可证），界面、UI 与主题均为重新设计，只保留刷壁纸功能。")
                    }
                    .padding(16)
                }
            }
            .navigationTitle("说明")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Drift 只做一件事：把交互壁纸刷进这台设备。")
                .font(.headline)
            Text("导入 .tendies 壁纸包或一段视频，选好后刷入。不下载、不从设备拉取备份、不改系统其他设置。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    private var rangeTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("版本对照").font(.subheadline.weight(.semibold))
            rangeRow("26.0 – 26.1", "本机直刷*", "不重启")
            rangeRow("26.2 – 27.1", "可直刷", "不重启")
            rangeRow("27.2 测试版 1 / 2", "可直刷", "不重启")
            rangeRow("27.2（测试版 3 起）", "本机直刷*", "不重启")
            rangeRow("27.3 以上", DriftRestoreGate.isEnabled ? "仅恢复式" : "仅恢复式（停用中）", "重启")
            Text("* 本机直刷需要签名带 App Group，免费 Apple ID 签不了；没有时这几档没有可用的直刷方式。")
                .font(.caption).foregroundStyle(.secondary)
            Text(DriftRestoreGate.isEnabled
                 ? "视频壁纸在任何版本都只能走恢复式。"
                 : "视频壁纸在任何版本都只能走恢复式，恢复式停用期间暂时刷不了。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    private func rangeRow(_ range: String, _ mode: String, _ cost: String) -> some View {
        HStack {
            Text(range).font(.subheadline)
            Spacer()
            DriftPill(text: mode)
            DriftPill(text: cost, tint: .secondary)
        }
    }
}
