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
                            DriftFactRow(title: "恢复刷已封存",
                                         text: "2026-11-10，一次恢复刷入在设备重启后把手机恢复了出厂设置，数据全部丢失。查清原因、并在备用机上验证「从设备拉到真备份」之前，恢复刷不开放：入口保留，但没有任何可执行的恢复代码。只能走恢复刷的内容（视频壁纸、重置商店、带数据库的容器包）暂时都刷不了；免注销直刷不受影响。")
                        }
                        rangeTable
                        DriftFactRow(title: "两种刷入方式",
                                     text: "免注销直刷：唯一在工作的刷入方式。它内部按系统版本选写入通道——26.0–26.1 与 27.2 测试版 3 起走本机通道（在 App 内直接写进壁纸商店容器，写入不用配对、不用隧道）；26.2–27.1 与 27.2 测试版 1/2 走隧道通道（配对隧道写入）。重叠的版本段两个通道都行，哪个前提齐全用哪个。生效统一：写完时隧道在，就只重启 PosterBoard 守护进程、免注销生效；隧道不在，就只提示「壁纸已写入」并给手动注销按钮，App 永远不自动注销。恢复刷：把壁纸编进系统备份再恢复写回的方式，已封存（见上），没有任何可执行代码。")
                        DriftFactRow(title: "两类前提",
                                     text: "本机通道只看两样：App 自身的系统版本在范围内，且签名授予了一个能打开的 App Group。它不看配对、隧道、Wi-Fi。隧道通道必须已配对、隧道连通，并且真读到设备的系统版本＋构建号；读不到设备身份时一律不可用并写明原因，不会拿 App 自己的版本冒充。")
                        DriftFactRow(title: "核验",
                                     text: "走隧道通道时，写前会先枚举一遍设备上壁纸商店的实际内容（核对结构版本与目标文件夹），写完再枚举一次，确认刚写的描述符真的在商店里。只有核验在册才报「完成」；没核对上只会说「已写入、未确认显示」。")
                        DriftFactRow(title: "旧格式转换",
                                     text: LegacyConversionCopy.why + LegacyConversionCopy.versions)
                        DriftFactRow(title: "隧道",
                                     text: "借 LocalDevVPN（或同类隧道 App）建立：地址固定用默认值（本机 10.7.1.1、对端 10.7.0.1、端口 62078），在 LocalDevVPN 里填同样的值即可，需 Wi-Fi；隧道状态实时检测，App 打开之后再连上隧道也会自动识别并连接，不用重开 App。配对与隧道只是免注销直刷走隧道通道时的前提，走本机通道不需要。")
                        DriftFactRow(title: "签名",
                                     text: "Apple ID 免费签和付费证书都能用，功能无差别——唯一例外是本机通道，它需要签名授予可用的 App Group。App 会在运行时读取安装包签名里实际授予的组名单，用第一个能打开的组：付费证书的哈希组名、开发者后台注册的组、SideStore / AltStore 改签后的组都可以；免费 Apple ID 直签拿不到 App Group，此时其他方式不受影响。免费签 7 天过期、重装会丢 App 内数据（配对和已导入的包要重新导入）；付费证书有效期长、更稳定。本 App 没有自己的隧道扩展，用不上付费证书的 VPN 权限。")
                        DriftFactRow(title: "风险与边界",
                                     text: "刷入时请保持解锁、隧道开着、配对有效；中途断开可能留下刷一半的状态。出现位置选错不报错、只是不显示。带数据库的容器包可能弄乱壁纸索引，清乱了用「重置壁纸商店」。刷入和清理全程不从设备拉取备份：壁纸数据库用本地缓存的副本，没有缓存时从零新建，设备上原有的壁纸可能不再被列出；恢复刷封存后，设置里不再有任何恢复备份入口。一次最多刷 10 张。本 App 没有下载功能，壁纸包请自备。纯动画的包没有静态图，列表里用占位图显示。")
                        DriftFactRow(title: "基于",
                                     text: "Drift 是独立应用，只保留刷壁纸功能。2.0.0 起，设备写入核心与 CocoWall 共用同一套：源自 AirCard-iOS（Mak5er 著，MIT 许可证）的隧道写入核心（回环隧道、配对、同步写入、注入），加上 CocoWall 作者在该核心之上写的免注销生效（只重启 PosterBoard）与壁纸商店枚举模块；本机写入通道与界面为 Drift 自有部分（AGPL-3.0）。")
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
            rangeRow("26.0 – 26.1", "免注销直刷 · 本机通道*", "免注销或提示后手动注销")
            rangeRow("26.2 – 27.1", "免注销直刷 · 隧道/本机通道", "免注销")
            rangeRow("27.2 测试版 1 / 2", "免注销直刷 · 隧道/本机通道", "免注销")
            rangeRow("27.2（测试版 3 起）", "免注销直刷 · 本机通道*", "免注销或提示后手动注销")
            rangeRow("27.3 测试版 1", "免注销直刷 · 本机通道*（实验）", "免注销或提示后手动注销")
            rangeRow("27.3 起", "无可用通道", "—")
            Text("* 本机通道要求签名授予可用的 App Group（运行时发现，不再写死组名）；没有可用组时这一档没有可用的通道。它的生效方式由写完当时决定：配对、LocalDevVPN、Wi-Fi 齐全就免注销，否则只提示并可手动注销。27.3 测试版 1 的本机通道只在上游声明里出现过、未经真机验证，按实验对待。")
                .font(.caption).foregroundStyle(.secondary)
            Text(DriftRestoreGate.isEnabled
                 ? "视频壁纸在任何版本都只能走恢复刷。"
                 : "视频壁纸在任何版本都只能走恢复刷，恢复刷封存期间暂时刷不了。")
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
