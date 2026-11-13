import SwiftUI
import UniformTypeIdentifiers

/// The wallpaper-pack list, a page of its own since collection #266
/// (Grace, 2026-11-13): Home's packs section collapsed into one blue
/// bar, and the list lives here behind it.
///
/// The page's rules, all hers:
///   * rows are lazy and carry NO swipe gesture (#267) — the old
///     hand-rolled swipe-to-delete won gesture arbitration over the
///     page scroll, so with a dozen packs one finger could not scroll
///     at all. Deletion is the bottom zone's button now;
///   * rows have no chevron and tapping a row only selects it (#268);
///   * a repaired pack sits directly under its original, indented,
///     with a blue chip saying 修复版 / 深度修复版 (#268);
///   * the bottom zone holds the five things that used to live on a
///     detail page — where the wallpaper lands, legacy handling, and
///     删除 / 壁纸修复 / 深度修复 — acting on the selected packs (#268);
///   * importing is the blue filled circle at the top right (#281).
struct PackListView: View {
    @Binding var imports: [PosterBoardTendie]
    @Binding var selection: PosterBoardSelection
    @EnvironmentObject private var session: DriftSession
    @EnvironmentObject private var identityMonitor: DeviceIdentityMonitor

    @State private var importingTendies = false
    @State private var legacyPrompt: LegacyConvertPrompt?
    @State private var confirmDelete = false
    @State private var repairSummary: RepairSummary?
    @State private var deepRepairTarget: PosterBoardTendie?
    @State private var previewPack: PosterBoardTendie?
    @State private var legacyURLs: Set<URL> = []

    private var identity: DeviceIdentity { identityMonitor.current }

