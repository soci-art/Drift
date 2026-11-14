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
                if row.version != Self.tableRows.last?.version { Divider() }
            }
            Text("✓ = 能用，— = 用不了。本机直刷还要证书签名带能用的组；没有能用的组，本机直刷这一列就全是 —。")
                .font(.caption).foregroundStyle(.secondary)
            Text("内核直刷是实验功能，要先在「设置 → 实验性功能」里打开；只支持 iOS 17.0–17.7 和 iOS 18.0–18.7.1，机型也要在支持表里。")
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
        var kernel: Bool = false
    }

    private static let tableRows: [TableRow] = [
        // #314 (Grace, 2026-11-13): the 17 band lost its tunnel
        // ticks — its system refuses the container lookup (see
        // DriftSession) — and 18 keeps its own row. #329
        // (2026-11-14): the kernel column joins — it is the 17
        // band's only tick and shares the 18 band with the tunnels;
        // its finer limits (17.7 / 18.7.1 caps, the model table)
        // live in the footnote under the table.
        TableRow(version: "iOS 17.0 – 17.x", noRespring: false, respring: false, local: false, kernel: true),
        TableRow(version: "iOS 18.0 – 18.x", noRespring: true, respring: true, local: false, kernel: true),
        TableRow(version: "iOS 26.0 – 26.1 正式版", noRespring: false, respring: false, local: true),
        TableRow(version: "iOS 26.2 – 27.1 正式版", noRespring: true, respring: true, local: true),
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
            Text("免注销直刷").frame(width: 56).minimumScaleFactor(0.85).lineLimit(1)
            Text("注销直刷").frame(width: 56).minimumScaleFactor(0.85).lineLimit(1)
            Text("本机直刷").frame(width: 56).minimumScaleFactor(0.85).lineLimit(1)
            Text("内核直刷").frame(width: 56).minimumScaleFactor(0.85).lineLimit(1)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func tableRow(_ row: TableRow) -> some View {
        HStack(spacing: 4) {
            Text(row.version).font(.subheadline)
                .minimumScaleFactor(0.8).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            mark(row.noRespring).frame(width: 56)
            mark(row.respring).frame(width: 56)
            mark(row.local).frame(width: 56)
            mark(row.kernel).frame(width: 56)
        }
    }

    private func mark(_ usable: Bool) -> some View {
        Text(usable ? "✓" : "—")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(usable ? Color.green : Color.secondary.opacity(0.55))
    }
}
