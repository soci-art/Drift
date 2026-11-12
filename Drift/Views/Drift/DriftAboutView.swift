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
                                     text: "自动选择：替你在三条通道里挑第一条可用的，并写明选了哪条。免注销直刷：隧道写入，只重启 PosterBoard，刷完即生效。注销直刷：隧道写入，注销后生效。本机直刷：在 App 内直接写入，不用配对、不用隧道，刷完上滑关闭 PosterBoard 生效。三条通道互相独立，一条不行不会自动改走另一条。")
                        DriftFactRow(title: "要用到的条件",
                                     text: "本机直刷看两样：系统版本在范围内、证书签名带能打开的组（免费 ID 签都给不了组）。隧道两条要配对、隧道连通、读到设备真实的系统版本；读不到就不可用，不拿 App 自己的版本冒充。")
                        DriftFactRow(title: "核验",
                                     text: "写完会再查一遍商店：在册才报「完成」；没查到只说「已写入、未确认显示」。本机直刷每次写入都留回执，可在设置里按回执删除。")
                        DriftFactRow(title: "旧格式转换",
                                     text: LegacyConversionCopy.why + LegacyConversionCopy.versions)
                        DriftFactRow(title: "隧道",
                                     text: "隧道借 LocalDevVPN 建立（本机 10.7.1.1、对端 10.7.0.1、端口 62078，需 Wi-Fi）。只有走隧道两条才需要配对和隧道，本机直刷不用。App 开着时连上隧道会自动识别，不用重开 App。")
                        DriftFactRow(title: "签名",
                                     text: "免费签和证书签都能装、都能用隧道两条；只有本机直刷挑签名，要证书签（见「要用到的条件」）。免费签 7 天过期，重装会丢 App 里存的东西，配对和包要重新来。本 App 没有自己的隧道扩展。")
                        DriftFactRow(title: "注意事项",
                                     text: "刷入时保持解锁、别断隧道；中断可能留下刷一半的状态。位置不对只会不显示，不会报错。一次最多刷 10 张。壁纸包请自备，本 App 没有下载功能。纯动画的包在列表里用占位图显示。")
                        DriftFactRow(title: "基于",
                                     text: "Drift 是独立应用。设备写入核心源自 AirCard-iOS（Mak5er，MIT 许可证）；免注销生效、商店枚举、本机直刷与界面为 Drift 自有部分（AGPL-3.0）。")
                    }
                    .padding(16)
                }
            }
            .navigationTitle("说明")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    /// The coverage table (collection #237, Grace 2026-11-12: a real table
    /// instead of pill rows — one row per system band, one column per
    /// channel, ✓ usable / — not usable). Version names follow the
    /// full-form rule (#229/#241): 正式版 / beta x written out, and the
    /// iOS 27.2 正式版 row that the pill list never had is here — the
    /// tunnel gates are build-based, so that band is local-only.
    private var rangeTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("版本对照").font(.subheadline.weight(.semibold))
            tableHeader
            Divider()
            ForEach(Array(Self.tableRows.enumerated()), id: \.offset) { _, row in
                tableRow(row)
                if row.version != Self.tableRows.last?.version { Divider() }
            }
            Text("✓ = 能用，— = 用不了。本机直刷还要证书签名带能用的组；没有能用的组，本机直刷这一列就全是 —。")
                .font(.caption).foregroundStyle(.secondary)
            Text("刷完怎么生效：免注销直刷直接生效；注销直刷要注销一次；本机直刷要把壁纸界面从后台划掉。")
                .font(.caption).foregroundStyle(.secondary)
            Text(DriftRestoreGate.isEnabled
                 ? "视频壁纸在任何版本都只能走恢复刷。"
                 : "视频壁纸在任何版本都只能走恢复刷，恢复刷封存期间暂时刷不了。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    private struct TableRow {
        let version: String
        let noRespring: Bool
        let respring: Bool
        let local: Bool
        var experimental: Bool = false
    }

    private static let tableRows: [TableRow] = [
        TableRow(version: "iOS 17.0 – 18.x", noRespring: true, respring: true, local: false),
        TableRow(version: "iOS 26.0 – 26.1 正式版", noRespring: false, respring: false, local: true),
        TableRow(version: "iOS 26.2 – 27.1 正式版", noRespring: true, respring: true, local: true),
        TableRow(version: "iOS 27.2 beta 1 / beta 2", noRespring: true, respring: true, local: true),
        TableRow(version: "iOS 27.2 beta 3 起", noRespring: false, respring: false, local: true),
        TableRow(version: "iOS 27.2 正式版", noRespring: false, respring: false, local: true),
        TableRow(version: "iOS 27.2.1 正式版", noRespring: false, respring: false, local: true),
        TableRow(version: "iOS 27.3 beta 1", noRespring: false, respring: false, local: true, experimental: true),
        TableRow(version: "iOS 27.3 起", noRespring: false, respring: false, local: false),
    ]

    private var tableHeader: some View {
        HStack(spacing: 4) {
            Text("系统版本").frame(maxWidth: .infinity, alignment: .leading)
            Text("免注销直刷").frame(width: 62)
            Text("注销直刷").frame(width: 62)
            Text("本机直刷").frame(width: 62)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func tableRow(_ row: TableRow) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 5) {
                Text(row.version).font(.subheadline)
                if row.experimental {
                    Text("实验")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.16),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            mark(row.noRespring).frame(width: 62)
            mark(row.respring).frame(width: 62)
            mark(row.local).frame(width: 62)
        }
    }

    private func mark(_ usable: Bool) -> some View {
        Text(usable ? "✓" : "—")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(usable ? Color.green : Color.secondary.opacity(0.55))
    }
}
