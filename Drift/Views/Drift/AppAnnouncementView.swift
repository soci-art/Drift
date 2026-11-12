import SwiftUI
import UIKit

/// The in-app update announcement (#178), presented as a proper
/// announcement page (#192): app icon, title, version and date in the
/// header; the notes below; a single 确定 button.
///
/// Collection #222: the notes are the GitHub release notes of this
/// build's version (see AppAnnouncement). The page renders the cached
/// copy instantly and refreshes it in the background. Opened manually
/// from Settings with nothing to show, it says so in one short line;
/// the automatic presentation is preflighted by the root view and
/// never lands on that state.
struct AppAnnouncementView: View {
    /// True when the user opened the page themselves (Settings).
    var manualEntry = false
    let onDismiss: () -> Void

    @State private var notes: AppAnnouncement.Notes? = AppAnnouncement.cachedNotes()
    @State private var fetchSettled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                appIcon
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppAnnouncement.title)
                        .font(.title3.weight(.bold))
                    Text(AppAnnouncement.versionLine(dateLine: notes?.dateLine))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 18)

            Divider()

            Group {
                if let notes {
                    ScrollView {
                        notesBody(notes.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if manualEntry && fetchSettled {
                    Text("暂时取不到更新说明，检查网络后再试。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 16)
                } else {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 24)
                }
            }
            .frame(maxHeight: 430)

            Spacer()

            Button {
                onDismiss()
            } label: {
                Text("确定")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .driftGlassProminentButton()
        }
        .padding(24)
        .task {
            if let fresh = await AppAnnouncement.fetchNotes() {
                notes = fresh
            }
            fetchSettled = true
        }
    }

    // MARK: - Notes rendering

    /// The release notes are light markdown (a title line, section
    /// heads, dash bullets). Render them in reader form instead of
    /// showing raw markup characters.
    ///
    /// Collection #265 (Grace, 2026-11-12): the body is ONE `Text`
    /// built by concatenating styled segments, not a stack of per-line
    /// views. The per-line stack rendered the line that was still
    /// below the scroll area's bottom edge early, squeezed to a
    /// half-height strip; scrolling to it made it snap to full height.
    /// A single text block has no per-line layout to squeeze — lines
    /// are clipped by the scroll view's bottom edge like any text,
    /// emerging from the very bottom as it scrolls, which is exactly
    /// the behaviour she specified.
    private func notesBody(_ body: String) -> some View {
        notesText(body)
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }

    private func notesText(_ body: String) -> Text {
        let lines = Self.readerLines(body)
        var result = Text("")
        for (index, line) in lines.enumerated() {
            if index > 0 {
                // A heading gets a blank line before it; every other
                // line follows directly.
                result = result + Text(line.isHeading ? "\n\n" : "\n")
            }
            switch line {
            case .heading(let text):
                result = result + Text(text).font(.headline)
            case .bullet(let text):
                result = result + Text("•  ").foregroundColor(.secondary)
                    + Text(text).font(.subheadline)
            case .text(let text):
                result = result + Text(text).font(.subheadline).foregroundColor(.secondary)
            }
        }
        return result
    }

    private enum ReaderLine {
        case heading(String)
        case bullet(String)
        case text(String)

        var isHeading: Bool {
            if case .heading = self { return true }
            return false
        }
    }

    private static func readerLines(_ body: String) -> [ReaderLine] {
        body.components(separatedBy: .newlines).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "---" { return nil }
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
            // #265: sub-headings (###, ####) are headings too — the old
            // parser only knew ## and #, so ### lines showed their raw
            // hashes in the page.
            if line.hasPrefix("#") {
                let hashes = line.prefix(while: { $0 == "#" }).count
                let rest = line.dropFirst(hashes)
                if hashes <= 4, rest.hasPrefix(" ") {
                    return .heading(String(rest.dropFirst()))
                }
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                return .bullet(String(line.dropFirst(2)))
            }
            return .text(line)
        }
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
