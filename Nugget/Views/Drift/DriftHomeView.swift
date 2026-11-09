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
    private var judgement: DriftModeJudgement {
        DriftJudge.judge(identity: identity, selection: selection, pick: manualPick)
    }
    private var selectedDescriptors: Int { selection.tendies.reduce(0) { $0 + $1.descriptorCount } }
    private var overLimit: Bool { selectedDescriptors > PosterBoardImports.descriptorLimit }
    private var canApply: Bool {
        session.paired && !selection.tendies.isEmpty && !overLimit && !session.running
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
                DocumentPicker(contentTypes: [UTType("com.sociart.drift.tendies") ?? .zip],
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
            Text(identity.version.isEmpty
                 ? "导入配对文件、打开 LocalDevVPN 后，这里会显示设备系统。"
                 : "\(identity.describe)")
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
                    Button("自动判断") { manualPickRaw = nil; statusLine = nil }
                    Button("直刷（只注销）") { manualPickRaw = PosterBoardApplyMode.airlift.rawValue; statusLine = nil }
                    Button("恢复式（会重启）") { manualPickRaw = PosterBoardApplyMode.backup.rawValue; statusLine = nil }
                } label: {
                    // The control names the **pick**, not the outcome: it used
                    // to render `judged.mode`, so with a hard limit in force
                    // (no pairing → no identity → restore forced) the button
                    // read 恢复式 no matter what was tapped, and the menu
                    // looked dead (Grace, 2026-11-09). The effective mode
                    // stays where it belongs — the reason line and the
                    // override note below.
                    Label(manualPick == nil ? "自动判断"
                          : manualPick == .airlift ? "直刷" : "恢复式",
                          systemImage: "chevron.up.chevron.down")
                        .font(.subheadline.weight(.medium))
                }
            }
            Text(judged.reason).font(.subheadline).foregroundStyle(.secondary)
            if judged.overriddenPick != nil {
                Text("你手动选了直刷，但上面的硬性限制不允许，已按恢复式处理。")
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
                             onOpen: { detailPack = pack })
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
            if !session.paired {
                NativeNote("先导入配对文件才能刷入。")
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
        session.paired && !session.running
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

    private func answerLegacy(_ prompt: LegacyConvertPrompt, convert: Bool) {
        let answered = prompt.pack.settingAutoConvert(convert)
        if let index = imports.firstIndex(where: { $0.url == answered.url }) {
            imports[index] = answered
        }
        selection.tendies.append(answered)
    }

    private func runApply() {
        let judged = judgement
        var runSelection = selection
        runSelection.resetModes = []
        runSelection.fullReset = false
        Task {
            let outcome = await session.run(selection: runSelection, mode: judged.mode, identity: identity)
            statusLine = outcome.message
        }
    }

    private func runReset() {
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
struct DriftPackRow: View {
    let pack: PosterBoardTendie
    let selected: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void

    @State private var cover: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

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
            Button(action: onOpen) {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .task {
            let url = await Task.detached { PosterBoardPreview.cover(for: pack) }.value
            if let url, let data = try? Data(contentsOf: url) {
                cover = UIImage(data: data)
            }
        }
    }
}

/// Pack details: per-descriptor previews and the poster-type choice.
struct DriftPackDetail: View {
    let pack: PosterBoardTendie
    @Binding var imports: [PosterBoardTendie]
    @Binding var selection: PosterBoardSelection
    @Environment(\.dismiss) private var dismiss
    @State private var previews: [UIImage] = []

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
                        Text("归属类型").font(.subheadline.weight(.semibold))
                        Text("决定壁纸出现在哪一类里。选错不报错、只是不显示，拿不准就用合集。")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("归属类型", selection: Binding(
                            get: { current.posterType },
                            set: { setType($0) }
                        )) {
                            ForEach(PosterBoardPosterType.allCases) { type in
                                Text(type.label).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .driftCard()
                    if current.isUnsafeContainer {
                        NativeSafetyNote("这个包带着壁纸商店的数据库，属于「容器包」：刷入可能弄乱现有壁纸索引，只能用恢复式刷入；真乱了用壁纸页底部的「重置壁纸商店」清理。")
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
}

/// Chinese labels for the three store-reset modes (the enum's raw values are
/// the reference's English dialog names).
private func resetModeTitle(_ mode: PosterBoardResetMode) -> String {
    switch mode {
    case .collections: return "清理合集"
    case .suggestedPhotos: return "清理精选照片"
    case .galleryCache: return "清理图库缓存"
    }
}
