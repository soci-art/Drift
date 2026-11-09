import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A UIKit document picker, standing in for SwiftUI's `fileImporter`.
///
/// Why this exists (Grace's pairing import, feedback rounds 1–2,
/// 2026-11-09): on her iPhone the SwiftUI importer showed the pairing
/// `.plist` in the list — rendered normally, preview and all — and then
/// swallowed the tap on it: the picker neither returned to the app nor
/// reported anything, across two builds and two different content-type
/// tables, so the fault is in that presentation path on her system
/// (iOS 27.2 beta 2), not in what the app asked for. This picker is created
/// directly, one instance per presentation, delegate-driven, and
/// `asCopy: true` hands back a plain file copy in the app's temporary
/// directory, so callers read it without security-scope bookkeeping (the
/// import paths tolerate scoped URLs too, so nothing else changes).
///
/// Presented as a sheet: picking or cancelling calls back, and the caller
/// drops the sheet either way — a tap in this picker always ends somewhere
/// visible.
struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    var allowsMultipleSelection = false
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: DocumentPicker

        init(_ parent: DocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
