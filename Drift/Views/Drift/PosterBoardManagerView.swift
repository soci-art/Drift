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
            Section {
                Text("这里列出商店里在册、且属于合集 / Mercury / 照片 provider 的描述符——不管是谁刷的、有没有回执。系统/功能型 provider 不在管理范围内。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("删除走哪条路，看当时的条件：隧道通着走隧道删，隧道不通但本机能用走本机删。页面显示本次将走的路。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("本次删除将走：\(routeLabel)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }

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
        .navigationTitle("管理刷入的壁纸")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .driftActionSheet(isPresented: $confirmDelete, title: "确认删除这些壁纸？",
                          message: selectedEntries.map { "· \($0.name)（\($0.provider) / \($0.uuid)）" }.joined(separator: "\n")
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
        .alert("删除完成", isPresented: $showActivationPrompt) {
            Button(activationKind.actionTitle) { runActivation() }
            Button("稍后再说", role: .cancel) {}
        } message: {
            Text(activationMessage + "\n\n" + activationKind.needText)
        }
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
            }
            Spacer()
        }
        .padding(.vertical, 2)
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
                let outcome = try await PosterBoardManagement.deleteManagedEntry(
                    entry, tunnelReady: tunnelReady,
                    identityVersion: identity.version) { line in
                    DriftEngine.shared.log(line)
                }
                messages.append(outcome.message)
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
            let receipts = PosterBoardLocalReceipts.load()
            func flashedChannel(of entry: PosterBoardManagement.ManagedEntry)
                -> PosterBoardReceiptChannel? {
                let key = "\(entry.provider)/\(entry.uuid)/\(entry.generation)"
                return receipts.first {
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
