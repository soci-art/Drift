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
                        // Feedback #30: the suspension is stated first,
                        // before any row that describes the restore route
                        // as a way to flash — nothing below may read as
                        // "restore is available" while the gate is closed.
                        if !DriftRestoreGate.isEnabled {
                            DriftFactRow(title: "恢复刷已封存",
                                         text: DriftRestoreGate.notice)
                        }
                        rangeTable
                        DriftFactRow(title: "四种刷入方式",
                                     text: "自动选择：不是一条通道，是替你挑通道的。按条件在三条通道里挑第一条可用的，并在卡上写明这次选了哪条。免注销直刷：一次隧道事务里把描述符和刷新偏好一起写完，然后只重启 PosterBoard，刷完即生效、不用注销。注销直刷：隧道逐张写入描述符，写完统一注销生效。本机直刷（实验）：在 App 内直接写进商店容器，不用配对、不用隧道，刷完提示你上滑关闭 PosterBoard。三条通道彼此独立：一条不可用只会写明原因，不会自动改走另一条；只有自动选择会在三条之间挑。恢复刷：编进系统备份再恢复写回，已封存（见上），没有任何可执行代码。")
                        DriftFactRow(title: "要用到的条件",
                                     text: "本机直刷只看两样：App 自身的系统版本（含构建号）在范围内，且是付费证书签名、带一个能打开的 App Group（免费 ID 签和 SideStore / AltStore 改签都给不了）。它不看配对、隧道、Wi-Fi。两条隧道通道必须已配对、隧道连通，并且真读到设备的系统版本＋构建号；读不到设备身份时一律不可用并写明原因，不会拿 App 自己的版本冒充。")
                        DriftFactRow(title: "核验",
                                     text: "走隧道通道时，写前会先枚举一遍设备上壁纸商店的实际内容（核对结构版本与目标文件夹），写完再枚举一次；本机直刷写完直接枚举本地商店目录。只有核验在册才报「完成」；没核对上只会说「已写入、未确认显示」。本机直刷还会给每条写入留下回执，可在设置里按回执删除并复核。")
                        DriftFactRow(title: "旧格式转换",
                                     text: LegacyConversionCopy.why + LegacyConversionCopy.versions)
                        DriftFactRow(title: "隧道",
                                     text: "借 LocalDevVPN（或同类隧道 App）建立：地址固定用默认值（本机 10.7.1.1、对端 10.7.0.1、端口 62078），在 LocalDevVPN 里填同样的值即可，需 Wi-Fi；隧道状态实时检测，App 打开之后再连上隧道也会自动识别并连接，不用重开 App。配对与隧道只是走两条隧道通道才需要的，走本机直刷不需要。")
                        DriftFactRow(title: "签名",
                                     text: "Apple ID 免费签和付费证书都能装、都能用两条隧道通道，功能无差别——唯一例外是本机直刷：它要用到签名里的 App Group，实际上只有付费证书的签名才带能打开的组（App 会在运行时读取签名实际给的组名单，用第一个能打开的）。免费 Apple ID 直签给不了组，SideStore / AltStore 这类改签也给不了，所以这两种装法用不了本机直刷，其他方式不受影响。免费签 7 天过期、重装会丢 App 内数据（配对和已导入的包要重新导入）；付费证书有效期长、更稳定。本 App 没有自己的隧道扩展，用不上付费证书的 VPN 权限。")
                        DriftFactRow(title: "风险与边界",
                                     text: "刷入时请保持解锁、隧道开着、配对有效；中途断开可能留下刷一半的状态。出现位置选错不报错、只是不显示。带数据库的容器包可能弄乱壁纸索引。刷入和清理全程不从设备拉取备份：壁纸数据库用本地缓存的副本，没有缓存时从零新建，设备上原有的壁纸可能不再被列出；恢复刷封存后，设置里不再有任何恢复备份入口。一次最多刷 10 张。本 App 没有下载功能，壁纸包请自备。纯动画的包没有静态图，列表里用占位图显示。")
                        DriftFactRow(title: "基于",
                                     text: "Drift 是独立应用，只保留刷壁纸功能。设备写入核心源自 AirCard-iOS（Mak5er 著，MIT 许可证）的隧道写入核心（回环隧道、配对、同步写入、注入）；免注销生效、壁纸商店枚举、本机直刷通道与界面为 Drift 自有部分（AGPL-3.0）。")
                    }
                    .padding(16)
                }
            }
            .navigationTitle("说明")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var rangeTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("版本对照").font(.subheadline.weight(.semibold))
            rangeRow("26.0 – 26.1", "本机直刷*", "上滑关闭 PosterBoard")
            rangeRow("26.2 – 27.1", "免注销直刷 / 注销直刷 / 本机直刷*", "免注销 / 注销 / 上滑关闭")
            rangeRow("27.2 测试版 1 / 2", "免注销直刷 / 注销直刷 / 本机直刷*", "免注销 / 注销 / 上滑关闭")
            rangeRow("27.2 测试版 3 起", "本机直刷*", "上滑关闭 PosterBoard")
            rangeRow("27.2.1", "本机直刷*", "上滑关闭 PosterBoard")
            rangeRow("27.3 测试版 1", "本机直刷*（实验）", "上滑关闭 PosterBoard")
            rangeRow("27.3 起", "无可用通道", "—")
            Text("* 本机直刷要求签名授予可用的 App Group（运行时发现，不再写死组名）；没有可用组时这一档没有可用的通道。它的生效方式固定：刷完打开应用切换器，上滑关闭 PosterBoard，系统重新拉起时生效，App 不做任何自动注销。27.3 测试版 1 只在上游声明里出现过、未经真机验证，按实验对待。")
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
