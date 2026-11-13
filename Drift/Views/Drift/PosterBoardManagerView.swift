import SwiftUI

/// Manage the wallpapers currently in the PosterBoard store.
///
/// The list comes from the store itself, not from this app's receipts: every
/// in-scope descriptor (Collections / Mercury / Photos) is listed, no matter
/// which app wrote it. Deletion is routed by the premises available at delete
/// time, not by who wrote the descriptor.
struct PosterBoardManagerView: View {
    @EnvironmentObject private var session: DriftSession
    @EnvironmentObject private var identityMonitor: DeviceIdentityMonitor
    @ObservedObject private var tunnelMonitor = TunnelMonitor.shared

    @State private var entries: [PosterBoardManagement.ManagedEntry] = []
    /// The receipt journal, for the #307 pack-name chip and the
    /// #306 by-channel deletion routing.
    @State private var receipts: [PosterBoardLocalReceipt] = []
    @State private var sourceLabel: String = ""
    @State private var loadError: String?
    @State private var loading = false
    @State private var selected: Set<String> = []
    @State private var deleting = false
    @State private var confirmDelete = false
    @State private var notice: ManagerNotice?
    @State private var showActivationPrompt = false
    @State private var activationKind: ActivationKind = .respring
    @State private var activationMessage = ""

    /// How a deletion is made to take effect, keyed to how the wallpaper was
    /// flashed (Grace, #161): local → end PosterBoard; 免注销 → restart
    /// PosterBoard; 注销 and anything unknown → respring.
    private var identity: DeviceIdentity { identityMonitor.current }

    private var tunnelReady: Bool {
        session.paired && tunnelMonitor.status == .ready && !identity.version.isEmpty
    }

    private var localAvailable: Bool {
        WorseQueryEscape.isAvailable(
            deviceVersion: WorseQueryEscape.processVersion,
            buildVersion: WorseQueryEscape.processBuildVersion)
    }

    private var routeLabel: String {
        if tunnelReady { return "隧道" }
        if localAvailable { return "本机" }
        return "不可用"
    }

