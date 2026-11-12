import SwiftUI

// DriftActionSheet.swift
// ─────────────────────────────────────────────────────────────────────────
// The app's own confirmation popup for "pick one / confirm this"
// dialogs (Grace, 2026-11-12, builds 33–35). History: the system
// confirmationDialog / action-style alerts present on her system as
// a translucent floating bubble with an anchor arrow, pale pill
// buttons and no visible cancel — unacceptable. A first attempt as
// a solid bottom sheet (build 33/34) fixed the look but its height
// was formula-guessed, so short dialogs floated their buttons at
// the bottom over a big empty gap, each one different (#250).
//
// Final shape, chosen by Grace from mockups (option B): a centered
// popup card drawn entirely by the app — dim backdrop, solid card,
// title, optional short message, one full-width solid button per
// action (red text for destructive ones) and an always-visible
// 「取消」 button. The card is exactly as tall as its content, and
// because nothing here comes from the system, it looks identical
// on iOS 17, 18 and 26+. Tapping the backdrop cancels. Tapping an
// action dismisses the popup first and runs the handler a beat
// later, so a handler that presents another sheet (e.g. the share
// sheet after exporting a record) does not collide.
// ─────────────────────────────────────────────────────────────────────────

/// One tappable row in the popup.
struct DriftSheetAction: Identifiable {
    let id = UUID()
    let title: String
    var destructive = false
    let handler: () -> Void

    init(_ title: String, destructive: Bool = false, handler: @escaping () -> Void) {
        self.title = title
        self.destructive = destructive
        self.handler = handler
    }
}

struct DriftPopupCardView: View {
    let title: String
    var message: String?
    let actions: [DriftSheetAction]
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let message, !message.isEmpty {
                ScrollView {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: 150)
            }
            ForEach(actions) { action in
                Button {
                    dismiss()
                    Task {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        action.handler()
                    }
                } label: {
                    Text(action.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(action.destructive ? .red : .primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Button {
                dismiss()
            } label: {
                Text("取消")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 10)
        .frame(maxWidth: 340)
        .background(Color(.systemBackground),
                    in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 24, x: 0, y: 10)
    }
}

struct DriftPopupModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    var message: String?
    let actions: [DriftSheetAction]

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    ZStack {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                            .onTapGesture { isPresented = false }
                            .transition(.opacity)
                        DriftPopupCardView(title: title, message: message,
                                           actions: actions) {
                            isPresented = false
                        }
                        .padding(.horizontal, 36)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                    .ignoresSafeArea()
                    .animation(.easeOut(duration: 0.2), value: isPresented)
                }
            }
    }
}

extension View {
    /// Present the app's own centered confirmation popup
    /// (`DriftPopupCardView`) over a dimmed backdrop. The card's
    /// height hugs its content; the look is identical on every OS
    /// version because the app draws all of it.
    func driftActionSheet(isPresented: Binding<Bool>, title: String,
                          message: String? = nil,
                          actions: [DriftSheetAction]) -> some View {
        modifier(DriftPopupModifier(isPresented: isPresented, title: title,
                                    message: message, actions: actions))
    }
}
