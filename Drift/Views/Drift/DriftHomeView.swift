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
    /// The 内核直刷 switch from 实验性功能 (#329): while it is off the
    /// method does not exist on this page at all.
    @AppStorage(KernelDirectPremise.enabledKey) private var kernelEnabled = false

    @State private var imports: [PosterBoardTendie] = PosterBoardImports.load()
    @State private var importingPairing = false
    @State private var statusLine: String?
    @State private var confirmRespring = false
    /// The restore write-back's danger confirmation (Alpha line).
    @State private var confirmRestoreWriteBack = false
    /// #337 (Grace, 2026-11-16): the signature notice's entry
    /// window state — see `openEntryWindow()`.
    @State private var signatureNotice = false
    @State private var signatureNoticeDone = false
    @State private var entryWindowOpen = false
    @State private var entryWindowGeneration = 0
    @State private var didFirstAppear = false
    @Environment(\.scenePhase) private var scenePhase

    private var identity: DeviceIdentity { identityMonitor.current }
    /// The user's method pick (2.0.0: a method, never a channel).
    private var manualPick: DriftMethodPick {
        // The stored pick stands as-is (Grace, 2026-11-15): the
        // kernel row is always shown and selectable, and the judge
        // answers a kernel pick whose switch is off with a
        // go-turn-it-on reminder — the pick is never rewritten.
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
    /// The method rows to draw: every pick, always — 内核直刷
    /// included (Grace, 2026-11-15, replacing the #329
    /// hide-while-off rule). Supported devices show it 可用 and
    /// can pick it with the switch on or off; the switch is
    /// enforced at the flash tap, with a reminder.
    private var visiblePicks: [DriftMethodPick] {
        DriftMethodPick.allCases
    }
    private var selectedDescriptors: Int { selection.tendies.reduce(0) { $0 + $1.descriptorCount } }
    private var overLimit: Bool { selectedDescriptors > PosterBoardImports.descriptorLimit }
    private var canApply: Bool {
        // Kernel Direct writes the selected descriptor packs directly into
        // PosterBoard's container; no pairing or tunnel is required. On a
        // supported device the button stays tappable even while the
        // 实验性功能 switch is off — the tap then answers with the
        // go-turn-it-on reminder (Grace, 2026-11-15). An unsupported
        // device cannot tap it at all.
        if manualPick == .kernel {
            return kernelPremiseReady && !selection.tendies.isEmpty && !overLimit
                && selection.video == nil && !selection.fullReset
                && selection.resetModes.isEmpty && !session.running
        }
        // 自动选择 blocked only by the kernel switch: same deal — the
        // tap must reach the reminder.
        if judgement.kernelNeedsSwitch {
            return !selection.tendies.isEmpty && !overLimit && !session.running
        }
        // A restore pick blocked only by its switch: same deal
        // (Grace, 2026-11-19).
        if judgement.restoreNeedsSwitch {
            return !selection.tendies.isEmpty && !overLimit && !session.running
        }
        // The in-process route is the one path that does not need a pairing
        // record; every other mode still does.
        return (session.paired || judgement.mode == .worseQuery)
            && !selection.tendies.isEmpty && !overLimit && !session.running
    }
    /// The kernel channel's premise, judged on this device alone.
    /// Ready only when the user turned it on in 实验性功能 and this
    /// device is in its band and offset table (#319/#329).
    private var kernelReady: Bool {
        kernelEnabled && kernelPremiseReady
    }

    /// Supported-or-not, device only: iOS 17 / 18 band and the model
    /// in the offset table. The switch is not part of this — a
    /// supported device shows 可用 and can be picked either way
    /// (Grace, 2026-11-15).
    private var kernelPremiseReady: Bool {
        KernelDirectPremise.evaluate(version: localVersion).ready
    }

    /// The generations the kernel method belongs to (iOS 17 / 18),
    /// whether or not this system sits inside its band (#338).
    private var isKernelGeneration: Bool {
        let major = Int(localVersion.split(separator: ".").first ?? "") ?? 0
        return major == 17 || major == 18
    }

    /// #337's three conditions at once: the local channel is
    /// blocked by the signature alone (system in range, no usable
    /// storage area in the signature) and neither tunnel channel
    /// is available either — the user has no working route, and
    /// the signature is the one thing standing in the way.
    private var signatureNoticeApplies: Bool {
        InstallEnvironment.blockedBySignatureOnly(version: localVersion, build: localBuild)
            && !judgement.options.contains {
                ($0.mode == .direct || $0.mode == .airlift) && $0.available
            }
    }

    private var headerSubtitle: String {
        if kernelReady {
            return "内核直刷可用（本机 \(SystemVersionName.display(version: localVersion, build: localBuild))）：选择壁纸包后直接写入 PosterBoard 容器。"
        }
        if localReady {
            return "本机直刷可用（本机 \(SystemVersionName.display(version: localVersion, build: localBuild))）：现在就能刷，不用配对，也不用开隧道。"
        }
        if !identity.version.isEmpty { return identity.describe }
        return "本机直刷不可用；要走两条隧道通道，请导入配对文件并打开 LocalDevVPN。"
    }

    /// #337 (Grace, 2026-11-16): every entry into the app opens a
    /// short window in which the signature notice may present
    /// once. The window gives the verdicts (device read, tunnel
    /// state) a moment to settle before anything is concluded
    /// from them, and it closes soon after entry, so a tunnel
    /// dropping mid-session never pops the notice later.
    private func openEntryWindow() {
        signatureNoticeDone = false
        entryWindowOpen = true
        entryWindowGeneration += 1
        let generation = entryWindowGeneration
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if generation == entryWindowGeneration {
                presentSignatureNoticeIfNeeded()
            }
            try? await Task.sleep(nanoseconds: 8_500_000_000)
            if generation == entryWindowGeneration {
                entryWindowOpen = false
            }
        }
    }

    private func presentSignatureNoticeIfNeeded() {
        guard entryWindowOpen, !signatureNoticeDone, !signatureNotice,
              !session.running, !session.flashCover,
              signatureNoticeApplies else { return }
        signatureNoticeDone = true
        signatureNotice = true
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DriftBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        // #340 (Grace, 2026-11-16): a nightly package says
                        // so beside the app name. The name stays in the
                        // large title's place at the same size — this row
                        // is drawn where the system large title sits, with
                        // an orange 「预发行版」 to its right; the name
                        // itself never moves. Release builds keep the
                        // system large title and never show this row.
                        // The Alpha research line (Grace, 2026-11-19)
                        // wears a red "Alpha-test" in the same place, and
                        // a red warning banner under it: the restore
                        // route inside is unverified research.
                        if AppVersion.channel != .release {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("Drift")
                                    .font(.largeTitle)
                                    .fontWeight(.bold)
                                if AppVersion.channel == .alpha {
                                    Text("Alpha-test")
                                        .font(.headline)
                                        .foregroundStyle(.red)
                                } else {
                                    Text("预发行版")
                                        .font(.headline)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if AppVersion.channel == .alpha {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("研究包：恢复刷未验证，勿在主力机使用")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.red,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        headerCard
                        tutorialEntryCard
                        if updateChecker.updateAvailable, let latest = updateChecker.latest {
                            updateHintCard(latest)
                        }
                        judgeCard
                        actionFrame
                        if let dryRun = session.pendingRestoreDryRun {
                            restoreDryRunCard(dryRun)
                        }
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
            .navigationTitle(AppVersion.channel == .release ? "Drift" : "")
            .navigationBarTitleDisplayMode(AppVersion.channel == .release ? .large : .inline)
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
            .driftActionSheet(isPresented: $signatureNotice,
                              title: "本机直刷不可用",
                              message: InstallEnvironment.noUsableGroupReason,
                              actions: [DriftSheetAction("知道了") {}])
            .driftActionSheet(isPresented: $confirmRestoreWriteBack,
                              title: "确认写回？",
                              message: "写回会把干跑备好的恢复包真正恢复到这台设备上。可能出现的情况：\n· 顺利：重启后新壁纸生效，其他数据不动。\n· 设备拒绝或中途失败：壁纸不变，一般不会丢数据，但要重新干跑。\n· 最坏：恢复异常导致设备恢复出厂、数据全丢（2026-11-10 发生过一次）。\n只在已经用电脑完整备份过的备用机上写回，主力机不要写回。",
                              actions: [DriftSheetAction("确认写回") { runRestoreWriteBack() }])
            .onAppear {
                AppLog.op("打开壁纸页")
                if !didFirstAppear {
                    didFirstAppear = true
                    openEntryWindow()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { openEntryWindow() }
            }
            .onChange(of: signatureNoticeApplies) { _, _ in
                presentSignatureNoticeIfNeeded()
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
            DriftFlowLayout {
                // With the kernel method on and ready it leads the
                // card (#329, Grace 2026-11-14: 「最上面就应该显示
                // 内核直刷可用」); otherwise the local channel's
                // verdict leads, as before.
                if kernelReady {
                    DriftPill(text: "内核直刷可用", tint: .green)
                } else {
                    DriftPill(text: localReady ? "本机直刷可用" : "本机直刷不可用",
                              tint: localReady ? .green : .orange)
                    // #338 (Grace, 2026-11-16): on iOS 17 / 18 the
                    // card also carries the kernel method's state.
                    // Until now it said nothing about the kernel
                    // here, so a 17/18 user with the switch off saw
                    // only the local and tunnel verdicts and never
                    // learnt the kernel route existed but was off.
                    if isKernelGeneration {
                        DriftPill(text: "内核直刷不可用", tint: .orange)
                    }
                }
                DriftPill(text: "本机 \(SystemVersionName.display(version: localVersion, build: localBuild))")
            }
            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !localReady && !kernelReady {
                Text(InstallEnvironment.localReason(version: localVersion,
                                                    build: localBuild))
                    .font(.caption).foregroundStyle(.secondary)
            }
            DriftFlowLayout { tunnelPills }
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
                ForEach(visiblePicks) { pick in
                    methodRow(pick, judged)
                    if pick.id != visiblePicks.last?.id {
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
            // Grace (2026-11-19, later the same day): the restore row
            // is a real pick now — selectable, badged 实验， judged
            // like the kernel pick with a go-turn-it-on reminder. It
            // renders through `methodRow` with the other picks; the
            // sealed-route row it replaces is gone. The seal itself
            // is unchanged.
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftCard()
    }

    /// One of the method rows: a radio, the fixed name and its one-line
    /// description, and the channel's live status on the right.
    private func methodRow(_ pick: DriftMethodPick, _ judged: DriftModeJudgement) -> some View {
        let selected = manualPick == pick
        let option = pick.channel.flatMap { channel in
            judged.options.first { $0.mode == channel }
        }
        // The kernel pick has no channel row in the judgement; its
        // availability is its own premise, judged on this device.
        let kernelEval = pick == .kernel
            ? KernelDirectPremise.evaluate(version: localVersion) : nil
        // The kernel row's 可用 is about the device alone (Grace,
        // 2026-11-15): supported shows 可用 whether or not the
        // 实验性功能 switch is on; the switch only bites at the
        // flash tap, as a reminder.
        let available = pick == .auto ? (!judged.isBlocked || judged.kernelNeedsSwitch)
            : (kernelEval?.ready ?? (option?.available ?? false))
        // Sealed (collection #142): the version is in range but this
        // install's signing grants no usable App Group — the row stays
        // visible like the sealed restore entry, but it cannot be picked;
        // tapping it only explains why.
        let sealed = pick != .auto && (option?.sealed ?? false)
        let status: String
        if pick == .auto {
            status = judged.kernelNeedsSwitch ? "→ 内核直刷（实验）"
                : (judged.isBlocked ? "不可用"
                    : (judged.useKernel ? "→ 内核直刷（实验）" : "→ \(judged.mode.shortTitle)"))
        } else if sealed {
            status = "不可选"
        } else if pick == .kernel {
            status = available ? "可用" : "不支持"
        } else if pick == .restore {
            // The restore pick is selectable like the kernel pick,
            // but there is no device premise to judge — while the
            // route is sealed its honest state is 不可用； the switch
            // reminder bites at the flash tap (Grace, 2026-11-19).
            status = "不可用"
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
                    if let kernelEval, !kernelEval.ready {
                        Text(kernelEval.reason)
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

    /// The shared shape of Home's long bars (#266/#280): the
    /// usable-state blue, white centred content, no chevron. A flat
    /// fill again since the glass-unification round (2026-11-13) —
    /// the tinted liquid glass of #286 is gone.
    ///
    /// Collection #326 (Grace, 2026-11-14): all four of Home's bars
    /// — these two navigation bars and the two action buttons below
    /// (`homeBarButton`) — share this one fixed height, so the set
    /// reads as one size. The buttons used to be
    /// `NativePrimaryButton`, whose shared style pads less, and the
    /// refresh card insets more than the action frame, so no two of
    /// the four matched.
    private func homeBarLabel(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.headline)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .driftGlassCapsule(tint: .accentColor)
    }

    /// One of Home's long bars as a button (#326): the same 50pt
    /// bar `homeBarLabel` draws, with the running spinner and the
    /// disabled dimming the shared primary button used to give it.
    private func homeBarButton(icon: String, title: String,
                               running: Bool = false, disabled: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if running {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .driftGlassCapsule(tint: .accentColor)
            .opacity(disabled || running ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled || running)
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
            homeBarButton(icon: "paintbrush.pointed",
                          title: session.running ? "刷入中…" : "刷入",
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
            if manualPick == .kernel || judgement.useKernel {
                NativeNote("内核直刷会把已选壁纸描述文件写入 PosterBoard 容器并逐项核验；写入后会打开 PosterBoard，可上滑结束它，也可使用下方「注销」方式生效。")
            } else if judgement.mode == .worseQuery {
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
            // The same width as the three bars in the action frame
            // above (#326): this card insets its content by 16 where
            // the frame insets 12, so the bar pulls out by the
            // difference and all four line up.
            homeBarButton(icon: "arrow.triangle.2.circlepath",
                          title: "结束 PosterBoard",
                          disabled: !(localReady || ((manualPick == .kernel || judgement.useKernel) && kernelReady))) {
                openPosterBoard()
            }
            .padding(.horizontal, -4)
            if !localReady && !((manualPick == .kernel || judgement.useKernel) && kernelReady) {
                Text(InstallEnvironment.localReason(version: localVersion,
                                                    build: localBuild))
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Collection #327 (Grace, 2026-11-14): no capsule —
            // just the icon and the word, centred, and only that
            // cluster takes taps (the centring spacers sit outside
            // the button). The confirmation sheet is unchanged.
            HStack {
                Spacer()
                Button {
                    confirmRespring = true
                } label: {
                    Label("注销", systemImage: "arrow.clockwise.circle")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                .disabled(session.running)
                Spacer()
            }
            .driftActionSheet(isPresented: $confirmRespring, title: "确认注销？",
                              message: "将立即注销，界面会重启一遍，壁纸在重启后生效。",
                              actions: [
                                DriftSheetAction("立即注销", destructive: true) { respringNow() },
                              ])
            if session.running {
                Text("正在刷入，刷完再注销。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if manualPick == .kernel || judgement.useKernel {
                NativeNote("内核直刷写完后，用这两种办法生效：上滑结束 PosterBoard，或者注销。")
            } else {
                NativeNote("隧道通道（免注销 / 注销直刷）刷完会自动处理生效，不用在这里操作。")
            }
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
            // Blocked only by the kernel switch (Grace, 2026-11-15):
            // this tap is the reminder moment — a notice pointing at
            // 实验性功能, not an error.
            if judgement.kernelNeedsSwitch {
                session.noticeTitle = "内核直刷还没有打开"
                session.noticeText = "请先到「设置 → 实验性功能」里打开内核直刷，再回来刷入。"
            } else if judgement.restoreNeedsSwitch {
                // The restore pick's reminder moment, same shape
                // (Grace, 2026-11-19).
                session.noticeTitle = "恢复刷还没有打开"
                session.noticeText = "请先到「设置 → 实验性功能」里打开恢复刷，再回来刷入。"
            } else {
                session.errorText = judgement.blockedReason
            }
            return
        }
        var runSelection = selection
        runSelection.resetModes = []
        runSelection.fullReset = false
        // Kernel Direct has its own on-device write flow. It verifies the
        // real PosterBoard container first, then writes the selected packs;
        // no channel mode, pairing record or tunnel is involved. Dispatch
        // follows the judgement alone, never the raw stored pick: a kernel
        // pick with its 实验性功能 switch off judges as blocked (the
        // reminder above) and never reaches this point (Grace, 2026-11-15).
        if judgement.useKernel {
            Task {
                defer { session.flashCover = false }
                // Re-judge on the state as it is now, like every other
                // channel's run below: the card's answer is not the run's
                // answer if the switch or the premises moved in between.
                let fresh = DriftJudge.judge(identity: identity, selection: selection,
                                             pick: manualPick, tunnelReady: tunnelReady)
                if fresh.isBlocked {
                    session.errorText = fresh.blockedReason
                    return
                }
                guard fresh.useKernel else {
                    session.errorText = "刷入方式的判定刚刚变了，这次没有刷入。请再点一次「刷入」。"
                    return
                }
                let outcome = await session.runKernelApply(identity: identity,
                                                            selection: selection)
                if outcome.ok {
                    statusLine = outcome.message
                } else {
                    statusLine = nil
                    session.errorText = outcome.message
                }
            }
            return
        }
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
                if outcome.message.hasPrefix("这次没找到壁纸商店") {
                    session.presentError(outcome.message, retry: { self.runApply() })
                } else {
                    session.errorText = outcome.message
                }
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
                ? "已打开 PosterBoard 以刷新集合，请在应用切换器里上滑结束它，然后检查锁定屏幕壁纸选择器。"
                : "请打开锁定屏幕壁纸选择器来刷新 PosterBoard；如果壁纸未出现，请在应用切换器里上滑结束 PosterBoard 后重试。"
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

    /// The restore dry-run card (Alpha line): what the dry run
    /// prepared, and the two ways out — write it back (behind the
    /// danger confirmation) or throw it away. Shown only while a dry
    /// run is pending; the session clears it on either outcome.
    private func restoreDryRunCard(_ report: RestoreDryRunReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("恢复刷 · 干跑完成")
                    .font(.subheadline.weight(.semibold))
                Text("还没写回")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.red.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(.red)
            }
            Text("已拉取设备清单并对账通过：将写回 \(report.packageFileCount) 个文件（共 \(ByteCountFormatter.string(fromByteCount: report.packageBytes, countStyle: .file))），其中这次新做的 \(report.payloadCount) 个。干跑指纹 \(report.fingerprintShort)，写回前会再验一次，对不上就取消。")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    confirmRestoreWriteBack = true
                } label: {
                    Label("确认写回", systemImage: "arrow.up.doc")
                }
                .driftGlassButton()
                .disabled(session.running)
                Button("放弃") {
                    session.discardRestoreDryRun()
                    statusLine = "已放弃这次干跑，什么都没有写回。"
                }
                .driftGlassButton()
                .disabled(session.running)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .driftGlassSlab()
    }

    /// The dry-run card's confirmed write-back: same outcome
    /// presentation as a flash run (status line on success, error
    /// notice on failure).
    private func runRestoreWriteBack() {
        Task {
            let outcome = await session.runRestoreWriteBack(identity: identity)
            if outcome.ok {
                statusLine = outcome.message
            } else {
                statusLine = nil
                session.errorText = outcome.message
            }
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
