import Photos
import SwiftUI
import UIKit

/// The About page (Grace, 2026-11-13, #295 + #297 merged): reached from
/// the「关于此 App」row pinned at the very top of Settings, it gathers
/// in one place who made Drift and how to reach them — the author and
/// the GitHub links (#295), the QQ group card (#297), and the reward
/// code (moved here from the end of the 说明 page, where #271 first
/// put it; the 说明 page keeps its version table only). The credit
/// line for the tunnel core used to live in a small About section at
/// the bottom of Settings; it moved here with everything else, and
/// that section is gone.
///
/// Two fixes from Grace's 3.1.0 walk-through (2026-11-13): the header
/// shows the current app icon, not the old `Logo` artwork `NativeLogo`
/// still loads — the `AboutIcon` catalog set carries the redrawn
/// masters and follows the colour scheme, light artwork in light
/// mode, the black-backed one in dark mode (#298); and the author
/// card opens straight with its one bold「作者」row — the card used
/// to repeat the word as a section header above the row (#299).
struct AboutAppView: View {
    @State private var showRewardLarge = false
    @State private var showQQCardLarge = false

    var body: some View {
        ZStack {
            DriftBackground()
            ScrollView {
                VStack(spacing: 14) {
                    header
                    authorCard
                    qqCard
                    rewardCard
                    creditCard
                    Text("Drift 由 soci-art 制作")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(16)
                .driftPageWidth()
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showRewardLarge) {
            CodeImageLargeView(image: Self.rewardImage, title: "赞赏码",
                               logLine: "关于页：把赞赏码存到相册",
                               helpText: "存好后打开微信扫一扫，选相册里的这张图就能识别。")
        }
        .sheet(isPresented: $showQQCardLarge) {
            CodeImageLargeView(image: Self.qqCardImage, title: "QQ 群",
                               logLine: "关于页：把 QQ 群卡片存到相册",
                               helpText: "存好后打开 QQ 扫一扫，选相册里的这张图就能识别。")
        }
        .onAppear { AppLog.op("打开关于页") }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            // The current app icon (#298), not `NativeLogo`'s old
            // `Logo@1x/@2x` artwork: the catalog set swaps light/dark
            // with the colour scheme on its own. The masters fill
            // their square edge to edge, so the clip gives the
            // home-screen corner.
            Image("AboutIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 84 * 0.22,
                                            style: .continuous))
            Text("Drift").font(.title3.weight(.bold))
            Text("版本 \(Self.versionText)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private static var versionText: String { AppVersion.display }

    // MARK: - Author (#295)

    private var authorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // One「作者」only (#299): the bold row label below is the
            // card's heading and its first row in one.
            HStack {
                Text("作者").fontWeight(.bold)
                Spacer()
                Text("soci-art").foregroundStyle(.secondary)
            }
            Divider()
            Link(destination: URL(string: "https://github.com/soci-art")!) {
                HStack {
                    Text("GitHub 主页").foregroundStyle(.tint)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            Link(destination: URL(string: "https://github.com/soci-art/Drift")!) {
                HStack {
                    Text("Drift 仓库").foregroundStyle(.tint)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    // MARK: - QQ group (#297)

    /// Grace's QQ group card, cropped by her from the group's own
    /// share image (group CocoWall内测群, 1131521407) — the card face
    /// is hers and is shown exactly as supplied. Like the reward code
    /// it opens large with a save-to-photos action: a phone cannot
    /// scan its own screen.
    private var qqCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("QQ 群").font(.subheadline.weight(.semibold))
            Text("喜欢 Drift？扫码加入 QQ 群，一起聊壁纸、报问题。")
                .font(.subheadline)
            if let image = Self.qqCardImage {
                Button { showQQCardLarge = true } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Text("点卡片可以看大图、存进相册，再用 QQ 扫码。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    // #315: decoded once into a static let — as computed statics
    // these two images were re-decoded from disk on every render.
    private static func bundledImage(_ name: String, _ ext: String) -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext)
        else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    static let qqCardImage: UIImage? = bundledImage("QQGroupCard", "png")

    // MARK: - Reward code (#271, moved from the 说明 page)

    private var rewardCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("赞赏").font(.subheadline.weight(.semibold))
            Text("这个 App 免费使用。如果它帮到了你，欢迎打赏支持。")
                .font(.subheadline)
            if let image = Self.rewardImage {
                Button { showRewardLarge = true } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Text("点图片可以看大图、存进相册，再去微信里识别。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    static let rewardImage: UIImage? = bundledImage("RewardCode", "jpg")

    // MARK: - Credit

    /// The tunnel core's credit, carried over word for word from the
    /// Settings About section this page replaces (the same text also
    /// lives in the repo-root NOTICE).
    private var creditCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("来源").font(.subheadline.weight(.semibold))
            Text("独立应用，只保留刷壁纸功能。设备写入核心源自 AirCard-iOS（Mak5er 著，MIT 许可证）的隧道写入核心（回环隧道、配对、同步写入、注入）；免注销生效、商店枚举与本机直刷通道、界面为 Drift 自有部分（AGPL-3.0）。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }
}

/// One code/card image, large: as big as the screen allows, plus the
/// one action that makes it usable — saving it to the photo library,
/// so the owning app (WeChat / QQ) can recognise it from the album;
/// the phone cannot scan its own screen. Shared by the reward code
/// and the QQ group card.
private struct CodeImageLargeView: View {
    let image: UIImage?
    let title: String
    let logLine: String
    let helpText: String

    @Environment(\.dismiss) private var dismiss
    @State private var savedNote: String?
    @State private var showSaved = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let image {
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
                }
                .driftGlassProminentButton()
                Text(helpText)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(20)
            .navigationTitle(title)
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
        guard let image else { return }
        AppLog.op(logLine)
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
