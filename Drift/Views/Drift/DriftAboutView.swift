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
                        // Feedback #30: the suspension is stated first,
                        // before any row that describes the restore route
                        // as a way to flash — nothing below may read as
                        // "restore is available" while the gate is closed.
                        if !DriftRestoreGate.isEnabled {
                            DriftFactRow(title: "恢复刷已封存",
                                         text: DriftRestoreGate.notice)
                        }
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
                if let note = row.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if row.version != Self.tableRows.last?.version { Divider() }
            }
            Text("✓ = 能用，— = 用不了。iOS 26.0 – 26.6.1 有证书、没证书都能用：带着能用的组就走用组的那条路，没有组就走不用组的那条路。其余系统要证书签名带能用的组，没有能用的组就用不了。")
                .font(.caption).foregroundStyle(.secondary)
            Text("iOS 18.7.2 起，内核直刷用不了，只能走两条隧道通道。")
                .font(.caption).foregroundStyle(.secondary)
            Text("内核直刷是实验功能，要先在「设置 → 实验性功能」里打开；只支持 iOS 17.0–17.7.x 和 iOS 18.0–18.7.1，机型也要在支持表里。")
                .font(.caption).foregroundStyle(.secondary)
            Text("刷完怎么生效：免注销直刷直接生效；注销直刷要注销一次；本机直刷、内核直刷要把壁纸界面从后台划掉。")
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
        var localNoCert: Bool = false
        var kernel: Bool = false
        /// A line of text rendered inside the table, directly under this
        /// row (Grace, 2026-11-18: a key conclusion belongs in the table
        /// itself, not only in the footnotes below it).
        var note: String? = nil
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
        TableRow(version: "iOS 26.0 – 26.1 正式版", noRespring: false, respring: false, local: true, localNoCert: true,
                 note: "这一段证书可有可无：有能用的组走用组的路，没有组走不用组的路。"),
        TableRow(version: "iOS 26.7 – 26.2 正式版", noRespring: true, respring: true, local: true),
        TableRow(version: "iOS 27.0 – 27.2 正式版", noRespring: true, respring: true, local: true),
        TableRow(version: "iOS 27.2 beta 1 / beta 2", noRespring: true, respring: true, local: true),
        TableRow(version: "iOS 27.2 beta 3 起", noRespring: false, respring: false, local: true),
        TableRow(version: "iOS 27.2 正式版", noRespring: false, respring: false, local: true),
        TableRow(version: "iOS 27.2.1 正式版", noRespring: false, respring: false, local: true),
        TableRow(version: "iOS 27.3 beta 1", noRespring: false, respring: false, local: true),
        TableRow(version: "iOS 27.3 起", noRespring: false, respring: false, local: false),
    ]

    private var tableHeader: some View {
        HStack(spacing: 4) {
            Text("系统版本").frame(maxWidth: .infinity, alignment: .leading)
            Text("免注销直刷").frame(width: 47).minimumScaleFactor(0.85).lineLimit(1)
            Text("注销直刷").frame(width: 47).minimumScaleFactor(0.85).lineLimit(1)
            // #333 (Grace, 2026-11-14): the local column must say up
            // front that it needs a certificate, not only in the
            // footnote under the table.
            VStack(spacing: 0) {
                Text("本机直刷").minimumScaleFactor(0.85).lineLimit(1)
                Text("需证书").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
            }.frame(width: 47)
            VStack(spacing: 0) {
                Text("本机直刷").minimumScaleFactor(0.85).lineLimit(1)
                Text("无需证书").font(.caption2.weight(.semibold)).foregroundStyle(.green)
            }.frame(width: 47)
            Text("内核直刷").frame(width: 47).minimumScaleFactor(0.85).lineLimit(1)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func tableRow(_ row: TableRow) -> some View {
        HStack(spacing: 4) {
            Text(row.version).font(.subheadline)
                .minimumScaleFactor(0.8).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            mark(row.noRespring).frame(width: 47)
            mark(row.respring).frame(width: 47)
            mark(row.local).frame(width: 47)
            mark(row.localNoCert).frame(width: 47)
            mark(row.kernel).frame(width: 47)
        }
    }

    private func mark(_ usable: Bool) -> some View {
        Text(usable ? "✓" : "—")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(usable ? Color.green : Color.secondary.opacity(0.55))
    }
}
