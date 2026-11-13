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

            // #293 (Grace, 2026-11-13): no height cap on the notes —
            // the old 430pt ceiling cut long release notes off mid-line
            // with empty page below it. The scroll view now takes all
            // the space between the header and the button, so the full
            // text is always reachable.
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

    /// The release notes are markdown, and the page renders them the
    /// way GitHub renders the same notes (#293, Grace, 2026-11-13):
    /// the markup characters never show, but the structure does —
    /// headings sized by their level, **bold** actually bold, dash
    /// and numbered lists as lists, blank lines as paragraph breaks.
    ///
    /// Collection #265 (Grace, 2026-11-12): the body is ONE `Text`
    /// built by concatenating styled segments, not a stack of per-line
    /// views. The per-line stack rendered the line that was still
    /// below the scroll area's bottom edge early, squeezed to a
    /// half-height strip; scrolling to it made it snap to full height.
    /// A single text block has no per-line layout to squeeze — lines
    /// are clipped by the scroll view's bottom edge like any text,
    /// emerging from the very bottom as it scrolls, which is exactly
    /// the behaviour she specified. The GitHub-style rendering keeps
    /// that single-text architecture; only the segment styling grew.
    private func notesBody(_ body: String) -> some View {
        notesText(body)
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }

    private func notesText(_ body: String) -> Text {
        let lines = Self.readerLines(body)
        var result = Text("")
        var wroteAny = false
        var blankBefore = false
        for line in lines {
            switch line {
            case .paragraphBreak:
                blankBefore = true
            case .heading(let level, let text):
                // A heading gets a blank line before it, like GitHub.
                if wroteAny { result = result + Text("\n\n") }
                result = result + inlineText(text, font: Self.headingFont(level))
                wroteAny = true
                blankBefore = false
            case .bullet(let text):
                if wroteAny { result = result + Text(blankBefore ? "\n\n" : "\n") }
                result = result + Text("•  ")
                    + inlineText(text, font: .body)
                wroteAny = true
                blankBefore = false
            case .numbered(let marker, let text):
                if wroteAny { result = result + Text(blankBefore ? "\n\n" : "\n") }
                result = result + Text("\(marker) ")
                    + inlineText(text, font: .body)
                wroteAny = true
                blankBefore = false
            case .text(let text):
                if wroteAny { result = result + Text(blankBefore ? "\n\n" : "\n") }
                result = result + inlineText(text, font: .body)
                wroteAny = true
                blankBefore = false
            }
        }
        return result
    }

    /// Heading sizes follow the markdown level, GitHub-style: the
    /// fewer hashes, the bigger the heading.
    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.weight(.bold)
        case 2: return .title2.weight(.bold)
        case 3: return .title3.weight(.bold)
        default: return .headline
        }
    }

    /// One line's inline markdown as styled text: `**bold**` renders
    /// bold, `` `code` `` renders monospaced, the markers themselves
    /// never show. Unbalanced markers degrade to plain text.
    private func inlineText(_ raw: String, font: Font) -> Text {
        var result = Text("")
        let boldParts = raw.components(separatedBy: "**")
        for (index, part) in boldParts.enumerated() {
            result = result + styledPart(part, font: font, bold: index % 2 == 1)
        }
        return result
    }

    private func styledPart(_ raw: String, font: Font, bold: Bool) -> Text {
        var result = Text("")
        let codeParts = raw.components(separatedBy: "`")
        for (index, part) in codeParts.enumerated() {
            var segmentFont = font
            if index % 2 == 1 { segmentFont = segmentFont.monospaced() }
            if bold { segmentFont = segmentFont.weight(.bold) }
            result = result + Text(part).font(segmentFont)
        }
        return result
    }

    private enum ReaderLine {
        case heading(level: Int, text: String)
        case bullet(String)
        case numbered(marker: String, text: String)
        case text(String)
        case paragraphBreak

        var isHeading: Bool {
            if case .heading = self { return true }
            return false
        }
    }

    private static func readerLines(_ body: String) -> [ReaderLine] {
        var lines: [ReaderLine] = []
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "---" {
                // A blank line (or a divider) is a paragraph break;
                // collapse runs of them into one.
                if let last = lines.last, case .paragraphBreak = last { continue }
                if !lines.isEmpty { lines.append(.paragraphBreak) }
                continue
            }
            // #265: sub-headings (###, ####) are headings too — the old
            // parser only knew ## and #, so ### lines showed their raw
            // hashes in the page.
            if line.hasPrefix("#") {
                let hashes = line.prefix(while: { $0 == "#" }).count
                let rest = line.dropFirst(hashes)
                if hashes <= 4, rest.hasPrefix(" ") {
                    lines.append(.heading(level: hashes, text: String(rest.dropFirst())))
                    continue
                }
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                lines.append(.bullet(String(line.dropFirst(2))))
                continue
            }
            // A numbered list item: digits, a dot, a space.
            let digits = line.prefix(while: { $0.isNumber })
            if !digits.isEmpty, digits.count <= 3,
               line.dropFirst(digits.count).hasPrefix(". ") {
                lines.append(.numbered(marker: String(digits) + ".",
                                        text: String(line.dropFirst(digits.count + 2))))
                continue
            }
            if line.hasPrefix("> ") {
                lines.append(.text(String(line.dropFirst(2))))
                continue
            }
            lines.append(.text(line))
        }
        while let last = lines.last, case .paragraphBreak = last { lines.removeLast() }
        return lines
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