    var body: some View {
        ZStack {
            DriftBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if imports.isEmpty {
                        Text("还没有导入壁纸包。点右上角的蓝色按钮选 .tendies 文件导入，或在「文件」App 里对壁纸包点打开方式选 Drift。")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    // #315: the selected set is built once per body
                    // pass — each row used to rescan the whole
                    // selection array to answer "am I selected".
                    let selectedURLs = Set(selection.tendies.map(\.url))
                    ForEach(displayRows) { row in
                        PackListRow(pack: row.pack,
                                    selected: selectedURLs.contains(row.pack.url),
                                    kind: row.kind,
                                    onPreview: {
                                        previewPack = row.pack
                                        AppLog.op("壁纸包页：看 \(row.pack.name) 的大图")
                                    })
                            .onTapGesture { toggle(row.pack) }
                    }
                }
                .padding(16)
                .driftPageWidth()
            }
        }
        .navigationTitle("壁纸包")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // #281: the import button is a blue filled circle.
            ToolbarItem(placement: .topBarTrailing) {
                Button { importingTendies = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("导入壁纸包")
            }
        }
        .safeAreaInset(edge: .bottom) { bottomZone }
        .sheet(isPresented: $importingTendies) {
            // `.item` is the eligibility backstop, as on Home before:
            // the declared `.tendies` type doesn't reliably match real
            // packs' system tags, and `PosterBoardImports` validates
            // every pick and reports bad packs in words (#269).
            DocumentPicker(contentTypes: [UTType("com.sociart.drift.tendies") ?? .zip, .item],
                           allowsMultipleSelection: true) { urls in
                importingTendies = false
                handleTendiesPick(urls)
            } onCancel: {
                importingTendies = false
            }
        }
        .modifier(LegacyConvertPromptModifier(prompt: $legacyPrompt) { prompt, convert in
            answerLegacy(prompt, convert: convert)
        })
        .driftActionSheet(isPresented: $confirmDelete, title: "删除选中的壁纸包？",
                          message: selection.tendies.map { "· \($0.name)" }.joined(separator: "\n"),
                          actions: [
                            DriftSheetAction("删除", destructive: true) { deleteSelected() },
                          ])
        .alert(item: $repairSummary) { summary in
            Alert(title: Text(summary.title), message: Text(summary.message),
                  dismissButton: .default(Text("知道了")))
        }
        .sheet(item: $deepRepairTarget) { target in
            PackDeepRepairView(pack: target) { repaired in
                if !imports.contains(where: { $0.url == repaired.url }) {
                    imports.append(repaired)
                }
            }
        }
        .sheet(item: $previewPack) { pack in
            // Collection #282 (Grace, 2026-11-13): the cover, big. A
            // partial detent on purpose — the list stays visible and
            // dimmed behind it, and the two ways out are exactly the
            // two she named: swipe it down, or tap the area outside
            // the sheet. Both are the sheet's own behaviour at this
            // detent; the page itself only carries the words 下滑关闭.
            PackCoverPreview(pack: pack)
                .presentationDetents([.fraction(0.86)])
        }
        .overlay {
            if session.cover == .repairing {
                repairingCover
            }
        }
        .task(id: selectionKey) { await refreshLegacyInfo() }
        // Warm the legacy-family memo off the main thread (cleanup
        // round, 2026-11-13): the first tap on a pack used to open its
        // archive synchronously in `toggle`, and the selection refresh
        // re-opened every selected pack. With the memo warm, both are
        // stat-cheap lookups.
        .task(id: importsWarmKey) {
            let packs = imports
            await Task.detached(priority: .utility) {
                for pack in packs { _ = try? pack.legacyFamilies() }
            }.value
        }
        .onAppear { AppLog.op("打开壁纸包页（已导入 \(imports.count) 个包）") }
    }

    // MARK: - Rows and ordering

    private struct DisplayRow: Identifiable {
        let pack: PosterBoardTendie
        let kind: PackRowKind
        var id: URL { pack.url }
    }

    /// Originals in import order, each followed immediately by its
    /// repaired products (#268). A derivative whose original is gone
    /// keeps its own place at the end rather than vanishing.
    private var displayRows: [DisplayRow] {
        func kind(of pack: PosterBoardTendie) -> PackRowKind {
            if PackDeepRepair.isDeepRepaired(pack) { return .deepRepaired }
            if PackRepair.isRepaired(pack) { return .repaired }
            return .original
        }
        func baseName(of pack: PosterBoardTendie) -> String {
            var name = pack.url.deletingPathExtension().lastPathComponent
            for suffix in ["(patched)", "(deep)"] where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
            return name
        }
        var rows: [DisplayRow] = []
        let derivatives = imports.filter { kind(of: $0) != .original }
        for pack in imports where kind(of: pack) == .original {
            rows.append(DisplayRow(pack: pack, kind: .original))
            for derivative in derivatives where baseName(of: derivative) == baseName(of: pack) {
                rows.append(DisplayRow(pack: derivative, kind: kind(of: derivative)))
            }
        }
        let placed = Set(rows.map(\.id))
        for derivative in derivatives where !placed.contains(derivative.url) {
            rows.append(DisplayRow(pack: derivative, kind: kind(of: derivative)))
        }
        return rows
    }

    // MARK: - Bottom zone (#268)

    private var selectedPacks: [PosterBoardTendie] { selection.tendies }

    private var bottomZone: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("刷完出现在哪里").font(.subheadline.weight(.semibold))
                Spacer()
                if !selectedPacks.isEmpty {
                    Text("已选 \(selectedPacks.count) 个").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("刷完出现在哪里", selection: posterTypeBinding) {
                ForEach(PosterBoardPosterType.allCases) { type in
                    Text(type.label).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .disabled(selectedPacks.isEmpty)
            if let first = selectedPacks.first {
                Text(first.posterType.blurb)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !legacyURLs.isEmpty && needsConversionUI {
                Text("旧格式处理").font(.subheadline.weight(.semibold))
                Picker("旧格式处理", selection: autoConvertBinding) {
                    Text("转换成新格式").tag(true)
                    Text("按原样安装").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(selectedPacks.isEmpty)
            }
            if selectedPacks.contains(where: \.isUnsafeContainer) {
                Text("选中的包里有容器包：只能走恢复刷，恢复刷已封存，目前刷不了。")
                    .font(.caption).foregroundStyle(.red)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { bottomActionButtons }
                VStack(alignment: .leading, spacing: 10) { bottomActionButtons }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background { bottomZoneBackground }
    }

    @ViewBuilder
    private var bottomActionButtons: some View {
        Button(role: .destructive) {
            confirmDelete = true
        } label: {
            Label("删除", systemImage: "trash")
        }
        .driftGlassButton()
        .fixedSize(horizontal: true, vertical: false)
        .disabled(selectedPacks.isEmpty)
        Button {
            runRepairSelected()
        } label: {
            Label("壁纸修复", systemImage: "wrench.and.screwdriver")
        }
        .driftGlassButton()
        .fixedSize(horizontal: true, vertical: false)
        .disabled(selectedPacks.isEmpty)
        if !selectedPacks.isEmpty
            && selectedPacks.allSatisfy({ PackDeepRepair.isDeepRepaired($0) }) {
            Label("已深度修复", systemImage: "checkmark.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            Button {
                deepRepairTarget = selectedPacks.first {
                    !PackDeepRepair.isDeepRepaired($0)
                } ?? selectedPacks.first
            } label: {
                Label("深度修复", systemImage: "wand.and.stars")
            }
            .buttonStyle(DeepRepairPillStyle())
            .fixedSize(horizontal: true, vertical: false)
            .disabled(selectedPacks.isEmpty)
        }
    }

    @ViewBuilder
    private var bottomZoneBackground: some View {
        // Collection #283: rounded top edge. On iOS 17/18 this is a solid
        // panel, not a material, so the legacy surface stays consistent.
        let shape = UnevenRoundedRectangle(cornerRadii: .init(topLeading: 20, topTrailing: 20),
                                           style: .continuous)
        if DriftTheme.legacyUI {
            shape.fill(Color(.secondarySystemBackground))
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: .black.opacity(0.10), radius: 10, y: -3)
        } else {
            shape.fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: .black.opacity(0.10), radius: 10, y: -3)
        }
    }

    private var repairingCover: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("正在修复")
                    .font(.headline)
                Text("请勿熄屏或退出 App")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let progress = session.coverProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(DriftTheme.legacyUI
                          ? AnyShapeStyle(Color(.secondarySystemBackground))
                          : AnyShapeStyle(.regularMaterial))
            }
        }
        .transition(.opacity)
    }

    // MARK: - Selection and settings

    private var selectionKey: String {
        selection.tendies.map { $0.url.path }.joined(separator: "|")
    }

    /// Changes whenever the import list's membership or any pack's
    /// bytes change, so the warm-up task reruns exactly then.
    private var importsWarmKey: String {
        imports.map { $0.url.path + "@" + PackFileFingerprint.of($0.url) }.joined(separator: "|")
    }

    private func refreshLegacyInfo() async {
        var found: Set<URL> = []
        for pack in selection.tendies {
            if ((try? pack.legacyFamilies()) ?? []).isEmpty == false {
                found.insert(pack.url)
            }
        }
        legacyURLs = found
    }

    /// The device's major version, or nil while identity is unread —
    /// the conversion UI shows unless the device is known to be on
    /// iOS 26, the one supported system that never converts.
    private var needsConversionUI: Bool {
        let version = identity.version
        guard let major = Int(version.split(separator: ".").first ?? "") else { return true }
        return major >= 27
    }

    private var posterTypeBinding: Binding<PosterBoardPosterType> {
        Binding(
            get: { selectedPacks.first?.posterType ?? .defaultForContainer(false) },
            set: { type in
                for pack in selectedPacks { setType(type, on: pack) }
                AppLog.op("壁纸包页：把 \(selectedPacks.count) 个包的出现位置改成\(type.label)")
            })
    }

    private var autoConvertBinding: Binding<Bool> {
        Binding(
            get: { selectedPacks.first?.autoConvert ?? true },
            set: { convert in
                for pack in selectedPacks where legacyURLs.contains(pack.url) {
                    setConvert(convert, on: pack)
                }
                AppLog.op("壁纸包页：旧格式处理改成\(convert ? "转换成新格式" : "按原样安装")")
            })
    }

    private func toggle(_ pack: PosterBoardTendie) {
        if let index = selection.tendies.firstIndex(where: { $0.url == pack.url }) {
            selection.tendies.remove(at: index)
            AppLog.op("壁纸包页：取消勾选 \(pack.name)")
            return
        }
        if let prompt = pack.legacyConvertPrompt(deviceVersion: identity.version) {
            legacyPrompt = prompt
            return
        }
        selection.tendies.append(pack)
        AppLog.op("壁纸包页：勾选 \(pack.name)")
    }

    private func answerLegacy(_ prompt: LegacyConvertPrompt, convert: Bool) {
        // Clear the question FIRST — the modifier's contract (see the
        // Home page's old note): leaving it set re-presents the alert
        // on every re-render.
        legacyPrompt = nil
        let answered = prompt.pack.settingAutoConvert(convert)
        if let index = imports.firstIndex(where: { $0.url == answered.url }) {
            imports[index] = answered
        }
        selection.tendies.append(answered)
    }

    private func setType(_ type: PosterBoardPosterType, on pack: PosterBoardTendie) {
        let updated = pack.settingPosterType(type)
        if let index = imports.firstIndex(where: { $0.url == updated.url }) {
            imports[index] = updated
        }
        if let index = selection.tendies.firstIndex(where: { $0.url == updated.url }) {
            selection.tendies[index] = updated
        }
    }

    private func setConvert(_ convert: Bool, on pack: PosterBoardTendie) {
        let updated = pack.settingAutoConvert(convert)
        if let index = imports.firstIndex(where: { $0.url == updated.url }) {
            imports[index] = updated
        }
        if let index = selection.tendies.firstIndex(where: { $0.url == updated.url }) {
            selection.tendies[index] = updated
        }
    }

    // MARK: - Actions

    private func deleteSelected() {
        let targets = selectedPacks
        for pack in targets {
            PosterBoardPreview.invalidate(for: pack)
            PosterBoardImports.remove(pack)
        }
        let targetURLs = Set(targets.map(\.url))
        imports.removeAll { targetURLs.contains($0.url) }
        selection.tendies.removeAll { targetURLs.contains($0.url) }
        AppLog.op("壁纸包页：删除了 \(targets.map(\.name).joined(separator: "、"))")
    }

    private struct RepairSummary: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// The detail page's repair, aimed at every selected pack (#268):
    /// each pack that has structural issues is repaired in turn, under
    /// the same cover, and the outcome is one summary at the end.
    private func runRepairSelected() {
        let targets = selectedPacks
        guard !targets.isEmpty else { return }
        let version = identity.version.isEmpty
            ? WorseQueryEscape.processVersion : identity.version
        session.cover = .repairing
        session.coverProgress = 0
        AppLog.op("壁纸包页：对 \(targets.count) 个包点壁纸修复")
        Task {
            defer { session.cover = nil; session.coverProgress = nil }
            var repairedNames: [String] = []
            var noNeed = 0
            for (index, target) in targets.enumerated() {
                let issues = PackRepair.inspect(target)
                if issues.isEmpty {
                    noNeed += 1
                    continue
                }
                do {
                    let repaired = try await Task.detached {
                        try PackRepair.repair(target, issues: issues, deviceVersion: version) { phase in
                            let overall = (Double(index) + phase) / Double(targets.count)
                            Task { @MainActor in DriftSession.shared.coverProgress = overall }
                        }
                    }.value
                    if !imports.contains(where: { $0.url == repaired.url }) {
                        imports.append(repaired)
                    }
                    repairedNames.append(repaired.name)
                } catch {
                    session.errorText = error.localizedDescription
                }
            }
            if !repairedNames.isEmpty {
                repairSummary = RepairSummary(
                    title: "修好了",
                    message: "修好的包已放进列表，就在原包下面：\(repairedNames.joined(separator: "、"))。")
            } else if noNeed == targets.count {
                repairSummary = RepairSummary(
                    title: "壁纸修复",
                    message: "选中的包没查到需要修的毛病，无需修复。")
            }
        }
    }

    private func handleTendiesPick(_ urls: [URL]) {
        Task {
            var problemPacks: [String] = []
            for url in urls {
                do {
                    let packs = try await Task.detached {
                        try PosterBoardImports.importPicked(from: url)
                    }.value
                    for pack in packs {
                        Task.detached { _ = PosterBoardPreview.previews(for: pack) }
                        // Auto-repair already ran at import (#269); a
                        // pack still carrying blocking issues is one
                        // the repair could not fix.
                        if !PackRepair.isRepaired(pack),
                           !PackDeepRepair.isDeepRepaired(pack),
                           !PackRepair.blockingIssues(of: pack).isEmpty {
                            problemPacks.append(pack.name)
                        }
                    }
                } catch {
                    session.errorText = error.localizedDescription
                }
            }
            imports = PosterBoardImports.load()
            if !problemPacks.isEmpty {
                session.noticeTitle = "有壁纸包需要修一下"
                session.noticeText = problemPacks.map { "「\($0)」" }.joined(separator: "、")
                    + "的结构有点问题，导入时自动修了一次没修好，现在刷可能会找不到壁纸。"
            }
        }
    }
}

