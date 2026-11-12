import SwiftUI
import UniformTypeIdentifiers

/// The wallpaper page: connection state, the delivery-mode judgement,
/// imported packs with previews, the apply run, and the activation card.
struct DriftHomeView: View {
    @EnvironmentObject private var session: DriftSession
    @ObservedObject private var updateChecker = AppUpdateChecker.shared
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
    @State private var confirmRespring = false

    private var identity: DeviceIdentity { identityMonitor.current }
    /// The user's method pick (2.0.0: a method, never a channel).
    private var manualPick: DriftMethodPick {
        DriftMethodPick.fromStored(manualPickRaw)
    }
    /// The local channel's premise: the app's own system only. It never
    /// looks at the device read, pairing or the tunnel.
    private var localVersion: String { WorseQueryEscape.processVersion }
    private var localBuild: String { WorseQueryEscape.processBuildVersion }
    private var localReady: Bool {
        WorseQueryEscape.isAvailable(deviceVersion: localVersion, buildVersion: localBuild)
    }
    private var tunnelReady: Bool { tunnelMonitor.status == .ready }
    private var judgement: DriftModeJudgement {
        DriftJudge.judge(identity: identity, selection: selection, pick: manualPick,
                         tunnelReady: tunnelReady)
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
        if localReady {
            return "本机直刷可用（本机 \(SystemVersionName.display(version: localVersion, build: localBuild))）：现在就能刷，不用配对，也不用开隧道。"
        }
        if !identity.version.isEmpty { return identity.describe }
        return "本机直刷不可用；要走两条隧道通道，请导入配对文件并打开 LocalDevVPN。"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DriftBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        headerCard
                        tutorialEntryCard
                        if updateChecker.updateAvailable, let latest = updateChecker.latest {
                            updateHintCard(latest)
                        }
                        judgeCard
                        packsCard
                        applyCard
                        activationCard
                        RunLogCard()
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Drift")
            .navigationBarTitleDisplayMode(.large)
            // Collection #223 (Grace, 2026-11-12): no toolbar pairing
            // shortcut — it duplicated the status card's full-width
            // 「导入配对文件」button directly below it.
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

    /// The tutorial entry (collection #230, Grace 2026-11-12): in the gap
    /// between the status card and the method card, nowhere else — the
    /// setup wizard is unchanged and Settings carries no tutorial entry
    /// (#239).
    private var tutorialEntryCard: some View {
        NavigationLink {
            DriftTutorialView(states: DriftTutorialStates.current(
                identity: identity, tunnelReady: tunnelReady))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "book.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor,
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                // Grace (2026-11-12, on 3.0.11): no small print under
                // the tutorial entry — the title alone.
                Text("使用教程").font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .driftCard()
        }
        .buttonStyle(.plain)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The premises are listed per route, not as one global gate: the
            // in-process route only needs the app's own version and a granted
            // App Group, so pairing and the tunnel must not sit in front of it.
            HStack(spacing: 8) {
                DriftPill(text: localReady ? "本机直刷可用" : "本机直刷不可用",
                          tint: localReady ? .green : .orange)
                DriftPill(text: "本机 \(SystemVersionName.display(version: localVersion, build: localBuild))")
            }
            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !localReady {
                Text(InstallEnvironment.localReason(version: localVersion,
                                                    build: localBuild))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                DriftPill(text: "走隧道通道需要", tint: .secondary)
                DriftPill(text: session.paired ? "已配对" : "未配对",
                          tint: session.paired ? .green : .orange)
                DriftPill(text: tunnelMonitor.status == .ready ? "隧道已连通"
                          : tunnelMonitor.status == .interfaceUp ? "隧道等待对端"
                          : "隧道未连接",
                          tint: tunnelMonitor.status == .ready ? .green : .orange)
                if identity.version.isEmpty {
                    DriftPill(text: "隧道设备信息未读到", tint: .orange)
                } else {
                    DriftPill(text: "设备 \(SystemVersionName.display(version: identity.version, build: identity.buildVersion))")
                }
            }
            if !session.paired {
                Button { importingPairing = true } label: {
                    Label("导入配对文件（只走两条隧道通道时才需要）", systemImage: "link.badge.plus")
                }
                .driftGlassButton()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    private var judgeCard: some View {
        let judged = judgement
        return VStack(alignment: .leading, spacing: 10) {
            Text("刷入方式").font(.subheadline.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(DriftMethodPick.allCases) { pick in
                    methodRow(pick, judged)
                    if pick != DriftMethodPick.allCases.last {
                        Divider().padding(.leading, 34)
                    }
                }
            }
            Text(judged.reason)
                .font(.subheadline).foregroundStyle(.secondary)
            if !judged.expectedEffect.isEmpty && !judged.isBlocked {
                Label("预计生效：\(judged.expectedEffect)", systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.secondary)
            } else if judged.isBlocked, let blocked = judged.blockedReason {
                Text(blocked).font(.caption).foregroundStyle(.orange)
            }
            if !DriftRestoreGate.isEnabled {
                Button {
                    session.noticeTitle = "恢复刷（已封存）"
                    session.noticeText = DriftRestoreGate.notice
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.caption)
                        Text("恢复刷（已封存）").font(.caption.weight(.medium))
                        Spacer()
                        Text("点此看说明").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    /// One of the four method rows: a radio, the fixed name and its one-line
    /// description, and the channel's live status on the right.
    private func methodRow(_ pick: DriftMethodPick, _ judged: DriftModeJudgement) -> some View {
        let selected = manualPick == pick
        let option = pick.channel.flatMap { channel in
            judged.options.first { $0.mode == channel }
        }
        let available = pick == .auto ? !judged.isBlocked : (option?.available ?? false)
        // Sealed (collection #142): the version is in range but this
        // install's signing grants no usable App Group — the row stays
        // visible like the sealed restore entry, but it cannot be picked;
        // tapping it only explains why.
        let sealed = pick != .auto && (option?.sealed ?? false)
        let status: String
        if pick == .auto {
            status = judged.isBlocked ? "不可用" : "→ \(judged.mode.shortTitle)"
        } else if sealed {
            status = "不可选"
        } else {
            status = available ? "可用" : "不可用"
        }
        return Button {
            if sealed {
                session.noticeTitle = "本机直刷不可选"
                session.noticeText = option?.reason
                return
            }
            manualPickRaw = pick == .auto ? nil : pick.rawValue
            statusLine = nil
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: sealed ? "lock.fill"
                        : (selected ? "largecircle.fill.circle" : "circle"))
                    .font(.title3)
                    .foregroundStyle(selected && !sealed ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pick.label).font(.subheadline.weight(.medium))
                        if pick.isExperimental {
                            Text("实验")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.16),
                                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(pick.subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if pick != .auto, let option, !option.available {
                        Text(option.reason)
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                Text(status)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(available ? Color.green : Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var packsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // #209 (Grace, 2026-11-12): no separate import button — the
            // packs area itself is tapped to import.
            HStack {
                Text("壁纸包").font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "plus.circle").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { importingTendies = true }
            if imports.isEmpty {
                Text("还没有导入壁纸包。点这里选 .tendies 文件导入，或在「文件」App 里对壁纸包点打开方式选 Drift。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { importingTendies = true }
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
                    .driftGlassButton()
            }
            if let statusLine {
                Text(statusLine).font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A written wallpaper that is not visible yet is not a failed run:
            // the user decides whether to respring. Drift never does it itself.
            if session.lastEffect?.needsManualRespring == true {
                Button {
                    Task {
                        let triggered = await MainActor.run { NeoSpring.trigger() }
                        statusLine = triggered
                            ? "已触发注销；PosterBoard 重新启动后会读到新壁纸。"
                            : "现在没有可用的窗口触发注销，请手动从系统里注销一次。"
                    }
                } label: {
                    Label("手动注销", systemImage: "arrow.clockwise.circle")
                }
                .driftGlassButton()
            }
            if judgement.mode == .worseQuery {
                NativeNote("本机直刷在本机写入，不需要配对文件，也不用开隧道。刷完先打开 PosterBoard 刷新集合，再从应用切换器上滑关闭它，系统重新拉起后壁纸生效。App 不会自动注销。")
            } else if !session.paired {
                NativeNote("两条隧道通道都需要先导入配对文件；本机直刷不需要，但只有证书签名才能用。")
            } else if selection.tendies.isEmpty && !imports.isEmpty {
                NativeNote("在上面的列表里点圆圈勾选要刷的包。")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    /// Refresh & Apply: the two ways to make a written wallpaper take
    /// effect when it has not appeared yet. The light one is gated on the
    /// local channel's premise (the same `localReady` the header card
    /// shows); the heavy one is the manual respring, confirmed first and
    /// unavailable while a run is going.
    private var activationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("刷新与生效").font(.subheadline.weight(.semibold))
            Text("刷完壁纸还没生效时用这里。")
                .font(.subheadline).foregroundStyle(.secondary)
            NativePrimaryButton(title: "结束 PosterBoard",
                                systemImage: "arrow.triangle.2.circlepath",
                                running: false,
                                disabled: !localReady) {
                openPosterBoard()
            }
            if !localReady {
                Text(InstallEnvironment.localReason(version: localVersion,
                                                    build: localBuild))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                confirmRespring = true
            } label: {
                Label("注销", systemImage: "arrow.clockwise.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .driftGlassButton()
            .controlSize(.large)
            .disabled(session.running)
            .driftActionSheet(isPresented: $confirmRespring, title: "确认注销？",
                              message: "将立即注销，界面会重启一遍，壁纸在重启后生效。",
                              actions: [
                                DriftSheetAction("立即注销", destructive: true) { respringNow() },
                              ])
            if session.running {
                Text("正在刷入，刷完再注销。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            NativeNote("隧道通道（免注销 / 注销直刷）刷完会自动处理生效，不用在这里操作。")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
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

    /// The launch auto-check's only Home footprint: a slim line, no
    /// popup, no action of its own — the download lives in 设置 → 检查更新.
    private func updateHintCard(_ latest: AppUpdateChecker.ReleaseInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
            Text("有新版 Drift \(latest.displayVersion)，到「设置 → 检查更新」下载。")
                .font(.subheadline)
            Spacer()
        }
        .padding(12)
        .driftCard()
    }

    private func runApply() {
        // The cover goes up on the tap itself (Grace, 2026-11-11): the
        // identity refresh, the re-judgement and the channel's own search
        // all happen underneath it, for every channel.
        session.flashCover = true
        // Feedback #30: a blocked judgement starts nothing — the tap
        // only explains. (The session funnel refuses restore runs too,
        // but a blocked selection must never even be shaped into one.)
        if judgement.isBlocked {
            session.flashCover = false
            session.errorText = judgement.blockedReason
            return
        }
        var runSelection = selection
        runSelection.resetModes = []
        runSelection.fullReset = false
        Task {
            defer { session.flashCover = false }
            // Collection #228: judge once on the state already on
            // screen. A run that resolves to the local channel goes
            // straight in: the local channel judges the app's own
            // system, so the tunnel identity read cannot change its
            // answer — and when the tunnel is down that read retries
            // for up to ~15 s, which was pure delay at the head of
            // every local flash (the flash itself takes ~0.2 s).
            var checked = DriftJudge.judge(identity: identity, selection: runSelection,
                                           pick: manualPick, tunnelReady: tunnelReady)
            if checked.isBlocked || checked.mode != .worseQuery {
                // Anything else still re-checks before touching
                // anything: refresh the device identity when a tunnel
                // is configured, then re-run the judgement on the
                // state as it is now. The card's answer is not the
                // run's answer if the device was updated or the tunnel
                // dropped in between.
                if session.paired { await session.refreshIdentity() }
                checked = DriftJudge.judge(identity: identity, selection: runSelection,
                                           pick: manualPick, tunnelReady: tunnelReady)
            }
            if checked.isBlocked {
                session.errorText = checked.blockedReason
                return
            }
            let outcome = await session.run(selection: runSelection, mode: checked.mode,
                                            pick: manualPick, identity: identity)
            if outcome.ok {
                statusLine = outcome.message
            } else {
                statusLine = nil
                session.errorText = outcome.message
            }
        }
    }

    /// The activation card's light option: bring PosterBoard forward so
    /// the user can end it from the app switcher. The app launches it;
    /// ending it is the user's swipe — the copy says exactly that.
    private func openPosterBoard() {
        Task {
            let opened = await MainActor.run { PosterBoardLaunch.open() }
            statusLine = opened
                ? "已打开 PosterBoard 以刷新集合，请从应用切换器中关闭它，然后检查锁定屏幕壁纸选择器。"
                : "请打开锁定屏幕壁纸选择器来刷新 PosterBoard；如果壁纸未出现，请从应用切换器关闭 PosterBoard 后重试。"
        }
    }

    /// The activation card's heavy option: the same manual respring the
    /// post-run button offers, behind the card's confirmation.
    private func respringNow() {
        Task {
            let triggered = await MainActor.run { NeoSpring.trigger() }
            statusLine = triggered
                ? "已触发注销；PosterBoard 重新启动后会读到新壁纸。"
                : "现在没有可用的窗口触发注销，请手动从系统里注销一次。"
        }
    }

    private func handleTendiesPick(_ urls: [URL]) {
        var problemPacks: [String] = []
        for url in urls {
            do {
                let tendie = try PosterBoardImports.import(from: url)
                if !imports.contains(where: { $0.url == tendie.url }) {
                    imports.append(tendie)
                }
                if !PackRepair.blockingIssues(of: tendie).isEmpty {
                    problemPacks.append(tendie.name)
                }
                Task.detached { _ = PosterBoardPreview.previews(for: tendie) }
            } catch {
                session.errorText = error.localizedDescription
            }
        }
        imports = PosterBoardImports.load()
        if !problemPacks.isEmpty {
            session.noticeTitle = "有壁纸包需要修一下"
            session.noticeText = problemPacks.map { "「\($0)」" }.joined(separator: "、")
                + "的结构有点问题，现在刷可能会找不到壁纸。点开它的详细页，里面有「壁纸修复」可以修。"
        }
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
                        Text(pack.url.lastPathComponent).font(.subheadline.weight(.medium)).lineLimit(2)
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
    @EnvironmentObject private var session: DriftSession
    @State private var previews: [UIImage] = []
    @State private var packHasLegacy = false
    @State private var repairAlert: RepairAlert?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(current.name)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
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
                        NativeSafetyNote("这个包带着壁纸商店的数据库，属于「容器包」：刷入可能弄乱现有壁纸索引，只能用恢复刷刷入。" + DriftRestoreGate.notice + "这类包只能走恢复刷；恢复刷已封存，目前刷不了。")
                    }
                    HStack(spacing: 12) {
                        Button(role: .destructive) {
                            PosterBoardPreview.invalidate(for: current)
                            PosterBoardImports.remove(current)
                            imports.removeAll { $0.url == current.url }
                            selection.tendies.removeAll { $0.url == current.url }
                            dismiss()
                        } label: {
                            Label("删除这个包", systemImage: "trash")
                        }
                        .driftGlassButton()
                        if PackRepair.isRepaired(current) {
                            Label("已修复", systemImage: "checkmark.circle")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        } else {
                            Button {
                                runRepair()
                            } label: {
                                Label("壁纸修复", systemImage: "wrench.and.screwdriver")
                            }
                            .driftGlassButton()
                        }
                    }
                }
                .padding(16)
            }
            .background { DriftBackground() }
            .navigationTitle("壁纸详情")
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
            .overlay {
                if session.cover == .repairing {
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
                        .background(.regularMaterial,
                                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }
                    .transition(.opacity)
                }
            }
            .alert(item: $repairAlert) { item in
                switch item {
                case .done(let name):
                    return Alert(title: Text("修好了"),
                                 message: Text("修好的包已放进壁纸列表，名字是「\(name)」。请返回主页查看。"),
                                 dismissButton: .default(Text("知道了")))
                case .noneNeeded:
                    return Alert(title: Text("壁纸修复"),
                                 message: Text("这个包没查到需要修的毛病，无需修复。"),
                                 dismissButton: .default(Text("知道了")))
                }
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

    /// The repair button's outcome, shown as an alert (#210): a new
    /// (patched) pack in the list, or 无需修复 when nothing was wrong.
    private enum RepairAlert: Identifiable {
        case done(String)
        case noneNeeded
        var id: String {
            switch self {
            case .done(let name): return "done-\(name)"
            case .noneNeeded: return "none-needed"
            }
        }
    }

    private func runRepair() {
        let target = current
        guard !PackRepair.inspect(target).isEmpty else {
            repairAlert = .noneNeeded
            return
        }
        let version = identityMonitor.current.version.isEmpty
            ? WorseQueryEscape.processVersion : identityMonitor.current.version
        session.cover = .repairing
        session.coverProgress = 0
        Task {
            defer { session.cover = nil; session.coverProgress = nil }
            do {
                let repaired = try await Task.detached {
                    try PackRepair.repair(target, deviceVersion: version) { phase in
                        Task { @MainActor in DriftSession.shared.coverProgress = phase }
                    }
                }.value
                if !imports.contains(where: { $0.url == repaired.url }) {
                    imports.append(repaired)
                }
                repairAlert = .done(repaired.name)
            } catch {
                session.errorText = error.localizedDescription
            }
        }
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

