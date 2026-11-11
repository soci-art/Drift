import SwiftUI

/// Manage the wallpapers Drift itself wrote.
///
/// The list is built from the receipt journal only: system wallpapers and
/// wallpapers other tools wrote are not Drift's to list or delete. Each row's
/// deletion goes back through the channel that wrote it — the local channel
/// deletes its directory, the tunnel channels use the store primitive — and a
/// deletion is only reported as done when the channel verified it.
struct PosterBoardManagerView: View {
    @EnvironmentObject private var session: DriftSession
    @ObservedObject private var tunnelMonitor = TunnelMonitor.shared

    @State private var receipts: [PosterBoardLocalReceipt] = []
    @State private var states: [String: PosterBoardReconcileState] = [:]
    @State private var reconciling = false
    @State private var busyID: String?
    @State private var target: PosterBoardLocalReceipt?
    @State private var notice: ManagerNotice?

    var body: some View {
        List {
            Section {
                Text("这里只列 Drift 自己刷入、并留下回执的壁纸。系统自带壁纸、其他工具刷入的不会出现，也不能在这里删。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("删除走刷入时的通道：本机直刷在本机删除，隧道通道需要配对文件、LocalDevVPN 和已连接的设备。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if receipts.isEmpty {
                Section {
                    Text("还没有可管理的壁纸。用任意通道刷入一张后，这里才会出现它的回执。")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(PosterBoardReceiptChannel.allCases, id: \.self) { channel in
                    let group = receipts.filter { $0.resolvedChannel == channel }
                    if !group.isEmpty {
                        Section {
                            ForEach(group) { receipt in
                                row(receipt)
                            }
                        } header: {
                            Text(channel.rawValue)
                        }
                    }
                }
            }

            Section {
                Button {
                    Task { await reconcile() }
                } label: {
                    Label(reconciling ? "正在核对…" : "重新核对", systemImage: "arrow.clockwise")
                }
                .disabled(reconciling || receipts.isEmpty)
                Text("对账做不了时会显示「未核对」，不会猜。隧道管理目前只覆盖合集类 provider；覆盖不到的会如实写「暂不支持」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("管理刷入的壁纸")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            reload()
            await reconcile()
        }
        .confirmationDialog("删除这张壁纸？", isPresented: Binding(
            get: { target != nil },
            set: { if !$0 { target = nil } }), titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let receipt = target else { return }
                target = nil
                Task { await delete(receipt) }
            }
            Button("取消", role: .cancel) { target = nil }
        } message: {
            if let receipt = target {
                Text("将删除：\(receipt.pack)（\(receipt.extensionID) / \(receipt.folderName)，通道：\(receipt.channelLabel)）。如果删的正是当前正在使用的壁纸，生效后系统会换回默认壁纸。")
            }
        }
        .alert(item: $notice) { item in
            if item.offersRefresh {
                return Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    primaryButton: .default(Text("刷新 PosterBoard")) {
                        Task { await refreshPosterBoard() }
                    },
                    secondaryButton: .cancel(Text("稍后")))
            }
            return Alert(title: Text(item.title), message: Text(item.message),
                         dismissButton: .default(Text("知道了")))
        }
    }

    @ViewBuilder
    private func row(_ receipt: PosterBoardLocalReceipt) -> some View {
        let state = states[receipt.id] ?? .unknown("还没有核对。")
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(receipt.pack).font(.subheadline)
                Spacer()
                Text(state.label)
                    .font(.caption2)
                    .foregroundStyle(tint(for: state))
            }
            Text(receipt.summary)
                .font(.caption2).foregroundStyle(.secondary)
            if !state.note.isEmpty {
                Text(state.note)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                if busyID == receipt.id {
                    ProgressView().controlSize(.small)
                } else if state == .absent {
                    Button("移除记录") {
                        PosterBoardLocalReceipts.forget(id: receipt.id)
                        reload()
                        notice = ManagerNotice(title: "记录已移除",
                                               message: "只移除了这条回执，没有对设备做任何操作。",
                                               offersRefresh: false)
                    }
                    .font(.caption)
                } else {
                    Button("删除", role: .destructive) {
                        target = receipt
                    }
                    .font(.caption)
                    .disabled(!canDelete(receipt, state: state))
                }
                Spacer()
                Text(receipt.channelLabel)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func tint(for state: PosterBoardReconcileState) -> Color {
        switch state {
        case .inStore: return .green
        case .absent: return .secondary
        case .unsupported: return .orange
        case .unknown: return .secondary
        }
    }

    private var tunnelReady: Bool {
        session.paired && tunnelMonitor.status == .ready
    }

    private func canDelete(_ receipt: PosterBoardLocalReceipt,
                           state: PosterBoardReconcileState) -> Bool {
        if case .unsupported = state { return false }
        switch receipt.resolvedChannel {
        case .local:
            guard WorseQueryEscape.unavailableReason(
                deviceVersion: WorseQueryEscape.processVersion,
                buildVersion: WorseQueryEscape.processBuildVersion).isEmpty else {
                return false
            }
            // The local delete opens the same container as the write. Only
            // offer it when the reconciliation actually found the descriptor;
            // an unreadable local store is a reason, not a retry button.
            if case .inStore = state { return true }
            return false
        case .direct, .airlift:
            guard tunnelReady,
                  PosterBoardManagement.tunnelSupports(receipt.extensionID) else {
                return false
            }
            // Enumeration may fail while deletion itself still works, so an
            // unknown tunnel row stays actionable; unsupported is handled above.
            if case .inStore = state { return true }
            if case .unknown = state { return true }
            return false
        }
    }

    private func reload() {
        receipts = PosterBoardLocalReceipts.load()
    }

    private func reconcile() async {
        guard !receipts.isEmpty else { return }
        reconciling = true
        states = await PosterBoardManagement.reconcile(
            receipts, tunnelReady: tunnelReady) { line in
            DriftEngine.shared.log(line)
        }
        reconciling = false
    }

    private func delete(_ receipt: PosterBoardLocalReceipt) async {
        guard busyID == nil else { return }
        busyID = receipt.id
        defer { busyID = nil }
        do {
            let outcome = try await PosterBoardManagement.delete(
                receipt, tunnelReady: tunnelReady) { line in
                DriftEngine.shared.log(line)
            }
            reload()
            if outcome.confirmed {
                states[receipt.id] = .absent
            } else {
                states[receipt.id] = .unknown(outcome.message)
            }
            notice = ManagerNotice(title: outcome.confirmed ? "删除完成" : "已删除、未确认",
                                   message: outcome.message,
                                   offersRefresh: outcome.channel.isTunnel && outcome.confirmed)
            await reconcile()
        } catch {
            session.errorText = error.localizedDescription
            await reconcile()
        }
    }

    private func refreshPosterBoard() async {
        let result = await PosterRefresh.attempt(pairingPath: AppPaths.pairingFile.path)
        if result.confirmed {
            notice = ManagerNotice(title: "PosterBoard 已刷新",
                                   message: "只重启了 PosterBoard，壁纸库会重新读取商店；其他 App 不受影响。",
                                   offersRefresh: false)
        } else {
            session.errorText = "PosterBoard 刷新未确认：\(result.status.explanation)。可以手动注销生效；App 不会自动注销。"
        }
    }
}

private struct ManagerNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let offersRefresh: Bool
}
