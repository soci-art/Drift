import SwiftUI
import UniformTypeIdentifiers

/// The wallpaper page: connection state, the delivery-mode judgement,
/// imported packs with previews, the apply run, and the store reset.
struct DriftHomeView: View {
    @EnvironmentObject private var session: DriftSession
    @EnvironmentObject private var identityMonitor: DeviceIdentityMonitor
    @ObservedObject private var tunnelMonitor = TunnelMonitor.shared
    @Binding var selection: PosterBoardSelection

    /// The mode menu's pick, held in `@AppStorage` so a tap publishes a
    /// change the judgement card re-renders from immediately. The same key
    /// backs `DriftJudge.manualPick`, which stays for non-view readers.
    @AppStorage(DriftJudge.manualKey) private var manualPickRaw: String?

    @State private var imports: [PosterBoardTendie] = PosterBoardImports.load()
    @State private var importingTendies = false
    @State private var importingPairing = false
    @State private var legacyPrompt: LegacyConvertPrompt?
    @State private var detailPack: PosterBoardTendie?
    @State private var statusLine: String?
    @State private var confirmReset = false

    private var identity: DeviceIdentity { identityMonitor.current }
    private var manualPick: PosterBoardApplyMode? {
        manualPickRaw.flatMap(PosterBoardApplyMode.init(rawValue:))
    }
    /// The system version the judgement uses: the device's when a tunnel has
    /// answered, otherwise the app's own — the in-process route needs nothing
    /// but that.
    private var localVersion: String {
        identity.version.isEmpty ? WorseQueryEscape.processVersion : identity.version
    }
    private var localReady: Bool {
        WorseQueryEscape.isAvailable(deviceVersion: localVersion)
    }
    private var directReady: Bool {
        !identity.version.isEmpty && PosterBoardDirect.isAvailable(deviceVersion: identity.version)
    }
    private var manualLabel: String {
        manualPick?.shortTitle ?? "自动判断"
    }
    private var judgement: DriftModeJudgement {
        DriftJudge.judge(identity: identity, selection: selection, pick: manualPick)
    }
    private var selectedDescriptors: Int { selection.tendies.reduce(0) { $0 + $1.descriptorCount } }
    private var overLimit: Bool { selectedDescriptors > PosterBoardImports.descriptorLimit }
    private var canApply: Bool {
        // The in-process route is the one path that does not need a pairing
        // record; every other mode still does.
        (session.paired || judgement.mode == .worseQuery)
            && !selection.tendies.isEmpty && !overLimit && !session.running
    }
    private var headerSubtitle: String {
        if !identity.version.isEmpty { return identity.describe }
        if localReady {
            return "本机直刷可用（iOS \(WorseQueryEscape.processVersion)）：不用配对，也不用开隧道。"
        }
        return "导入配对文件、打开 LocalDevVPN 后，这里会显示设备系统。"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DriftBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        headerCard
                        judgeCard
                        packsCard
                        applyCard
                        resetCard
                        RunLogCard()
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Drift")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importingPairing = true } label: {
                        Image(systemName: session.paired ? "link.badge.plus" : "link")
                    }
                    .accessibilityLabel("导入配对文件")
                }
            }
            // UIKit pickers, not SwiftUI `fileImporter` — see
            // `DocumentPicker` for the tap-swallowing failure that moved
            // these. A pick or a cancel always lands back here.
            .sheet(isPresented: $importingTendies) {
                // `.item` is the same eligibility backstop as the pairing
                // picker's: the declared `.tendies` type is in the bundle,
                // but real packs' system type tags don't reliably match it
                // on Grace's phone — her packs listed greyed-out and
                // unselectable (2026-11-09). Eligibility was never the gate;
                // `PosterBoardImports` unpacks and validates every pick and
                // reports bad packs in words.
                DocumentPicker(contentTypes: [UTType("com.sociart.drift.tendies") ?? .zip, .item],
                               allowsMultipleSelection: true) { urls in
                    importingTendies = false
                    handleTendiesPick(urls)
                } onCancel: {
                    importingTendies = false
                }
            }
            .sheet(isPresented: $importingPairing) {
                DocumentPicker(contentTypes: PairingRecord.types) { urls in
                    importingPairing = false
                    handlePairingPick(urls)
                } onCancel: {
                    importingPairing = false
                }
            }
            .modifier(LegacyConvertPromptModifier(prompt: $legacyPrompt) { prompt, convert in
                answerLegacy(prompt, convert: convert)
            })
            .sheet(item: $detailPack) { pack in
                DriftPackDetail(pack: pack, imports: $imports, selection: $selection)
            }
        }
    }

    // MARK: - Cards

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DriftPill(text: session.paired ? "已配对" : "未配对",
                          tint: session.paired ? .green : .orange)
                DriftPill(text: tunnelMonitor.status == .ready ? "隧道已连通"
                          : tunnelMonitor.status == .interfaceUp ? "隧道等待对端"
                          : "隧道未连接",
                          tint: tunnelMonitor.status == .ready ? .green : .orange)
                if identity.version.isEmpty {
                    DriftPill(text: "设备信息未读到", tint: .orange)
                } else {
                    DriftPill(text: "iOS \(identity.version)\(identity.buildVersion.isEmpty ? "" : "（\(identity.buildVersion)）")")
                }
            }
            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !session.paired {
                Button { importingPairing = true } label: {
                    Label("导入配对文件", systemImage: "link.badge.plus")
                }
                .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    private var judgeCard: some View {
        let judged = judgement
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("本次刷入方式").font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    // A Picker inside the menu, not three bare Buttons: the
                    // picker is what draws the native checkmark on the current
                    // pick. With buttons the menu showed three identical rows
                    // and no sign of which one was in force (Grace, 2026-11-09).
                    Picker("刷入方式", selection: $manualPickRaw) {
                        Text("自动判断").tag(nil as String?)
                        // The in-process option is greyed when this signing
                        // profile has no App Group or the system is outside
                        // worse_query's range; the caption below says which.
                        Text("直刷（免注销）")
                            .tag(PosterBoardApplyMode.direct.rawValue as String?)
                            .disabled(!directReady)
                        Text("本机直刷（只注销）")
                            .tag(PosterBoardApplyMode.worseQuery.rawValue as String?)
                            .disabled(!localReady)
                        Text("AirLift 直刷（只注销）")
                            .tag(PosterBoardApplyMode.airlift.rawValue as String?)
                        // Feedback #30: while the restore gate is closed
                        // the restore pick is visible but not selectable —
                        // greyed, with the reason on the card below.
                        Text("恢复式（会重启）").tag(PosterBoardApplyMode.backup.rawValue as String?)
                            .disabled(!DriftRestoreGate.isEnabled)
                    }
                } label: {
                    // The control names the **pick**, not the outcome: it used
                    // to render `judged.mode`, so with a hard limit in force
                    // (no pairing → no identity → restore forced) the button
                    // read 恢复式 no matter what was tapped, and the menu
                    // looked dead (Grace, 2026-11-09). The effective mode
                    // stays where it belongs — the reason line and the
                    // override note below.
                    Label(manualLabel, systemImage: "chevron.up.chevron.down")
                        .font(.subheadline.weight(.medium))
                }
            }
            Text(judged.reason).font(.subheadline).foregroundStyle(.secondary)
                .onChange(of: manualPickRaw) { statusLine = nil }
            if !DriftRestoreGate.isEnabled {
                Text("恢复式暂时停用：菜单里选不了、自动判断也不会选它，原因查清之前先这样。直刷不受影响。")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !directReady && PosterBoardDirect.isAvailable(deviceVersion: localVersion) {
                Text("直刷需要先导入配对文件并读到设备系统版本。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !localReady {
                Text(WorseQueryEscape.unavailableReason(deviceVersion: localVersion))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let overridden = judged.overriddenPick {
                Text("你手动选的「\(overridden.shortTitle)」在这里用不了，已按上面的方式处理。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    private var packsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("壁纸包").font(.subheadline.weight(.semibold))
                Spacer()
                Button { importingTendies = true } label: {
                    Label("导入", systemImage: "plus")
                }
                .buttonStyle(.glass)
            }
            if imports.isEmpty {
                Text("还没有导入壁纸包。点「导入」选 .tendies 文件，或在「文件」App 里对壁纸包点打开方式选 Drift。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(imports) { pack in
                DriftPackRow(pack: pack,
                             selected: selection.tendies.contains { $0.url == pack.url },
                             onToggle: { toggle(pack) },
                             onOpen: { detailPack = pack },
                             onDelete: { deletePack(pack) })
            }
            if !selection.tendies.isEmpty {
                Text("已选 \(selection.tendies.count) 个包，共 \(selectedDescriptors) 张（一次最多 \(PosterBoardImports.descriptorLimit) 张）")
                    .font(.caption)
                    .foregroundStyle(overLimit ? .red : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    private var applyCard: some View {
        VStack(spacing: 10) {
            NativePrimaryButton(title: session.running ? "刷入中…" : "刷入",
                                systemImage: "paintbrush.pointed",
                                running: session.running,
                                disabled: !canApply) {
                runApply()
            }
            if session.running {
                Button("取消") { session.cancelRun() }
                    .buttonStyle(.glass)
            }
            if let statusLine {
                Text(statusLine).font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !session.paired && judgement.mode == .worseQuery {
                NativeNote("本机直刷在本机写入，不需要配对文件，也不用开隧道。")
            } else if !session.paired {
                NativeNote("先导入配对文件才能刷入；本机直刷需要签名带 App Group 权限。")
            } else if selection.tendies.isEmpty && !imports.isEmpty {
                NativeNote("在上面的列表里点圆圈勾选要刷的包。")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    private var resetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("重置壁纸商店").font(.subheadline.weight(.semibold))
            Text("壁纸乱了、刷坏了想清掉时用。只能走恢复式，刷完会重启；和普通刷入不能同一次进行。")
                .font(.subheadline).foregroundStyle(.secondary)
            if !DriftRestoreGate.isEnabled {
                NativeNote(DriftRestoreGate.notice)
            }
            ForEach(PosterBoardResetMode.allCases, id: \.self) { mode in
                Toggle(isOn: Binding(
                    get: { selection.resetModes.contains(mode) },
                    set: { on in
                        if on { selection.resetModes.insert(mode) }
                        else { selection.resetModes.remove(mode) }
                    })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(resetModeTitle(mode))
                        Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("完全重置（清空商店）", isOn: $selection.fullReset)
            NativeDangerButton(title: "执行重置", disabled: !canReset) { confirmReset = true }
                .confirmationDialog("确认重置壁纸商店？", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("重置并重启", role: .destructive) { runReset() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("将通过恢复式写入重置，设备会重启。已导入的壁纸包不会被删。")
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    private var canReset: Bool {
        // Feedback #30: a reset IS a restore run — while the gate is
        // closed the button stays disabled and the card above says why.
        DriftRestoreGate.isEnabled
            && session.paired && !session.running
            && (selection.fullReset || !selection.resetModes.isEmpty)
    }

    // MARK: - Actions

    private func toggle(_ pack: PosterBoardTendie) {
        if let index = selection.tendies.firstIndex(where: { $0.url == pack.url }) {
            selection.tendies.remove(at: index)
            return
        }
        if let prompt = pack.legacyConvertPrompt(deviceVersion: identity.version) {
            legacyPrompt = prompt
            return
        }
        selection.tendies.append(pack)
    }

    /// Remove an imported pack: the same steps the detail page's delete
    /// button takes (preview cache, stored copy, list, selection).
    private func deletePack(_ pack: PosterBoardTendie) {
        PosterBoardPreview.invalidate(for: pack)
        PosterBoardImports.remove(pack)
        imports.removeAll { $0.url == pack.url }
        selection.tendies.removeAll { $0.url == pack.url }
    }

    private func answerLegacy(_ prompt: LegacyConvertPrompt, convert: Bool) {
        // Clear the question FIRST. The modifier's contract says the caller
        // clears `prompt`; leaving it set keeps `isPresented` true, so the
        // alert re-presented itself every time this view re-rendered — most
        // visibly on every tab switch back to this page (Grace, 2026-11-09).
        // The answer itself is already permanent: `settingAutoConvert` writes
        // it to `autoConvertAnswers` by file name, so the pack is never asked
        // about twice.
        legacyPrompt = nil
        let answered = prompt.pack.settingAutoConvert(convert)
        if let index = imports.firstIndex(where: { $0.url == answered.url }) {
            imports[index] = answered
        }
        selection.tendies.append(answered)
    }

    private func runApply() {
        let judged = judgement
        // Feedback #30: a blocked judgement starts nothing — the tap
        // only explains. (The session funnel refuses restore runs too,
        // but a blocked selection must never even be shaped into one.)
        if judged.isBlocked {
            statusLine = judged.blockedReason
            return
        }
        var runSelection = selection
        runSelection.resetModes = []
        runSelection.fullReset = false
        Task {
            let outcome = await session.run(selection: runSelection, mode: judged.mode, identity: identity)
            statusLine = outcome.message
        }
    }

    private func runReset() {
        guard DriftRestoreGate.isEnabled else {
            statusLine = DriftRestoreGate.notice
            return
        }
        var resetSelection = PosterBoardSelection()
        resetSelection.resetModes = selection.resetModes
        resetSelection.fullReset = selection.fullReset
        Task {
            let outcome = await session.run(selection: resetSelection, mode: .backup, identity: identity)
            statusLine = outcome.message
            if outcome.ok {
                selection.resetModes = []
                selection.fullReset = false
            }
        }
    }

    private func handleTendiesPick(_ urls: [URL]) {
        for url in urls {
            do {
                let tendie = try PosterBoardImports.import(from: url)
                if !imports.contains(where: { $0.url == tendie.url }) {
                    imports.append(tendie)
                }
                Task.detached { _ = PosterBoardPreview.previews(for: tendie) }
            } catch {
                session.errorText = error.localizedDescription
            }
        }
        imports = PosterBoardImports.load()
    }

    private func handlePairingPick(_ urls: [URL]) {
        guard let url = urls.first else {
            session.errorText = "没有选到文件，请再导入一次。"
            return
        }
        do {
            try session.importPairing(from: url)
            statusLine = "配对文件已导入，正在连接设备。"
        } catch {
            session.errorText = error.localizedDescription
        }
    }
}

/// One imported pack: cover preview, facts, and the select toggle.
///
/// The whole row (cover, name, chevron) opens the detail page — the chevron
/// alone was too small a target (Grace, 2026-11-09) — and a left swipe
/// reveals a delete button behind the row. The rows live in a card inside a
/// `ScrollView`, not a `List`, so the swipe is hand-rolled — and the first
/// version's arbitration was itself the bug (feedback #25/#26): the detail
/// target was a real `Button` sitting under a `simultaneousGesture` drag,
/// so a horizontal swipe could still end as a button tap (both left and
/// right swipes navigated into the detail page), the drag had to fight the
/// scroll view and the buttons for the touch (a press-and-hold was needed
/// before a swipe would take at all), and the row slid on a translucent
/// material that let the delete tile's text ghost through its own.
///
/// The arbitration now lives in exactly one place:
///   * the sliding content carries no buttons — the tick and the detail
///     target are tap zones on one surface, told apart by where the tap
///     lands;
///   * a `highPriorityGesture` drag watches the same surface, so a touch
///     that travels past the drag's minimum distance is a drag and can
///     never also land as a tap;
///   * the drag locks its axis from the cumulative translation: the row
///     only starts moving once the motion is clearly horizontal, and a
///     mostly-vertical drag leaves the row exactly where it was (the page
///     scroll owns those);
///   * the slide is clamped to [-revealWidth, 0] — a right swipe from
///     closed does nothing at all, and from revealed it can only close;
///   * the content's background is opaque, so nothing underneath can show
///     through while it slides.
struct DriftPackRow: View {
    let pack: PosterBoardTendie
    let selected: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var cover: UIImage?
    /// How far the row content is slid left: 0 closed, -revealWidth revealed.
    @State private var slide: CGFloat = 0
    /// The slide position the current drag started from, captured when the
    /// drag locks horizontal.
    @State private var dragBase: CGFloat = 0
    /// Whether the current drag has locked horizontal. A vertical-dominant
    /// drag never sets it, so it never moves the row.
    @State private var dragLocked = false

    private static let revealWidth: CGFloat = 76
    /// Width of the leading tap zone that belongs to the select tick: the
    /// tick glyph plus the spacing that follows it.
    private static let tickZoneWidth: CGFloat = 48

    var body: some View {
        ZStack(alignment: .trailing) {
            // Delete tile, uncovered as the row slides left. The only real
            // button in the row, and only reachable while revealed — the
            // opaque content covers it completely when closed.
            Button(role: .destructive) { onDelete() } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                    Text("删除").font(.caption)
                }
                .foregroundStyle(.white)
                .frame(width: Self.revealWidth)
                .frame(maxHeight: .infinity)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 24)

                HStack(spacing: 12) {
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

                    VStack(alignment: .leading, spacing: 3) {
                        Text(pack.url.lastPathComponent).font(.subheadline.weight(.medium)).lineLimit(1)
                        HStack(spacing: 6) {
                            DriftPill(text: "\(pack.descriptorCount) 张")
                            DriftPill(text: pack.posterType.label)
                            if pack.isUnsafeContainer {
                                DriftPill(text: "含数据库 · 风险高", tint: .red)
                            }
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
            // Opaque on purpose: the translucent material this used to slide
            // on let the delete tile's text print through the row's own text
            // (the ghosting in Grace's recording, feedback #25).
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .offset(x: slide)
            .onTapGesture(coordinateSpace: .local) { location in
                handleTap(at: location)
            }
            .highPriorityGesture(swipeGesture)
        }
        .task {
            let url = await Task.detached { PosterBoardPreview.cover(for: pack) }.value
            if let url, let data = try? Data(contentsOf: url) {
                cover = UIImage(data: data)
            }
        }
    }

    /// The row's single drag: axis-locked, clamped, flick-aware.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if !dragLocked {
                    // Axis lock, judged on the cumulative translation: the
                    // row only joins a clearly horizontal drag. One that
                    // starts out vertical belongs to the page scroll and
                    // never moves the row at all.
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.2
                    else { return }
                    dragLocked = true
                    dragBase = slide
                }
                // Clamped at 0: a right swipe can never push the row past
                // closed, so from closed it does nothing, and from revealed
                // it only closes.
                slide = min(0, max(-Self.revealWidth, dragBase + value.translation.width))
            }
            .onEnded { value in
                defer { dragLocked = false }
                guard dragLocked else { return }
                // Flick-aware: judge by where the drag is heading, not just
                // where it stopped, so a fast short swipe reveals the tile
                // just as surely as a slow full one.
                let projected = dragBase + value.predictedEndTranslation.width
                withAnimation(.snappy) {
                    slide = projected < -Self.revealWidth / 2 ? -Self.revealWidth : 0
                }
            }
    }

    private func handleTap(at location: CGPoint) {
        // With the delete tile revealed, any tap on the row just closes it —
        // it never falls through to the tick or the detail page.
        if slide != 0 { closeSwipe(); return }
        if location.x < Self.tickZoneWidth { onToggle() } else { onOpen() }
    }

    private func closeSwipe() {
        withAnimation(.snappy) { slide = 0 }
        dragBase = 0
    }
}

/// Pack details: per-descriptor previews and the poster-type choice.
struct DriftPackDetail: View {
    let pack: PosterBoardTendie
    @Binding var imports: [PosterBoardTendie]
    @Binding var selection: PosterBoardSelection
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var identityMonitor: DeviceIdentityMonitor
    @State private var previews: [UIImage] = []
    @State private var packHasLegacy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if previews.isEmpty {
                        NativeNote("这个包提不出预览图（纯动画包只有动画文件、没有静态图时就会这样），不影响刷入。")
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(previews.enumerated()), id: \.offset) { _, image in
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(width: 150, height: 240)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("刷完出现在哪里").font(.subheadline.weight(.semibold))
                        Picker("刷完出现在哪里", selection: Binding(
                            get: { current.posterType },
                            set: { setType($0) }
                        )) {
                            ForEach(PosterBoardPosterType.allCases) { type in
                                Text(type.label).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                        // The explanation follows the selection: each kind
                        // says, in plain words, which gallery shelf it lands
                        // on — the provider names alone did not (Grace,
                        // 2026-11-09).
                        Text(current.posterType.blurb)
                            .font(.caption).foregroundStyle(.secondary)
                        Text("选错了不报错、只是不显示，回来改就行。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .driftCard()
                    // Feedback #22: the conversion answer used to be a
                    // one-way ratchet — asked once at flash time, stored
                    // forever, changeable nowhere (not even by deleting and
                    // re-importing). It is an ordinary setting here now.
                    // Shown only when the pack actually holds legacy
                    // content and the device runs a system that can need
                    // conversion (iOS 27+; an unread version also shows it,
                    // so a transient read failure cannot hide the setting).
                    if packHasLegacy && needsConversionUI {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("旧格式处理").font(.subheadline.weight(.semibold))
                            Picker("旧格式处理", selection: Binding(
                                get: { current.autoConvert ?? true },
                                set: { setConvert($0) }
                            )) {
                                Text("转换成新格式").tag(true)
                                Text("按原样安装").tag(false)
                            }
                            .pickerStyle(.segmented)
                            Text(LegacyConversionCopy.why)
                                .font(.caption).foregroundStyle(.secondary)
                            Text(LegacyConversionCopy.versions)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .driftCard()
                    }
                    if current.isUnsafeContainer {
                        NativeSafetyNote("这个包带着壁纸商店的数据库，属于「容器包」：刷入可能弄乱现有壁纸索引，只能用恢复式刷入。" + DriftRestoreGate.notice + "这类包只能走恢复式，目前刷不了。")
                    }
                    Button(role: .destructive) {
                        PosterBoardPreview.invalidate(for: current)
                        PosterBoardImports.remove(current)
                        imports.removeAll { $0.url == current.url }
                        selection.tendies.removeAll { $0.url == current.url }
                        dismiss()
                    } label: {
                        Label("删除这个包", systemImage: "trash")
                    }
                    .buttonStyle(.glass)
                }
                .padding(16)
            }
            .background { DriftBackground() }
            .navigationTitle(pack.url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                let urls = await Task.detached { PosterBoardPreview.previews(for: pack) }.value
                previews = urls.compactMap { (try? Data(contentsOf: $0)).flatMap(UIImage.init(data:)) }
                packHasLegacy = ((try? pack.legacyFamilies()) ?? []).isEmpty == false
            }
        }
    }

    private var current: PosterBoardTendie {
        imports.first { $0.url == pack.url } ?? pack
    }

    private func setType(_ type: PosterBoardPosterType) {
        let updated = current.settingPosterType(type)
        if let index = imports.firstIndex(where: { $0.url == updated.url }) {
            imports[index] = updated
        }
        if let index = selection.tendies.firstIndex(where: { $0.url == updated.url }) {
            selection.tendies[index] = updated
        }
    }

    /// The device's major version, or nil while identity is unread — the
    /// conversion UI shows unless the device is known to be on iOS 26,
    /// the one supported system that never converts (feedback #22).
    private var needsConversionUI: Bool {
        let version = identityMonitor.current.version
        guard let major = Int(version.split(separator: ".").first ?? "") else { return true }
        return major >= 27
    }

    private func setConvert(_ convert: Bool) {
        let updated = current.settingAutoConvert(convert)
        if let index = imports.firstIndex(where: { $0.url == updated.url }) {
            imports[index] = updated
        }
        if let index = selection.tendies.firstIndex(where: { $0.url == updated.url }) {
            selection.tendies[index] = updated
        }
    }
}

/// Chinese labels for the three store-reset modes (the enum's raw values are
/// the reference's English dialog names).
private func resetModeTitle(_ mode: PosterBoardResetMode) -> String {
    switch mode {
    case .collections: return "清理合集"
    case .suggestedPhotos: return "清理照片推荐"
    case .galleryCache: return "清理图库缓存"
    }
}
