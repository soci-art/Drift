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
    @State private var importingPairing = false
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
                        actionFrame
                        activationCard
                        // Collection #289 (Grace, 2026-11-13): no log
                        // card on this page any more — the log is still
                        // recorded in full (#272) and still lives in
                        // Settings; it just isn't displayed here.
                    }
                    .padding(16)
                    .driftPageWidth()
                }
            }
            .navigationTitle("Drift")
            .navigationBarTitleDisplayMode(.large)
            // Collection #223 (Grace, 2026-11-12): no toolbar pairing
            // shortcut — it duplicated the status card's full-width
            // 「导入配对文件」button directly below it.
            // UIKit pickers, not SwiftUI `fileImporter` — see
            // `DocumentPicker` for the tap-swallowing failure that moved
            // these. A pick or a cancel always lands back here. (The
            // wallpaper-pack picker lives on the pack list page now,
            // #266 — this page keeps only the pairing one.)
            .sheet(isPresented: $importingPairing) {
                DocumentPicker(contentTypes: PairingRecord.types) { urls in
                    importingPairing = false
                    handlePairingPick(urls)
                } onCancel: {
                    importingPairing = false
                }
            }
            .onAppear { AppLog.op("打开壁纸页") }
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    DriftPill(text: localReady ? "本机直刷可用" : "本机直刷不可用",
                              tint: localReady ? .green : .orange)
                    DriftPill(text: "本机 \(SystemVersionName.display(version: localVersion, build: localBuild))")
                }
                VStack(alignment: .leading, spacing: 6) {
                    DriftPill(text: localReady ? "本机直刷可用" : "本机直刷不可用",
                              tint: localReady ? .green : .orange)
                    DriftPill(text: "本机 \(SystemVersionName.display(version: localVersion, build: localBuild))")
                }
            }
            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !localReady {
                Text(InstallEnvironment.localReason(version: localVersion,
                                                    build: localBuild))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { tunnelPills }
                VStack(alignment: .leading, spacing: 6) { tunnelPills }
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

    @ViewBuilder
    private var tunnelPills: some View {
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

    /// Collection #266 (Grace, 2026-11-13): the whole packs section is
    /// one long blue bar, like the flash button — blue, white, centred,
    /// no count, no chevron (her explicit word on both). Tapping it
    /// opens the pack list page, where the packs now live (#268).
    private var packsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                PackListView(imports: $imports, selection: $selection)
            } label: {
                homeBarLabel(icon: "photo.on.rectangle.angled", title: "壁纸包")
            }
            .buttonStyle(.plain)
            if imports.isEmpty {
                Text("还没有导入壁纸包。点上面的「壁纸包」进去导入。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !selection.tendies.isEmpty {
                Text("已选 \(selection.tendies.count) 个包，共 \(selectedDescriptors) 张（一次最多 \(PosterBoardImports.descriptorLimit) 张）")
                    .font(.caption)
                    .foregroundStyle(overLimit ? .red : .secondary)
            }
        }
    }

    /// Collection #280 (Grace, 2026-11-13): the store manager's entry
    /// moved here from Settings — same blue bar as the packs bar,
    /// directly under the flash button, and the page itself is renamed
    /// 本机壁纸管理.
    private var managerBar: some View {
        NavigationLink {
            PosterBoardManagerView()
        } label: {
            homeBarLabel(icon: "square.stack.3d.up", title: "本机壁纸管理")
        }
        .buttonStyle(.plain)
    }

    /// The shared shape of Home's two long bars (#266/#280): the
    /// usable-state blue, white centred content, no chevron. A flat
    /// fill again since the glass-unification round (2026-11-13) —
    /// the tinted liquid glass of #286 is gone.
    private func homeBarLabel(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.headline)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .driftGlassCapsule(tint: .accentColor)
    }

    /// Collection #286 (Grace, 2026-11-13): the packs bar, the flash
    /// section and the manager bar live inside ONE frame, all three
    /// the same width. Before, the two bars ran full-bleed while the
    /// flash section sat inside its own card, so the three read as
    /// mismatched lengths (her screenshot: both blue bars poking out
    /// past the card's edges). Inside one padded frame the equal
    /// width is structural. The frame's surface is the cards' own
    /// material and the bars inside are flat fills since the
    /// glass-unification round (#302, render ②, 2026-11-13).
    private var actionFrame: some View {
        VStack(spacing: 12) {
            packsBar
            applySection
            managerBar
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .driftGlassSlab()
    }

    /// The flash controls, without a card of their own since #286 —
    /// the action frame is the surface now.
    private var applySection: some View {
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

    // Pack selection, deletion, import and the legacy-conversion answer
    // moved to the pack list page with the list itself (#266/#268) —
    // see PackListView. Home keeps the flash run and the pairing pick.

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
        AppLog.op("点刷入：\(selection.tendies.map(\.name).joined(separator: "、"))（方式：\(manualPick.label)）")
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
