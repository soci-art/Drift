import SwiftUI

// DriftActionSheet.swift
// ─────────────────────────────────────────────────────────────────────────
// The app's own bottom action sheet for "pick one / confirm this"
// dialogs, replacing the system confirmationDialog and the
// action-style alerts (Grace, 2026-11-12, on 3.0.11 (32)): on her
// system those present as a translucent floating bubble with an
// anchor arrow, greyed-out-looking pill buttons and no visible
// cancel button — the same complaint she had already raised about
// the log-upload and wallpaper-delete dialogs, which are system
// alerts with the same look.
//
// This sheet is deliberately boring and identical on every OS
// version: it rises from the bottom, has a solid background, a
// title, an optional short message, one full-width solid button per
// action (red text for destructive ones) and an always-visible
// 「取消」 button. Tapping an action dismisses the sheet first and
// runs the handler a beat later, so a handler that presents another
// sheet (e.g. the share sheet after exporting a record) does not
// collide with the dismissal.
// ─────────────────────────────────────────────────────────────────────────

/// One tappable row in a `DriftActionSheet`.
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

struct DriftActionSheetView: View {
    let title: String
    var message: String?
    let actions: [DriftSheetAction]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
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
            // Uniform skeleton (Grace's option A, build 36): every
            // dialog is title / message / gap / actions / cancel in
            // a sheet of one fixed height, so they all look alike.
            Spacer()
            ForEach(actions) { action in
                Button {
                    dismiss()
                    Task {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        action.handler()
                    }
                } label: {
                    Text(action.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(action.destructive ? .red : .primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Button {
                dismiss()
            } label: {
                Text("取消")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}

extension View {
    /// Present `DriftActionSheetView` as a solid bottom sheet.
    /// Every dialog gets the same fixed height and the same
    /// skeleton — title, message, gap, actions, cancel — so they
    /// all look alike (Grace's option A, build 36; a centered
    /// popup, option B, shipped in build 35 and was rejected on
    /// device, so this sheet shape is the settled one).
    func driftActionSheet(isPresented: Binding<Bool>, title: String,
                          message: String? = nil,
                          actions: [DriftSheetAction]) -> some View {
        // One fixed height for every dialog (option A): uniformity
        // over hugging the content. 400 fits the tallest case (a
        // capped long message, or three actions) with room to spare.
        let height: CGFloat = 400
        return sheet(isPresented: isPresented) {
            DriftActionSheetView(title: title, message: message, actions: actions)
                .presentationDetents([.height(height)])
                // Grace (2026-11-12, on build 33): no drag-indicator
                // bar at the top of these sheets — remove it everywhere.
                .presentationDragIndicator(.hidden)
                .presentationBackground(Color(.systemBackground))
        }
    }
}
