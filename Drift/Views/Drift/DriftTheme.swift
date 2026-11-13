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
    /// One liquid-glass slab (collection #286): real glass on iOS 26+,
    /// the legacy solid card surface below it — the same split
    /// `driftCard` makes, minus the padding (the caller pads its own
    /// contents; a slab frames a group, not a single card's text).
    ///
    /// Collection #290 (Grace, 2026-11-13): the glass is drawn in the
    /// BACKGROUND, never on the container itself. With the glass on
    /// the container, 3.0.14's Home bars answered only taps that
    /// landed exactly on their text — the container's glass surface
    /// swallowed every other touch inside the frame. A background
    /// layer renders the same and sits outside the hit path entirely.
    @ViewBuilder
    func driftGlassSlab(cornerRadius: CGFloat = 26) -> some View {
        if #available(iOS 26.0, *), !DriftTheme.legacyUI {
            self.background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular,
                                 in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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

    /// A capsule of tinted liquid glass (collection #286) — the Home
    /// bars' surface on iOS 26+; a solid tint capsule below it. Also
    /// background-drawn, for the #290 reason above; the label's own
    /// content shape is the whole capsule, so the whole bar is the
    /// tap target, not just its text.
    @ViewBuilder
    func driftGlassCapsule(tint: Color) -> some View {
        if #available(iOS 26.0, *), !DriftTheme.legacyUI {
            self.background {
                Capsule().fill(.clear)
                    .glassEffect(.regular.tint(tint), in: Capsule())
            }
            .contentShape(Capsule())
        } else {
            self.background(tint, in: Capsule())
        }
    }
}

/// Page background: the colour wash on iOS 26+; the flat grouped
/// background on the legacy systems (#242).
///
/// Collection #274 (Grace, 2026-11-13): in dark mode the page
/// background is PURE BLACK — the blue-green gradient wash is gone.
/// Cards keep whatever surface they already have; only the page
/// behind them changes, on both the glass and legacy paths.
struct DriftBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if scheme == .dark {
            Color.black.ignoresSafeArea()
        } else if DriftTheme.legacyUI {
            Color(.systemGroupedBackground).ignoresSafeArea()
        } else {
            LinearGradient(colors: DriftTheme.washColors(scheme: scheme),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
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