/// How a row's pack relates to an original import (#268): repaired
/// products are marked and sit indented under their original.
private enum PackRowKind {
    case original, repaired, deepRepaired
}

/// One pack in the list: select tick, whole-picture cover (#263),
/// name and facts. No buttons inside, no gestures of its own — the
/// row's single tap toggles selection (#268), and the cover decodes
/// through the downsampling cache (#267).
private struct PackListRow: View {
    let pack: PosterBoardTendie
    let selected: Bool
    let kind: PackRowKind
    /// Collection #282: the cover is its own tap target — tapping IT
    /// opens the big preview, tapping anywhere else on the row just
    /// selects. A real Button, so its taps never fall through to the
    /// row's toggle gesture behind it.
    let onPreview: () -> Void

    @State private var cover: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: 24)
            Button(action: onPreview) {
                Group {
                    if let cover {
                        Image(uiImage: cover).resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: [.blue.opacity(0.35), .mint.opacity(0.35)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay(Text(String(pack.url.lastPathComponent.prefix(1)))
                                .font(.headline).foregroundStyle(.secondary))
                    }
                }
                .frame(width: 44, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(pack.url.lastPathComponent).font(.subheadline.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    DriftPill(text: "\(pack.descriptorCount) 张")
                    DriftPill(text: pack.posterType.label)
                    if kind == .repaired {
                        DriftPill(text: "修复版", tint: .blue)
                    }
                    if kind == .deepRepaired {
                        DriftPill(text: "深度修复版", tint: .blue)
                    }
                    if pack.isUnsafeContainer {
                        DriftPill(text: "含数据库 · 风险高", tint: .red)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .padding(.leading, kind == .original ? 0 : 14)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .task(id: pack.url) {
            // Decode off the main actor too (cleanup round, 2026-11-13):
            // the fetch was detached but the decode landed back here.
            cover = await Task.detached {
                PosterBoardPreview.cover(for: pack).flatMap {
                    PosterBoardPreview.coverImage(at: $0, maxPixelSize: 180)
                }
            }.value
        }
    }
}

/// The cover, big (collection #282, Grace, 2026-11-13, layout from
/// the approved full-page render): the pack's name and fact pills at
/// the top, the whole-picture cover below at phone-screen
/// proportions — every preview the pack carries, pageable when there
/// is more than one — and at the bottom the only words the page
/// carries about closing: 下滑关闭. (Tapping outside the sheet also
/// closes it; that way out is behaviour, not copy — her ruling.)
/// Selection is never touched from here.
private struct PackCoverPreview: View {
    let pack: PosterBoardTendie

    @State private var images: [UIImage] = []
    @State private var loaded = false

    var body: some View {
        GeometryReader { geo in
            let stageHeight = max(220, min(500, geo.size.height - 180))
            VStack(spacing: 12) {
                Text(pack.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    DriftPill(text: "\(pack.descriptorCount) 张")
                    DriftPill(text: pack.posterType.label)
                    if PackDeepRepair.isDeepRepaired(pack) {
                        DriftPill(text: "深度修复版", tint: .blue)
                    } else if PackRepair.isRepaired(pack) {
                        DriftPill(text: "修复版", tint: .blue)
                    }
                }
                stage(height: stageHeight, width: geo.size.width)
                Text("下滑关闭")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task {
            // Decode off the main actor, downsampled through the same
            // cache the rows use (cleanup round, 2026-11-13): the page
            // used to decode every preview at full size on the main
            // thread, one after another, while the sheet animated in.
            images = await Task.detached {
                PosterBoardPreview.previews(for: pack).compactMap {
                    PosterBoardPreview.coverImage(at: $0, maxPixelSize: 1400)
                }
            }.value
            loaded = true
        }
    }

    @ViewBuilder
    private func stage(height: CGFloat, width: CGFloat) -> some View {
        if images.count > 1 {
            TabView {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    stageImage(image, maxHeight: height)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(height: height)
        } else if let image = images.first {
            stageImage(image, maxHeight: height)
        } else if loaded {
            // A pack with no still anywhere (pure animation): the
            // same placeholder the row shows, at stage size.
            LinearGradient(colors: [.blue.opacity(0.35), .mint.opacity(0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(Text(String(pack.url.lastPathComponent.prefix(1)))
                    .font(.largeTitle).foregroundStyle(.secondary))
                .frame(width: max(180, min(250, width * 0.72)), height: height)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            ProgressView()
                .frame(height: height)
        }
    }

    private func stageImage(_ image: UIImage, maxHeight: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: maxHeight)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }
}
