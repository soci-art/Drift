import SwiftUI

/// The two pages behind the video page's decoded-video entry
/// (Grace, 2026-11-22): the library manager and the flash picker.
///
/// Decoding happens on the video page, where the video and its
/// options are; these pages only keep the products and flash them.
/// A decoded item is a finished descriptor tree, so flashing one
/// never decodes again — the whole point of the library.

/// One row's preview: the item's saved preview image, or a film
/// placeholder when the decode kept none.
private struct DecodedVideoThumb: View {
    let item: DecodedVideoItem

    var body: some View {
        Group {
            if item.hasPreview,
               let data = try? Data(contentsOf: item.previewURL),
               let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [.indigo.opacity(0.35), .teal.opacity(0.3)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
        }
        .frame(width: 46, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DecodedVideoRowText: View {
    let item: DecodedVideoItem
    /// The product was decoded for another screen size and the flash
    /// gate would refuse it — say so on the row itself (Grace,
    /// 2026-11-28) instead of letting a same-name stale item pass
    /// for the fresh one until it is tapped.
    var stale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
            Text([item.optionsSummary, item.resolutionText]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text("\(item.sizeText) · \(Self.dateText(item.decodedAt)) 解码")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if stale {
                Text("尺寸对不上，刷不了，要重新解码")
                    .font(.caption.weight(.medium)).foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

/// The library manager: what has been decoded, how much room it
/// takes, and batch deletion. A decode in flight rides at the top
/// as a row of its own — not selectable, since there is nothing to
/// select yet — and a deleted item has to be decoded again before
/// it can be flashed, which the footer says out loud.
struct DecodedVideoListView: View {
    @ObservedObject private var library = DecodedVideoLibrary.shared
    @State private var selectedIDs: Set<String> = []
    @State private var confirmingDelete = false
    @State private var staleIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            List {
                if let decodingName = library.decodingName {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(decodingName).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text("解码中…").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                if library.items.isEmpty && !library.isDecoding {
                    Text("还没有已解码的视频。回视频页选个视频，点「开始解码」，解好的会存到这里，刷的时候直接选，不用再等解码。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                // Grace (2026-11-23): the whole row is the tap
                // target — before, only the little circle at the
                // front answered, and the rest of the row was dead.
                ForEach(library.items) { item in
                    Button {
                        if selectedIDs.contains(item.id) {
                            selectedIDs.remove(item.id)
                        } else {
                            selectedIDs.insert(item.id)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedIDs.contains(item.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selectedIDs.contains(item.id) ? Color.accentColor : .secondary)
                            DecodedVideoThumb(item: item)
                            DecodedVideoRowText(item: item,
                                                stale: staleIDs.contains(item.id))
                            Spacer()
                            if staleIDs.contains(item.id) {
                                Text("尺寸对不上")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.14),
                                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    .foregroundStyle(.orange)
                            } else {
                                Text("就绪")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.green.opacity(0.14),
                                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if !library.items.isEmpty {
                    Text("删掉的视频要重新解码后才能再刷。共 \(library.items.count) 个，占用 \(ByteCountFormatter.string(fromByteCount: library.totalBytes, countStyle: .file))。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            HStack(spacing: 12) {
                Button(selectedIDs.count == library.items.count && !library.items.isEmpty
                       ? "取消全选" : "全选") {
                    if selectedIDs.count == library.items.count {
                        selectedIDs = []
                    } else {
                        selectedIDs = Set(library.items.map(\.id))
                    }
                }
                .driftGlassButton()
                Spacer()
                Text("已选 \(selectedIDs.count) 个").font(.subheadline).foregroundStyle(.secondary)
                Button("删除所选") { confirmingDelete = true }
                    .driftGlassButton()
                    .disabled(selectedIDs.isEmpty)
            }
            .padding(12)
        }
        .navigationTitle("已解码的视频")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: library.items.map(\.id)) {
            staleIDs = await library.staleItemIDs()
        }
        .driftActionSheet(isPresented: $confirmingDelete,
                          title: "删除所选视频？",
                          message: "删掉后要重新解码才能再刷。确定删除选中的 \(selectedIDs.count) 个？",
                          actions: [
                            DriftSheetAction("删除", destructive: true) {
                                library.delete(ids: selectedIDs)
                                selectedIDs = []
                            },
                          ])
    }
}

/// The flash picker: decoded videos chosen with checkboxes (no
/// count limit — Grace first set a cap of ten, then lifted it the
/// same evening, 2026-11-28), and the flash button at the very
/// bottom under a line naming what will go in.
/// A batch runs the video page's single-item run once per picked
/// item, in list order — same judgement, same dispatch per item —
/// except that nothing decodes on the way; one item's failure does
/// not stop the rest, and the end of the batch reports the tally.
/// The restore route batches too (Grace, 2026-11-28): one shared
/// confirmation up front covers the batch, and each item then
/// pulls its own backup in turn, like the wallpaper page asks.
struct DecodedVideoPickerView: View {
    @EnvironmentObject private var session: DriftSession
    @EnvironmentObject private var identityMonitor: DeviceIdentityMonitor
    @ObservedObject private var tunnelMonitor = TunnelMonitor.shared
    @ObservedObject private var library = DecodedVideoLibrary.shared
    @AppStorage(DriftJudge.manualKey) private var manualPickRaw: String?

    @State private var pickedIDs: Set<String> = []
    @State private var statusLine: String?
    @State private var confirmRestore = false
    @State private var staleIDs: Set<String> = []
    @State private var batchRunning = false
    @State private var batchCancelRequested = false

    private var identity: DeviceIdentity { identityMonitor.current }
    private var manualPick: DriftMethodPick { DriftMethodPick.fromStored(manualPickRaw) }
    /// The picked items in list order — the order they flash in.
    private var pickedItems: [DecodedVideoItem] {
        library.items.filter { pickedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                if let decodingName = library.decodingName {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(decodingName).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text("解码中，解完才能选").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                if library.items.isEmpty && !library.isDecoding {
                    Text("还没有已解码的视频，先回视频页选个视频点「开始解码」。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(library.items) { item in
                    Button {
                        togglePick(item)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: pickedIDs.contains(item.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(pickedIDs.contains(item.id) ? Color.accentColor : .secondary)
                            DecodedVideoThumb(item: item)
                            DecodedVideoRowText(item: item,
                                                stale: staleIDs.contains(item.id))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            VStack(spacing: 10) {
                if let statusLine {
                    Text(statusLine).font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if pickedItems.count == 1, let only = pickedItems.first {
                    Text("将刷入：\(only.name)（\(only.optionsSummary)）")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if pickedItems.count > 1 {
                    Text("将刷入：\(pickedItems.count) 个视频（按列表顺序逐个刷，锁屏显示最后刷的那个，其余在壁纸商店里随时能切）")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                NativePrimaryButton(title: session.running ? "刷入中…"
                                    : (pickedItems.count > 1 ? "刷入所选（\(pickedItems.count) 个）" : "刷入"),
                                    systemImage: "film",
                                    running: session.running,
                                    disabled: pickedItems.isEmpty || session.running) {
                    tapFlash()
                }
                if session.running {
                    Button("取消") {
                        if batchRunning { batchCancelRequested = true }
                        session.cancelRun()
                    }.driftGlassButton()
                }
            }
            .padding(12)
        }
        .navigationTitle("选择已解码的视频")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: library.items.map(\.id)) {
            staleIDs = await library.staleItemIDs()
        }
        .driftActionSheet(isPresented: $confirmRestore,
                          title: DriftRestoreGate.confirmationTitle,
                          message: DriftRestoreGate.confirmationMessage,
                          actions: [
                            DriftSheetAction("确定刷入", destructive: true) { performBatch() },
                          ])
    }

    /// Checkbox tap: add or remove the item.
    private func togglePick(_ item: DecodedVideoItem) {
        if pickedIDs.contains(item.id) {
            pickedIDs.remove(item.id)
        } else {
            pickedIDs.insert(item.id)
        }
    }

    /// The tap: judge first (on the first picked item — the
    /// judgement is about the device and the channels, not the
    /// payload), and a restore answer asks before anything runs —
    /// the same confirmation the wallpaper page shows, at the same
    /// moment (before the pull starts). One confirmation covers the
    /// whole batch; each item then pulls its own backup in turn.
    private func tapFlash() {
        guard let first = pickedItems.first else { return }
        let judged = DriftJudge.judge(identity: identity, selection: first.makeSelection(),
                                      pick: manualPick,
                                      tunnelReady: tunnelMonitor.status == .ready)
        if judged.isBlocked {
            session.errorText = judged.blockedReason
            return
        }
        if judged.mode == .backup {
            confirmRestore = true
            return
        }
        performBatch()
    }

    /// Run the batch: the single-item run below, once per picked
    /// item in list order. A single pick keeps the old behaviour
    /// exactly (the outcome lands on the status line, or the error
    /// popup). A batch reports progress per item, keeps going past
    /// a failure, and ends with a tally; cancelling stops the
    /// current item's run and ends the batch there.
    private func performBatch() {
        let items = pickedItems
        guard !items.isEmpty else { return }
        if items.count == 1 {
            Task { await runOne(items[0], reportIndividually: true) }
            return
        }
        batchRunning = true
        batchCancelRequested = false
        Task {
            var succeeded = 0
            var failures: [String] = []
            for (index, item) in items.enumerated() {
                if batchCancelRequested { break }
                statusLine = "正在刷第 \(index + 1)/\(items.count) 个：\(item.name)"
                let outcome = await runOne(item, reportIndividually: false)
                if outcome.ok { succeeded += 1 }
                else { failures.append("\(item.name)：\(outcome.message)") }
            }
            batchRunning = false
            if batchCancelRequested {
                statusLine = "已取消：刷好了 \(succeeded) 个，剩下的没刷。"
            } else if failures.isEmpty {
                statusLine = "刷完了：\(succeeded) 个视频全部刷入。"
            } else if succeeded == 0 {
                statusLine = nil
                session.errorText = failures.joined(separator: "\n")
            } else {
                statusLine = "刷完了：成功 \(succeeded) 个，失败 \(failures.count) 个。"
                session.errorText = failures.joined(separator: "\n")
            }
        }
    }

    /// The video page's run, carried on one item's selection
    /// (re-judged on the current state, kernel dispatched directly,
    /// everything else through the session funnel). Returns the
    /// outcome; with `reportIndividually` it also lands on the
    /// status line / error popup the way the single run always has.
    @discardableResult
    private func runOne(_ item: DecodedVideoItem,
                        reportIndividually: Bool) async -> (ok: Bool, message: String) {
        let videoSelection = item.makeSelection()
        var checked = DriftJudge.judge(
            identity: identity, selection: videoSelection, pick: manualPick,
            tunnelReady: tunnelMonitor.status == .ready)
        if checked.isBlocked || checked.mode != .worseQuery {
            if session.paired { await session.refreshIdentity() }
            checked = DriftJudge.judge(
                identity: identity, selection: videoSelection, pick: manualPick,
                tunnelReady: tunnelMonitor.status == .ready)
        }
        guard !checked.isBlocked else {
            if reportIndividually { session.errorText = checked.blockedReason }
            return (false, checked.blockedReason ?? "现在刷不了。")
        }
        // `run` also returns the effect grade; the kernel run does
        // not. Normalise both to the pair this page reports on.
        let outcome: (ok: Bool, message: String)
        if checked.useKernel {
            outcome = await session.runKernelApply(identity: identity, selection: videoSelection)
        } else {
            let ran = await session.run(selection: videoSelection, mode: checked.mode,
                                        pick: manualPick, identity: identity)
            outcome = (ok: ran.ok, message: ran.message)
        }
        if reportIndividually {
            if outcome.ok { statusLine = outcome.message }
            else { statusLine = nil; session.errorText = outcome.message }
        }
        return outcome
    }
}
