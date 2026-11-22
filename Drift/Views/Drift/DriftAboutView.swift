import Photos
import SwiftUI
import UIKit

/// The About page: what Drift does, which systems it covers, how each
/// delivery route behaves, and every risk the feature list says must be
/// written down rather than engineered around. Static text on purpose —
/// it has to read the same offline, unpaired and mid-failure.
///
/// Collection #270 (Grace, 2026-11-13) cut the page down to the sealed
/// restore row and the version table — nothing else is left below the
/// table. (The reward code that once ended the page lives on the
/// About page now; see AboutAppView.)
struct DriftAboutView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                DriftBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        rangeTable
                        // Collection #270 (Grace, 2026-11-13): the
                        // eight fact rows that used to follow the table
                        // are gone — the page ends with the table.
                        // The reward code that #271 put below it moved
                        // to the About page (AboutAppView) with the
                        // #295/#297 merge, and the AirCard-iOS/MIT
                        // attribution lives there and in the repo-root
                        // NOTICE.
                    }
                    .padding(16)
                    .driftPageWidth()
                }
            }
            .navigationTitle("说明")
            .navigationBarTitleDisplayMode(.large)
            .onAppear { AppLog.op("打开说明页") }
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
            Text("✓ = 能用，— = 用不了。iOS 26.0 – 26.6.1 有证书、没证书都能用：带着能用的组就走用组的那条路，没有组就走不用组的那条路。其余系统要证书签名带能用的组，没有能用的组就用不了。")
                .font(.caption).foregroundStyle(.secondary)
            Text("iOS 18.7.2 起，内核直刷用不了，只能走两条隧道通道。")
                .font(.caption).foregroundStyle(.secondary)
            Text("内核直刷只支持 iOS 17.0–17.7.x 和 iOS 18.0–18.7.1，机型也要在支持表里；没有开关，选了就能用。")
                .font(.caption).foregroundStyle(.secondary)
            Text("恢复刷只认 iOS 27，不要求证书、免费 ID 签名也能用；刷之前要先整机备份、关掉「查找」，详细步骤看「使用教程 → 恢复刷」。iOS 27.3 beta 2 起别的通道都用不了，只能走恢复刷。")
                .font(.caption).foregroundStyle(.secondary)
            Text("刷完怎么生效：免注销直刷直接生效；注销直刷要注销一次；本机直刷、内核直刷要把壁纸界面从后台划掉；恢复刷要重启一次，走完设置流程后生效。")
                .font(.caption).foregroundStyle(.secondary)
            Text("视频壁纸可以走任意一条通道：在主页选哪种刷入方式，就走哪种；走恢复刷时，先在视频页解码，再选已解码的视频刷入。")
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
        var localNoCert: Bool = false
        var kernel: Bool = false
        /// The restore column (Grace, 2026-11-22): the route opened
        /// on the formal line as a regular feature, iOS 27 only.
        var restore: Bool = false
    }

    private static let tableRows: [TableRow] = [
        // #314 (Grace, 2026-11-13): the 17 band lost its tunnel
        // ticks — its system refuses the container lookup (see
        // DriftSession) — and 18 keeps its own row. #329
        // (2026-11-14): the kernel column joins — it is the 17
        // band's only tick and shares the 18 band with the tunnels.
        // #331 (Grace, 2026-11-14): the bands are spelled out at
        // the kernel gate's own granularity — 17 ends at 17.7 and
        // 18 splits at 18.7.1, past which the kernel gate closes
        // even though the offset table would reach; 18.7.2+ keeps
        // only its tunnel ticks. The model table stays in the
        // footnote under the table.
        // Finer wording (Grace, 2026-11-16): no vague 「18.x」 —
        // the 17 row spells its patch tail (the whole iOS 17 line
        // ends inside 17.7.x) and the post-gate 18 row reads
        // 「18.7.2 起」, with a footnote under the table saying
        // outright that the kernel method is closed there.
        TableRow(version: "iOS 17.0 – 17.7.x", noRespring: false, respring: false, local: false, kernel: true),
        TableRow(version: "iOS 18.0 – 18.7.1", noRespring: true, respring: true, local: false, kernel: true),
        TableRow(version: "iOS 18.7.2 起", noRespring: true, respring: true, local: false, kernel: false),
        // 26 splits at 26.6.1 (Grace, 2026-11-17): bad_query below —
        // the only row with a localNoCert tick — worse_query above.
        TableRow(version: "iOS 26.0 – 26.6.1 正式版", noRespring: false, respring: false, local: true, localNoCert: true),
        TableRow(version: "iOS 26.7 – 26.7.2 正式版", noRespring: true, respring: true, local: true),
        TableRow(version: "iOS 27.0 – 27.2.1 正式版", noRespring: true, respring: true, local: true, restore: true),
        TableRow(version: "iOS 27.2 beta 1 / beta 2", noRespring: true, respring: true, local: true, restore: true),
        TableRow(version: "iOS 27.2 beta 3 起", noRespring: false, respring: false, local: true, restore: true),
        TableRow(version: "iOS 27.2.0 正式版", noRespring: false, respring: false, local: true, restore: true),
        TableRow(version: "iOS 27.2.1 正式版", noRespring: false, respring: false, local: true, restore: true),
        TableRow(version: "iOS 27.3 beta 1", noRespring: false, respring: false, local: true, restore: true),
        TableRow(version: "iOS 27.3 beta 2 起", noRespring: false, respring: false, local: false, restore: true),
    ]

    /// Column widths are sized for the narrowest supported phones
    /// (375pt across): at the old 47pt the seven columns plus the
    /// version column overflowed the card there and the 恢复刷 column
    /// fell off the right edge — the page read as if restore had
    /// never been added (Grace's field report, 2026-11-22). At 41pt
    /// and 2pt spacing the whole table fits with room to spare for
    /// the version names.
    private var tableHeader: some View {
        HStack(spacing: 2) {
            Text("系统版本").frame(maxWidth: .infinity, alignment: .leading)
            Text("免注销直刷").frame(width: 41).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text("注销直刷").frame(width: 41).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            // #333 (Grace, 2026-11-14): the local column must say up
            // front that it needs a certificate, not only in the
            // footnote under the table.
            VStack(spacing: 0) {
                Text("本机直刷").lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text("需证书").font(.caption2.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true).foregroundStyle(.orange)
            }.frame(width: 41)
            VStack(spacing: 0) {
                Text("本机直刷").minimumScaleFactor(0.85).lineLimit(1)
                Text("无需证书").font(.caption2.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true).foregroundStyle(.green)
            }.frame(width: 41)
            Text("内核直刷").frame(width: 41).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                Text("恢复刷").lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text("新").font(.caption2.weight(.semibold)).lineLimit(1).foregroundStyle(.red)
            }.frame(width: 41)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func tableRow(_ row: TableRow) -> some View {
        HStack(spacing: 2) {
            Text(row.version).font(.subheadline)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            mark(row.noRespring).frame(width: 41)
            mark(row.respring).frame(width: 41)
            mark(row.local).frame(width: 41)
            mark(row.localNoCert).frame(width: 41)
            mark(row.kernel).frame(width: 41)
            mark(row.restore).frame(width: 41)
        }
    }

    private func mark(_ usable: Bool) -> some View {
        Text(usable ? "✓" : "—")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(usable ? Color.green : Color.secondary.opacity(0.55))
    }
}
