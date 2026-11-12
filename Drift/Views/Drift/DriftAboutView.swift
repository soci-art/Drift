import Photos
import SwiftUI
import UIKit

/// The About page: what Drift does, which systems it covers, how each
/// delivery route behaves, and every risk the feature list says must be
/// written down rather than engineered around. Static text on purpose —
/// it has to read the same offline, unpaired and mid-failure.
///
/// Collection #270 (Grace, 2026-11-13) cut the page down to the sealed
/// restore row, the version table and the reward code (#271) — nothing
/// else is left below the table.
struct DriftAboutView: View {
    @State private var showRewardLarge = false

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
                        // are gone — the page ends with the table and
                        // the reward code below. (The AirCard-iOS/MIT
                        // attribution also lives in the repo-root
                        // NOTICE and in Settings' About section, so
                        // deleting the 「基于」 row loses nothing.)
                        rewardCard
                    }
                    .padding(16)
                }
            }
            .navigationTitle("说明")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showRewardLarge) {
                RewardCodeView()
            }
            .onAppear { AppLog.op("打开说明页") }
        }
    }

    /// Collection #271 (Grace, 2026-11-13): her WeChat reward code,
    /// after the version table — users asked to tip, so the code sits
    /// at the very end of the page. Tapping opens it large: a code on
    /// the user's own screen cannot be scanned by that same phone, so
    /// the large view can save it to the photo library for WeChat to
    /// recognise from the album.
    private var rewardCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("赞赏码").font(.subheadline.weight(.semibold))
            if let image = Self.rewardImage {
                Button { showRewardLarge = true } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Text("点开看大图，可以存到相册，再用微信扫一扫识别。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    static var rewardImage: UIImage? {
        guard let url = Bundle.main.url(forResource: "RewardCode", withExtension: "jpg")
        else { return nil }
        return UIImage(contentsOfFile: url.path)
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

/// The reward code, large (#271): the image as big as the screen
/// allows, plus the one action that makes it usable — saving it to
/// the photo library, so WeChat can recognise the code from the album
/// (the phone cannot scan its own screen).
private struct RewardCodeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var savedNote: String?
    @State private var showSaved = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let image = DriftAboutView.rewardImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                Button {
                    saveToPhotos()
                } label: {
                    Label("存到相册", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                Text("存好后打开微信扫一扫，选相册里的这张图就能识别。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(20)
            .navigationTitle("赞赏码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .driftActionSheet(isPresented: $showSaved, title: savedNote ?? "",
                              actions: [DriftSheetAction("知道了") {}])
        }
    }

    private func saveToPhotos() {
        guard let image = DriftAboutView.rewardImage else { return }
        AppLog.op("说明页：把赞赏码存到相册")
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        } completionHandler: { ok, _ in
            DispatchQueue.main.async {
                savedNote = ok ? "已存到相册" : "没存成，去系统设置里给 Drift 相册权限再试。"
                showSaved = true
            }
        }
    }
}
