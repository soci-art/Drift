import SwiftUI
import UIKit

// Plain-SwiftUI building blocks for the native screens.
//
// These are deliberately thin.  The screens themselves use `List`/`Form`,
// `Section`, `NavigationLink`, `Toggle`, `TextField`, `LabeledContent` and the
// system button styles directly; only the few repeated bits of custom text and
// the two action buttons live here.  Nothing in this file imitates the desktop
// build, and every value is a Dynamic Type text style or a semantic system
// colour so light and dark, and the user's text size, both work.
//
// The original `Golden*` design-system port — `GoldenComponents.swift` (the
// component library) and `GoldenTheme.swift` (the palette, metrics and type
// scale) — has been deleted as dead code: the native screens never used it, and
// every value it carried now comes from the platform's own styles and semantic
// colours. `GoldenTone` is the one survivor: the status-line tone slot the
// screens still pass around, now resolved through `nativeColor` below.
// `docs/ui-goldennugget.md` keeps the record of where the ported values came
// from, for anyone who wants to re-derive them.

/// A muted explanatory line: secondary, footnote, wraps rather than truncates.
struct NativeNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        // `LocalizedStringKey` rather than `Text(text)`: a `String` parameter is
        // the verbatim initializer, so every note in the app would ship in
        // English regardless of the catalog.  The literal call sites are found
        // by scripts/extract-localizations.py, which keeps Localizable.xcstrings
        // complete even though this initializer hides the key from the compiler.
        Text(LocalizedStringKey(text))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A line that says what an action costs, in the system danger tone.
struct NativeSafetyNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.footnote)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A full-width prominent action, with an inline spinner while running.
///
/// Uses the app's Liquid Glass prominent treatment
/// (`driftGlassProminentButton` — the system glass look without the
/// press swell, #285), so there is no gradient to keep in step with
/// the OS.
struct NativePrimaryButton: View {
    let title: String
    var systemImage: String?
    var running = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if running {
                    ProgressView().controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(LocalizedStringKey(title)).font(.headline)
            }
            .frame(maxWidth: .infinity)
        }
        .driftGlassProminentButton()
        .controlSize(.large)
        .disabled(running || disabled)
    }
}

/// A full-width destructive action, in the system's red prominent treatment.
struct NativeDangerButton: View {
    let title: String
    var systemImage: String?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(LocalizedStringKey(title)).font(.headline)
            }
            .frame(maxWidth: .infinity)
        }
        .driftGlassProminentButton(tint: .red)
        .controlSize(.large)
        .disabled(disabled)
    }
}

/// A tappable list-section header that folds the section's rows away.
///
/// `Section(isExpanded:)` is the platform's own collapsible section, but in the
/// tweaks/daemons `List`s it drew no visible affordance, so the fold was
/// unreachable.  This header draws the chevron itself and toggles the same
/// *collapsed* binding the page already keeps, so the fold state stays where it
/// was and the caller emits the rows only while the section is open.
struct NativeCollapsibleHeader: View {
    let title: String
    @Binding var collapsed: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(LocalizedStringKey(title))
                Spacer(minLength: 0)
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .flipsForRightToLeftLayoutDirection(true)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The app artwork at a chosen size, rounded like the home-screen icon.
///
/// Self-contained on purpose: it loads the same `Logo@1x/@2x` bundle files the
/// ported `GoldenLogo` did, without depending on a component library for it.
struct NativeLogo: View {
    var size: CGFloat = 72

