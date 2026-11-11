import SwiftUI
import UIKit

/// The in-app update announcement (#178), presented as a proper
/// announcement page (#192): app icon, title, version and date in the
/// header; one titled entry per change; a single 确定 button.
struct AppAnnouncementView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                appIcon
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppAnnouncement.title)
                        .font(.title3.weight(.bold))
                    Text(AppAnnouncement.versionLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 18)

            Divider()

            VStack(spacing: 0) {
                ForEach(AppAnnouncement.items, id: \.title) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.body)
                            .foregroundStyle(.tint)
                            .frame(width: 38, height: 38)
                            .background(Color.accentColor.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.headline)
                            Text(item.body)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 13)
                    if item.title != AppAnnouncement.items.last?.title {
                        Divider()
                    }
                }
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Text("确定")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    /// The real app icon from the bundle when it can be read; a plain
    /// initial tile otherwise.
    @ViewBuilder
    private var appIcon: some View {
        if let icon = Self.bundleIcon {
            Image(uiImage: icon)
                .resizable()
                .scaledToFit()
        } else {
            ZStack {
                LinearGradient(colors: [.cyan, .blue],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text("D").font(.largeTitle.weight(.bold)).foregroundStyle(.white)
            }
        }
    }

    private static var bundleIcon: UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last else { return nil }
        return UIImage(named: name)
    }
}