    var body: some View {
        List {
            // Collection #276 (Grace, 2026-11-13): no explainer section
            // at the top any more — the page opens straight onto the
            // list. (The deletion route is still computed exactly as
            // before; it just isn't announced in a paragraph.)
            if loading {
                Section { ProgressView() }
            } else if entries.isEmpty && loadError == nil {
                Section {
                    Text("商店里没有可管理的描述符。")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(entries) { entry in
                    row(entry)
                }
            }

            Section {
                Button {
                    Task { await load() }
                } label: {
                    Label(loading ? "正在读取…" : "重新读取", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label(deleting ? "正在删除…" : "删除选中的 \(selected.count) 项",
                          systemImage: "trash")
                }
                .disabled(selected.isEmpty || deleting || routeLabel == "不可用")
                Text("允许勾选多条，但确认时会逐条列出。没有「全选清空」入口。删了当前正在使用的壁纸时，生效后系统会换回默认壁纸。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        // #280 (Grace, 2026-11-13): renamed — the page is 本机壁纸管理
        // now, and its entry lives on Home under the flash button.
        .navigationTitle("本机壁纸管理")
        .navigationBarTitleDisplayMode(.inline)
        // #304: the one flat page background, like every page.
        .scrollContentBackground(.hidden)
        .background { DriftBackground() }
        .task {
            AppLog.op("打开本机壁纸管理")
            await load()
        }
        .driftActionSheet(isPresented: $confirmDelete, title: "确认删除这些壁纸？",
                          message: selectedEntries.map { entry in
                            "· \(entry.name)（\(entry.provider) / \(entry.uuid)）"
                                + (receipt(for: entry).map { " · 来自导入的包：\($0.pack)" } ?? "")
                          }.joined(separator: "\n")
                            + "\n如果删的正是当前正在使用的壁纸，生效后系统会换回默认壁纸。",
                          actions: [
                            DriftSheetAction("删除", destructive: true) {
                                Task { await deleteSelected() }
                            },
                          ])
        .alert(item: $notice) { item in
            Alert(title: Text(item.title), message: Text(item.message),
                  dismissButton: .default(Text("知道了")))
        }
        // #262 (Grace, 2026-11-12): same bottom-sheet UI as the
        // Settings deletion chain's「删除完成」ask — one look for the
        // same question everywhere. Wording and choices unchanged.
        .driftActionSheet(isPresented: $showActivationPrompt, title: "删除完成",
                          message: activationMessage + "\n\n" + activationKind.needText,
                          actions: [
                            DriftSheetAction(activationKind.actionTitle) {
                                runActivation()
                            },
                          ])
    }

    /// Execute the prompted activation immediately on tap (#161).
    private func runActivation() {
        switch activationKind {
        case .endPosterBoard:
            let opened = PosterBoardLaunch.open()
            notice = ManagerNotice(
                title: opened ? "已打开 PosterBoard" : "请手动打开",
                message: opened
                    ? "请从应用切换器中关闭 PosterBoard，然后检查锁定屏幕壁纸选择器，删掉的壁纸就没了。"
                    : "请打开锁定屏幕壁纸选择器来刷新 PosterBoard；如果删掉的壁纸还在，请从应用切换器关闭 PosterBoard 后再看。",
                offersRefresh: false)
        case .restartPosterBoard:
            Task {
                let result = await session.restartPosterBoardUnderCover()
                notice = ManagerNotice(
                    title: result.confirmed ? "已重启 PosterBoard" : "没重启成",
                    message: result.status.explanation + (result.confirmed
                        ? "。删掉的壁纸已经生效移除。"
                        : "。可以连上隧道再试，或改用注销。"),
                    offersRefresh: false)
            }
        case .respring:
            let triggered = session.respringUnderCover()
            notice = ManagerNotice(
                title: triggered ? "已触发注销" : "注销没触发成",
                message: triggered
                    ? "PosterBoard 重新启动后会读到删除结果。"
                    : "现在没有可用的窗口触发注销，请手动从系统里注销一次。",
                offersRefresh: false)
        }
    }

    private var selectedEntries: [PosterBoardManagement.ManagedEntry] {
        entries.filter { selected.contains($0.id) }
    }

    @ViewBuilder
    private func row(_ entry: PosterBoardManagement.ManagedEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                if selected.contains(entry.id) { selected.remove(entry.id) }
                else { selected.insert(entry.id) }
            } label: {
                Image(systemName: selected.contains(entry.id)
                      ? "checkmark.square.fill" : "square")
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).font(.subheadline.weight(.medium))
                Text(entry.provider).font(.caption2).foregroundStyle(.secondary)
                Text("文件夹：\(entry.uuid)").font(.caption2).foregroundStyle(.secondary)
                if !entry.packageName.isEmpty {
                    Text("包名：\(entry.packageName)").font(.caption2).foregroundStyle(.secondary)
                }
                packChip(for: entry)
            }
            Spacer()
            // #288 (Grace, 2026-11-13): no category label here — the
            // page makes no judgement about who wrote a wallpaper.
            // The #275 labels that briefly sat at this edge are gone.
        }
        .padding(.vertical, 2)
    }

    /// The receipt that proves Drift flashed this entry, if any
    /// (#307): matched on provider / folder / generation, the same
    /// key the activation prompt below has always used; the newest
    /// receipt wins when a descriptor was flashed more than once.
    /// This is not the #275/#288 judgement call — no origin is
    /// inferred from package names; an entry either matches the
    /// app's own write journal or it does not.
    private func receipt(for entry: PosterBoardManagement.ManagedEntry) -> PosterBoardLocalReceipt? {
        let key = "\(entry.provider)/\(entry.uuid)/\(entry.generation)"
        return receipts.last {
            "\($0.extensionID)/\($0.folderName)/\($0.generation)" == key
        }
    }

    /// The #307 chip: the file name of the pack this wallpaper was
    /// imported from, shown only on entries the journal proves are
    /// Drift's own.
    @ViewBuilder
    private func packChip(for entry: PosterBoardManagement.ManagedEntry) -> some View {
        if let receipt = receipt(for: entry) {
            Text("来自导入的包：\(receipt.pack)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.blue)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Color.blue.opacity(0.12), in: Capsule())
                .padding(.top, 1)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let result = await PosterBoardManagement.loadManagedEntries(
            tunnelReady: tunnelReady,
            identityVersion: identity.version) { line in
            DriftEngine.shared.log(line)
        }
        entries = result.entries
        receipts = PosterBoardLocalReceipts.load()
        sourceLabel = result.source
        loadError = result.reason
        if let reason = result.reason {
            session.errorText = reason
        }
        selected = selected.intersection(Set(entries.map(\.id)))
    }

    private func deleteSelected() async {
        guard !selected.isEmpty, !deleting else { return }
        deleting = true
        defer { deleting = false }
        let targets = selectedEntries
        var messages: [String] = []
        var succeeded: [PosterBoardManagement.ManagedEntry] = []
        for entry in targets {
            do {
                if let receipt = receipt(for: entry) {
                    // #306 (Grace, 2026-11-13): 怎么刷的怎么删 — an
                    // entry the journal proves is Drift's is deleted
                    // through the channel that flashed it, never
                    // rerouted. This is the flow that used to hang
                    // off Settings' records; it lives here now.
                    let outcome = try await PosterBoardManagement.delete(
                        receipt, tunnelReady: tunnelReady) { line in
                        DriftEngine.shared.log(line)
                    }
                    messages.append(outcome.message)
                } else {
                    let outcome = try await PosterBoardManagement.deleteManagedEntry(
                        entry, tunnelReady: tunnelReady,
                        identityVersion: identity.version) { line in
                        DriftEngine.shared.log(line)
                    }
                    messages.append(outcome.message)
                }
                succeeded.append(entry)
            } catch {
                session.errorText = error.localizedDescription
            }
        }
        selected.removeAll()
        await load()
        if !succeeded.isEmpty {
            // #161: prompt by how the deleted wallpapers were FLASHED (from
            // their receipts), not by the route the deletion took. Unknown
            // origin → respring (Grace's ruling); a mixed batch takes the
            // strongest action present.
            let freshReceipts = PosterBoardLocalReceipts.load()
            func flashedChannel(of entry: PosterBoardManagement.ManagedEntry)
                -> PosterBoardReceiptChannel? {
                let key = "\(entry.provider)/\(entry.uuid)/\(entry.generation)"
                return freshReceipts.last {
                    "\($0.extensionID)/\($0.folderName)/\($0.generation)" == key
                }?.resolvedChannel
            }
            let channels = succeeded.map { flashedChannel(of: $0) }
            if channels.contains(nil) {
                // At least one wallpaper was flashed by ANOTHER app:
                // there is no channel to key on, so choose by the
                // methods usable right now (Grace, 2026-11-11) — the
                // local channel usable → end PosterBoard; otherwise
                // respring.
                activationKind = WorseQueryEscape.isAvailable(
                    deviceVersion: WorseQueryEscape.processVersion,
                    buildVersion: WorseQueryEscape.processBuildVersion)
                    ? .endPosterBoard : .respring
            } else if channels.contains(.airlift) {
                activationKind = .respring
            } else if channels.contains(.direct) {
                activationKind = .restartPosterBoard
            } else {
                activationKind = .endPosterBoard
            }
            activationMessage = messages.joined(separator: "\n\n")
            showActivationPrompt = true
        }
    }
}

/// How a finished deletion takes effect, and the one tap that does it
/// (#161). Shared by the management page and Settings' record deletion.
enum ActivationKind {
    case endPosterBoard, restartPosterBoard, respring
    var needText: String {
        switch self {
        case .endPosterBoard: return "要让删除生效，请打开 PosterBoard，再从应用切换器把它上滑关掉。"
        case .restartPosterBoard: return "要让删除生效，需要重启 PosterBoard。"
        case .respring: return "要让删除生效，需要注销一次。"
        }
    }
    var actionTitle: String {
        switch self {
        case .endPosterBoard: return "打开 PosterBoard"
        case .restartPosterBoard: return "重启 PosterBoard"
        case .respring: return "立即注销"
        }
    }
}

private struct ManagerNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let offersRefresh: Bool
}
