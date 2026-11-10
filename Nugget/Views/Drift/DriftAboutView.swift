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
                        DriftFactRow(title: "四种刷入方式",
                                     text: "直刷免注销：通过配对隧道把壁纸写进商店容器，再只重启 PosterBoard 守护进程，免注销生效；要配对、隧道和一个解锁的设备。本机直刷：在 App 内取得壁纸商店容器的沙盒扩展，直接把壁纸写进去，写入不用配对文件、不用隧道；写完按当时的配对、LocalDevVPN、Wi-Fi 三项决定生效方式——齐全就借隧道只重启 PosterBoard、免注销生效，不齐全就只提示「壁纸已写入」并给手动注销按钮，App 不会自动注销。AirLift 直刷：通过隧道写进同一个容器，刷完注销、不重启。恢复式：把壁纸编进一份在手机外合成的系统备份再恢复写回，覆盖全部受支持系统，刷完重启。视频壁纸和重置商店只能走恢复式。")
                        DriftFactRow(title: "两类前提",
                                     text: "本机直刷只看两样：App 自身的系统版本在范围内，且签名授予了一个能打开的 App Group。它不看配对、隧道、Wi-Fi。直刷免注销与 AirLift 是隧道方式：必须已配对、隧道连通，并且真读到设备的系统版本＋构建号；读不到设备身份时两者一律不可用并写明原因，不会拿 App 自己的版本冒充。")
                        DriftFactRow(title: "系统范围",
                                     text: "直刷免注销：iOS 26.0–27.1 及 iOS 27.2 测试版 1/2（按构建号 24B5084k、24B5089g 判断），测试版 3 起关闭，需要配对。AirLift：iOS 26.2–27.1 及 27.2 测试版 1/2，需要配对。本机直刷：iOS 26.0–26.7.2、27.0–27.2，且签名要授予可用的 App Group。27.3 以上三种直刷都不可用。App 会逐档判断并写明理由；刷入前还会再复检一次。")
                        DriftFactRow(title: "旧格式转换",
                                     text: LegacyConversionCopy.why + LegacyConversionCopy.versions)
                        DriftFactRow(title: "隧道",
                                     text: "借 LocalDevVPN（或同类隧道 App）建立：地址固定用默认值（本机 10.7.1.1、对端 10.7.0.1、端口 62078），在 LocalDevVPN 里填同样的值即可，需 Wi-Fi；隧道状态实时检测，App 打开之后再连上隧道也会自动识别并连接，不用重开 App。配对与隧道只是直刷免注销和 AirLift 的前提，本机直刷不需要。")
                        DriftFactRow(title: "签名",
                                     text: "Apple ID 免费签和付费证书都能用，功能无差别——唯一例外是本机直刷，它需要签名授予可用的 App Group。App 会在运行时读取安装包签名里实际授予的组名单，用第一个能打开的组：付费证书的哈希组名、开发者后台注册的组、SideStore / AltStore 改签后的组都可以；免费 Apple ID 直签拿不到 App Group，此时其他方式不受影响。免费签 7 天过期、重装会丢 App 内数据（配对和已导入的包要重新导入）；付费证书有效期长、更稳定。本 App 没有自己的隧道扩展，用不上付费证书的 VPN 权限。")
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
            rangeRow("26.0 – 26.1", "直刷免注销 / 本机直刷*", "免注销 / 见注")
            rangeRow("26.2 – 27.1", "直刷免注销 / AirLift / 本机直刷*", "免注销 / 注销 / 见注")
            rangeRow("27.2 测试版 1 / 2", "直刷免注销 / AirLift / 本机直刷*", "免注销 / 注销 / 见注")
            rangeRow("27.2（测试版 3 起）", "本机直刷*", "见注")
            rangeRow("27.3 以上", DriftRestoreGate.isEnabled ? "仅恢复式" : "仅恢复式（停用中）", "重启")
            Text("* 本机直刷要求签名授予可用的 App Group（运行时发现，不再写死组名）；没有可用组时这一档没有可用的直刷方式。它的生效方式由写完当时决定：配对、LocalDevVPN、Wi-Fi 齐全就免注销，否则只提示并可手动注销。")
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
