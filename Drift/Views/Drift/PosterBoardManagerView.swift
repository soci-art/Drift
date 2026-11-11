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
                Text("删除走哪条路由前提决定：隧道在走隧道删，隧道不在但本机可用走本机删。页面显示本次将走的路。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("本次删除将走：\(routeLabel)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }

            if let loadError {
                Section {
                    Text(loadError).foregroundStyle(.secondary)
                }
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
        .confirmationDialog("确认删除这些壁纸？", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task { await deleteSelected() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(selectedEntries.map { "· \($0.name)（\($0.provider) / \($0.uuid)）" }.joined(separator: "\n")
                + "\n如果删的正是当前正在使用的壁纸，生效后系统会换回默认壁纸。")
        }
        .alert(item: $notice) { item in
            Alert(title: Text(item.title), message: Text(item.message),
                  dismissButton: .default(Text("知道了")))
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
        selected = selected.intersection(Set(entries.map(\.id)))
    }

    private func deleteSelected() async {
        guard !selected.isEmpty, !deleting else { return }
        deleting = true
        defer { deleting = false }
        let targets = selectedEntries
        var messages: [String] = []
        for entry in targets {
            do {
                let outcome = try await PosterBoardManagement.deleteManagedEntry(
                    entry, tunnelReady: tunnelReady,
                    identityVersion: identity.version) { line in
                    DriftEngine.shared.log(line)
                }
                messages.append(outcome.message)
            } catch {
                session.errorText = error.localizedDescription
            }
        }
        selected.removeAll()
        await load()
        if !messages.isEmpty {
            notice = ManagerNotice(title: "删除完成", message: messages.joined(separator: "\n\n"),
                                   offersRefresh: false)
        }
    }
}

private struct ManagerNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let offersRefresh: Bool
}
