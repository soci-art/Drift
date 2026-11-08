import SwiftUI

/// Drift's minimal light-glass look, built entirely from semantic colours
/// and system materials so the same code renders the light design and its
/// dark counterpart — the app follows the system appearance with no
/// in-app switch (the user's call).
enum DriftTheme {
    /// Faint colour wash behind the pages, echoing the icon's drift bands.
    static func washColors(scheme: ColorScheme) -> [Color] {
        scheme == .dark
            ? [Color(red: 0.10, green: 0.13, blue: 0.22), Color(red: 0.05, green: 0.16, blue: 0.14), Color(red: 0.07, green: 0.07, blue: 0.10)]
            : [Color(red: 0.93, green: 0.95, blue: 1.0), Color(red: 0.90, green: 0.97, blue: 0.94), Color(red: 0.97, green: 0.97, blue: 0.98)]
    }
}

extension View {
    /// A white (or dark) glass card on the wash.
    func driftCard(cornerRadius: CGFloat = 20) -> some View {
        self
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

/// Page background: the colour wash, edge to edge.
struct DriftBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LinearGradient(colors: DriftTheme.washColors(scheme: scheme),
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

/// A small rounded status pill (connection state, mode badges).
struct DriftPill: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// One fact row on the About page: a heading and its text.
struct DriftFactRow: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }
}