    var body: some View {
        Group {
            if let image = NativeLogo.bundledIcon {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay(
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: size * 0.4))
                            .foregroundStyle(.tint)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }

    /// `Logo@1x/@2x` are the icon artwork under names no icon key can claim, so
    /// loading them by path cannot abort the way `UIImage(named: "AppIcon")` can.
    private static let bundledIcon: UIImage? = {
        if let path = Bundle.main.path(forResource: "Logo@2x", ofType: "png"),
           let image = UIImage(contentsOfFile: path) { return image }
        if let path = Bundle.main.path(forResource: "Logo@1x", ofType: "png"),
           let image = UIImage(contentsOfFile: path) { return image }
        return nil
    }()
}

/// The tone slots the reference has named colors for.
///
/// The named colours themselves are gone with the rest of the design tokens
/// (see `docs/ui-goldennugget.md`): the native screens resolve every tone through
/// `nativeColor` below, which is what light mode, dark mode and the platform's
/// own contrast rules expect.
enum GoldenTone {
    case primary, secondary, disabled, accent, success, error, warning
}

extension GoldenTone {
    /// The same tone slot, in the platform's semantic palette rather than the
    /// desktop build's named colours.
    var nativeColor: Color {
        switch self {
        case .primary: return .primary
        case .secondary: return .secondary
        case .disabled: return Color(.tertiaryLabel)
        case .accent: return .accentColor
        case .success: return .green
        case .error: return .red
        case .warning: return .orange
        }
    }
}

extension View {
    /// Put a "Done" above the keyboard — required for `.numberPad` /
    /// `.decimalPad` fields, which have no Return key of their own.
    func nativeKeyboardDone() -> some View { modifier(NativeKeyboardDone()) }

    /// The app's Liquid Glass button look on iOS 26, with a bordered
    /// fallback below it. One entry point for every call site, so the app can
    /// build and run at a 17.0 deployment target without scattering
    /// `#available` checks through the views.
    ///
    /// Collection #285 (Grace, 2026-11-13): NOT the system's `.glass`
    /// style — that style swells the button up while a finger rests on
    /// it, so merely sliding a finger across a button to scroll the
    /// page made it grow, which she called out on a recording as a
    /// visual disturbance ("都不要再出现放大这个现象"). The look is
    /// kept, drawn by `DriftStaticGlassButtonStyle` below; the growth
    /// is gone, for every button in the app, because every glass
    /// button in the app comes through these two helpers.
    @ViewBuilder
    func driftGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(DriftStaticGlassButtonStyle(prominent: false,
                                                         tint: .accentColor))
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// The prominent variant of `driftGlassButton()`.
    @ViewBuilder
    func driftGlassProminentButton(tint: Color = .accentColor) -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(DriftStaticGlassButtonStyle(prominent: true,
                                                         tint: tint))
        } else {
            self.buttonStyle(.borderedProminent).tint(tint)
        }
    }

    /// Report whether a scroll view is parked at its end.
    ///
    /// `onScrollGeometryChange` is iOS 18; the app still installs on iOS 17.
    /// Below 18 this is a no-op, which leaves the log's follow-tail state at
    /// its default (true) — the reader simply does not get the automatic
    /// "parked away from the end" switch on that one version.
    @ViewBuilder
    func driftOnScrollAtEnd(_ action: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 24
            } action: { _, atEnd in
                action(atEnd)
            }
        } else {
            self
        }
    }
}

/// A "Done" button in a toolbar above the keyboard, resigning through UIKit so
/// one modifier serves every field.
struct NativeKeyboardDone: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { Self.resignFirstResponder() }
            }
        }
    }

    private static func resignFirstResponder() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

/// The Liquid Glass button look WITHOUT the system's swell (#285):
/// the same tinted glass capsule the `.glass` / `.glassProminent`
/// styles draw, but the label is never scaled — a finger resting on
/// the button, or sliding across it on the way to scrolling the page,
/// changes nothing about its size. The only press feedback is a
/// slight dim, the way the pre-glass bordered styles behaved.
/// Padding follows the button's control size, like the system styles.
@available(iOS 26.0, *)
struct DriftStaticGlassButtonStyle: ButtonStyle {
    let prominent: Bool
    let tint: Color

    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let horizontal: CGFloat
        let vertical: CGFloat
        switch controlSize {
        case .large: horizontal = 20; vertical = 12
        case .small: horizontal = 10; vertical = 5
        case .mini: horizontal = 8; vertical = 4
        default: horizontal = 16; vertical = 8
        }
        return configuration.label
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            // The glass is the label's background, not the label
            // itself (#290, same lesson as the Home frame): glass on
            // the view can swallow touches outside the drawn content,
            // and a button must answer across its whole capsule.
            .background {
                Capsule().fill(.clear)
                    .glassEffect(prominent ? .regular.tint(tint) : .regular,
                                 in: Capsule())
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
    }
}
