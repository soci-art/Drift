import SwiftUI

/// Drift's minimal light-glass look, built entirely from semantic colours
/// and system materials so the same code renders the light design and its
/// dark counterpart — the app follows the system appearance with no
/// in-app switch (the user's call).
enum DriftTheme {
    /// The one page background (collection #304, Grace, 2026-11-13):
    /// a flat pale grey-blue on every page — Home, Settings, every
    /// second-level page; popups and sheets keep their own surfaces.
    /// Her word for it: plain is better. The old gradient wash (and
    /// the legacy path's grouped grey) are gone; dark mode stays pure
    /// black per #274.
    static let pageBackgroundLight = Color(red: 0.914, green: 0.929, blue: 0.949)

    /// The pre–Liquid Glass systems (collection #242, Grace 2026-11-12):
    /// iOS 17/18 have no Liquid Glass, so they get a plain surface
    /// treatment of their own — flat grouped background, solid cards,
    /// an opaque tab bar — instead of the glass look falling back
    /// piecemeal. Layout, wording and function are identical on every
    /// system; only the surface differs, and every surface decision in
    /// the app reads this one flag (the two button styles have their
    /// own matching gate in NativeUI).
    static var legacyUI: Bool {
        !ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }
}

extension View {
    /// A card on the page background: translucent glass over the wash on
    /// iOS 26+, a solid grouped-list card on the legacy systems (#242).
    @ViewBuilder
    func driftCard(cornerRadius: CGFloat = 20) -> some View {
        if DriftTheme.legacyUI {
            self
                .padding(16)
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
        } else {
            self
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        }
    }
}

extension View {
    /// One framed slab (collection #286): the cards' material on
    /// iOS 26+, the legacy solid card surface below it — the same
    /// split `driftCard` makes, minus the padding (the caller pads
    /// its own contents; a slab frames a group, not a single card's
    /// text).
    ///
    /// Collection #290 (Grace, 2026-11-13): the surface is drawn in
    /// the BACKGROUND, never on the container itself. With the glass
    /// on the container, 3.0.14's Home bars answered only taps that
    /// landed exactly on their text — the container's glass surface
    /// swallowed every other touch inside the frame. A background
    /// layer renders the same and sits outside the hit path entirely.
    ///
    /// Collection #302 (Grace, 2026-11-13): the frame's surface is
    /// the SAME material as every card (`driftCard`'s
    /// ultraThinMaterial), not real Liquid Glass — the glass slab
    /// rendered whiter and brighter than the cards above and below
    /// it, with a showier edge, and the page read as two different
    /// materials. One material everywhere now.
    @ViewBuilder
    func driftGlassSlab(cornerRadius: CGFloat = 26) -> some View {
        if #available(iOS 26.0, *), !DriftTheme.legacyUI {
            self.background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    )
            }
        } else {
            self
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
        }
    }

    /// A capsule bar in a flat solid tint — the Home bars' surface.
    /// It was tinted liquid glass (#286); the glass-unification round
    /// (Grace, 2026-11-13, her pick of render ②) made the frame's
    /// insides plain solid fills like every legacy system already
    /// had: the frame keeps the one shared material, the bars are
    /// flat colour. Also background-drawn, for the #290 reason
    /// above; the label's own content shape is the whole capsule,
    /// so the whole bar is the tap target, not just its text.
    func driftGlassCapsule(tint: Color) -> some View {
        self.background(tint, in: Capsule())
            .contentShape(Capsule())
    }
}

extension View {
    /// Keep a page's content readable on iPad without changing phone
    /// layouts: below the cap the frame is unchanged; above it the content
    /// is centred instead of stretching edge to edge.
    func driftPageWidth(_ maxWidth: CGFloat = 720) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

/// Page background: the one flat colour (#304), on the glass and
/// legacy paths alike.
///
/// Collection #274 (Grace, 2026-11-13): in dark mode the page
/// background is PURE BLACK. Cards keep whatever surface they
/// already have; only the page behind them changes.
struct DriftBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if scheme == .dark {
            Color.black.ignoresSafeArea()
        } else {
            DriftTheme.pageBackgroundLight.ignoresSafeArea()
        }
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

/// Left-to-right layout that wraps onto the next line when a row
/// fills (collection #325): the header card's pill groups used
/// `ViewThatFits` with a one-per-line vertical fallback, and the
/// four tunnel pills never fit on a single line, so they always
/// landed stacked one per row. A flow keeps them side by side,
/// wrapping as needed, the way the first group already read.
struct DriftFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                widest = max(widest, x - horizontalSpacing)
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - horizontalSpacing)
        return CGSize(width: min(maxWidth, widest), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
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
