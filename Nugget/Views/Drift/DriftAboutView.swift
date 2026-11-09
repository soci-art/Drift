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
                        rangeTable
                        DriftFactRow(title: "两种刷入方式",
                                     text: "直刷：只把壁纸写进壁纸商店，刷完注销（respring）不重启，范围窄。恢复式：把壁纸编进一份系统备份再恢复写回，覆盖全部受支持系统，刷完重启，会保留设备上已有的壁纸。视频壁纸和重置商店只能走恢复式。")
                        DriftFactRow(title: "系统范围",
                                     text: "iOS 26.0–26.1：只有恢复式。iOS 26.2–27.1、27.2 测试版 1/2：普通壁纸包可直刷，视频仍走恢复式。iOS 27.2 测试版 3 起（含 27.2 正式版、27.3 以上）：直刷被关闭，回落恢复式。App 会按配对读到的系统版本和构建号自动判断，每次刷入前重读。")
                        DriftFactRow(title: "隧道",
                                     text: "借 LocalDevVPN（或同类隧道 App）建立：地址要和设置里一致，需 Wi-Fi；如果隧道是在 App 启动之后才连上的，把 App 关掉重开一次。")
                        DriftFactRow(title: "签名",
                                     text: "两种签名都能用，功能无差别。Apple ID 免费签 7 天过期、重装会丢 App 内数据（配对和已导入的包要重新导入）；付费证书有效期长、更稳定。本 App 没有自己的隧道扩展，用不上付费证书的 VPN 权限。")
                        DriftFactRow(title: "风险与边界",
                                     text: "刷入时请保持解锁、隧道开着、配对有效；中途断开可能留下刷一半的状态。归属类型选错不报错、只是不显示。带数据库的容器包可能弄乱壁纸索引，本 App 没有备份和回滚，清乱了用「重置壁纸商店」。一次最多刷 10 张。本 App 没有下载功能，壁纸包请自备。纯动画的包没有静态图，列表里用占位图显示。")
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
            Text("导入 .tendies 壁纸包或一段视频，选好后刷入。不下载、不备份、不改系统其他设置。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    private var rangeTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("版本对照").font(.subheadline.weight(.semibold))
            rangeRow("26.0 – 26.1", "仅恢复式", "重启")
            rangeRow("26.2 – 27.1", "可直刷", "不重启")
            rangeRow("27.2 测试版 1 / 2", "可直刷", "不重启")
            rangeRow("27.2 测试版 3 起", "仅恢复式", "重启")
            Text("视频壁纸在任何版本都只能走恢复式。").font(.caption).foregroundStyle(.secondary)
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
