import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// Drift's settings: connection (pairing, tunnel), apply preferences and
/// history, logs/diagnostics, and About. Only what the wallpaper feature
/// needs — the base app's tweak/developer/update settings do not exist here.
struct DriftSettingsView: View {
    @EnvironmentObject private var session: DriftSession
    @ObservedObject private var wirelessPair = WirelessPairing.shared
    @ObservedObject private var tunnelMonitor = TunnelMonitor.shared

    @State private var importingPairing = false
    @State private var showGuide = false
    @State private var confirmResetPairing = false
    @State private var history: [ApplyHistory.Record] = ApplyHistory.load()
    @State private var packaging = false
    @State private var sharePackage: SharePackageItem?
    @State private var recordsNote: String?
    @State private var showSealedNotice = false
    @State private var receipts: [PosterBoardLocalReceipt] = PosterBoardLocalReceipts.load()
    @State private var receiptToDelete: PosterBoardLocalReceipt?
    @State private var showDeleteActivation = false
    @State private var deleteActivationKind: ActivationKind = .respring
    @State private var deleteActivationMessage = ""
    @State private var confirmClearHistory = false
    @State private var exportTarget: ApplyHistory.Record?
    @State private var exportBundle: RecordExport.Bundle?
    @State private var showExportChoices = false
    /// The export outcome popup (#256): set the content, then flip
    /// `showExportPopup`. Success after an upload carries no text at
    /// all — the popup title「上传成功」is the whole message.
    @State private var showExportPopup = false
    @State private var exportPopupTitle = ""
    @State private var exportPopupMessage: String?
    @State private var recordBusy = false
    @ObservedObject private var updateChecker = AppUpdateChecker.shared
    @State private var cacheBreakdown: AppCache.Breakdown?
    @State private var confirmClearCache = false
    @State private var cacheNote: String?
    @State private var notificationsAllowed = true
    @State private var showAnnouncement = false
    @State private var uploading = false
    @State private var confirmUpload = false
    #if DRIFT_ENUM_PROBE
    @State private var probeRunning = false
    @State private var probeStatus = ""
    // #292 (Grace, 2026-11-13): live progress for the probe run — which
    // tier is running, the finished tiers' times, a rough remaining
    // estimate — and a completion / failure sheet at the end. Tier-level
    // only: the C scan reports nothing until a tier finishes, so there
    // is no honest within-tier counter to show.
    @State private var probeTierIndex = 0
    @State private var probeTierTotal = 9
    @State private var probeCurrentTier = ""
    @State private var probeDoneLines: [String] = []
    @State private var probeStartedAt: Date?
    @State private var probeDoneWeight = 0.0
    @State private var probeShowDone = false
    @State private var probeDoneMessage = ""
    @State private var probeShowFailed = false
    @State private var probeFailedMessage = ""
    #endif

    var body: some View {
        NavigationStack {
            List {
                announcementSection
                connectionSection
                localRouteSection
                #if DRIFT_ENUM_PROBE
                probeSection
                #endif
                restoreSealedSection
                historySection
                recordsSection
                appSection
                aboutSection
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            // UIKit picker, not SwiftUI `fileImporter` — see
            // `DocumentPicker` for why.
            .sheet(isPresented: $importingPairing) {
                DocumentPicker(contentTypes: PairingRecord.types) { urls in
                    importingPairing = false
                    guard let url = urls.first else {
                        session.errorText = "没有选到文件，请再导入一次。"
                        return
                    }
                    do { try session.importPairing(from: url) }
                    catch { session.errorText = error.localizedDescription }
                } onCancel: {
                    importingPairing = false
                }
            }
            .sheet(isPresented: $showGuide) {
                FirstRunView(onClose: { showGuide = false })
            }
            .sheet(isPresented: $showAnnouncement) {
                AppAnnouncementView(manualEntry: true) { showAnnouncement = false }
                    .presentationDetents([.large])
            }
            .driftActionSheet(isPresented: $confirmUpload, title: "上传日志？",
                              message: "把这份记录包（诊断信息和运行日志）传给开发者，只用来排查问题。",
                              actions: [
                                DriftSheetAction("上传") { Task { await uploadLogs() } },
                              ])
            .onChange(of: wirelessPair.generatedRecordPath) { _, path in
                adoptWirelessRecord(at: path)
            }
            .onAppear {
                AppLog.op("打开设置页")
                history = ApplyHistory.load()
                receipts = PosterBoardLocalReceipts.load()
                refreshNotificationStatus()
            }
            .onChange(of: wirelessPair.pin) { _, _ in
                refreshNotificationStatus()
            }
            .driftActionSheet(isPresented: Binding(
                get: { receiptToDelete != nil },
                set: { if !$0 { receiptToDelete = nil } }),
                              title: "删除这张壁纸？",
                              message: receiptToDelete.map {
                                "「\($0.pack)」将被删除。如果删的正是当前正在用的壁纸，生效后系统会换回默认壁纸。"
                              },
                              // #262 (Grace, 2026-11-12): the action must
                              // carry the receipt it was presented for.
                              // The sheet dismisses BEFORE running its
                              // handler, and dismissal clears
                              // receiptToDelete — a handler that re-read
                              // it found nothing and silently did
                              // nothing, so the delete never ran.
                              actions: receiptToDelete.map { receipt in
                                [DriftSheetAction("删除", destructive: true) {
                                    receiptToDelete = nil
                                    Task { await deleteReceipt(receipt) }
                                }]
                              } ?? [])
            // #293: presented from the root, not from the app section —
            // see the note at the clear-cache `.task` in `appSection`.
            .driftActionSheet(isPresented: $confirmClearCache, title: "清除这些缓存？",
                              message: cacheBreakdown.map {
                                "预览图 \(AppCache.format($0.previews))、目录缓存 \(AppCache.format($0.catalogCache))、临时文件 \(AppCache.format($0.fetchScratch))、日志 \(AppCache.format($0.logs))、下载的安装包 \(AppCache.format($0.updates))，共 \(AppCache.format($0.total))。"
                              },
                              actions: [
                                DriftSheetAction("清除", destructive: true) {
                                    Task {
                                        let freed = await Task.detached { AppCache.clear() }.value
                                        cacheBreakdown = await Task.detached { AppCache.measure() }.value
                                        cacheNote = "已清除，省出约 \(AppCache.format(freed))。"
                                    }
                                },
                              ])
            .driftActionSheet(isPresented: $confirmClearHistory, title: "清空全部刷入记录？",
                              message: "记录清空后无法恢复。此操作只清记录，不会删除设备上已刷入的壁纸——要删壁纸请用主页的「本机壁纸管理」。",
                              actions: [
                                DriftSheetAction("清空记录", destructive: true) {
                                    ApplyHistory.clear()
                                    history = []
                                    recordsNote = "刷入记录已清空；回执没有动，管理页仍能认出已刷的壁纸。"
                                },
                              ])
            // #262 (Grace, 2026-11-12): the post-delete activation ask
            // wears the same bottom-sheet UI as the confirmation before
            // it — same layout family, the sheet's 取消 standing in for
            // 「稍后再说」. Wording and choices are unchanged.
            .driftActionSheet(isPresented: $showDeleteActivation, title: "删除完成",
                              message: deleteActivationMessage + "\n\n" + deleteActivationKind.needText,
                              actions: [
                                DriftSheetAction(deleteActivationKind.actionTitle) {
                                    runDeleteActivation()
                                },
                              ])
            .alert("恢复刷已封存", isPresented: $showSealedNotice) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(DriftRestoreGate.notice)
            }
            .sheet(item: $sharePackage) { item in
                ActivityShareSheet(url: item.url)
            }
            // Grace (2026-11-12, on 3.0.11): the dialog shows ONLY the
            // title and the three choices — no bundle breakdown, no
            // missing-items list, no retention note. Outcomes arrive in
            // the popup below (#256); an oversize bundle uploads without
            // its wallpaper packs instead of refusing (#257).
            // On 3.0.11 (32) she flagged the system dialog's floating
            // bubble presentation itself, so this is now the app's own
            // bottom sheet (DriftActionSheet) like every other
            // action confirmation in the app.
            .driftActionSheet(isPresented: $showExportChoices, title: "导出这条记录",
                              actions: [
                                DriftSheetAction("导出（存成文件）") { saveRecordExport() },
                                DriftSheetAction("分享") {
                                    if let bundle = exportBundle {
                                        sharePackage = SharePackageItem(url: bundle.url)
                                    }
                                },
                                DriftSheetAction("导出并上传") { uploadRecordExport() },
                              ])
            .driftActionSheet(isPresented: $showExportPopup, title: exportPopupTitle,
                              message: exportPopupMessage,
                              actions: [DriftSheetAction("知道了") {}])
        }
    }

    /// Present an export outcome (#256): a popup at action time instead
    /// of a standing line in the records section.
    private func presentExportOutcome(title: String, message: String? = nil) {
        exportPopupTitle = title
        exportPopupMessage = message
        showExportPopup = true
    }

    // MARK: - Announcement

    /// The update announcement, re-openable from Settings (Grace,
    /// 2026-11-12): pinned at the very top, above the tunnel section.
    private var announcementSection: some View {
        Section {
            Button { showAnnouncement = true } label: {
                Label("更新公告", systemImage: "megaphone")
            }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section("隧道通道（免注销直刷 / 注销直刷）") {
            Text("配对文件与隧道是走两条隧道通道要先备齐的；走本机直刷不需要它们。想走隧道通道时，再在这里配好。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Label("配对文件", systemImage: "link")
                Spacer()
                DriftPill(text: session.paired ? "已导入" : "未导入",
                          tint: session.paired ? .green : .orange)
            }
            Button { importingPairing = true } label: {
                Label(session.paired ? "更换配对文件" : "导入配对文件", systemImage: "doc.badge.plus")
            }
            if session.paired {
                Button(role: .destructive) { confirmResetPairing = true } label: {
                    Label("删除配对（停止使用）", systemImage: "link.badge.minus")
                }
                .driftActionSheet(isPresented: $confirmResetPairing, title: "删除当前配对？",
                                  message: "App 会忘掉这份配对记录，文件本身保留在 App 文档里；重新导入即可恢复。",
                                  actions: [
                                    DriftSheetAction("删除", destructive: true) { session.resetPairing() },
                                  ])
            }
            wirelessPairingRows
            HStack {
                Label("隧道状态", systemImage: "antenna.radiowaves.left.and.right")
                Spacer()
                // The monitor's live verdict, not a one-off probe taken when
                // this page happened to render — the tunnel coming up or
                // dropping changes this row within a couple of seconds.
                Text(tunnelMonitor.status == .ready ? "隧道已连通"
                     : tunnelMonitor.status == .interfaceUp ? "接口已就绪，等待对端回应"
                     : "未检测到隧道")
                    .foregroundStyle(.secondary)
            }
            Button {
                showGuide = true
            } label: {
                Label("重新打开设置向导", systemImage: "wand.and.stars")
            }
            // Collection #239 (Grace, 2026-11-12): no tutorial entry in
            // Settings — the tutorial lives on the Home page only (#230).
        }
    }

    // MARK: - In-process route

    /// The in-process route's premise, shown where the user can act on it:
    /// whether this system is in range, and which App Group the installed
    /// signing profile actually granted.
    private var localRouteSection: some View {
        Section("本机直刷") {
            HStack {
                Label("系统版本", systemImage: "iphone")
                Spacer()
                Text("\(SystemVersionName.display(version: WorseQueryEscape.processVersion, build: WorseQueryEscape.processBuildVersion))\(WorseQueryEscape.isSupported(deviceVersion: WorseQueryEscape.processVersion, buildVersion: WorseQueryEscape.processBuildVersion) ? "（在范围内）" : "（不在范围内）")")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label("生效方式", systemImage: "hand.tap")
                Spacer()
                Text("刷完上滑关闭 PosterBoard")
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top) {
                Label("App Group", systemImage: "person.2")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let group = WorseQueryEscape.discoveredGroupIdentifier {
                        Text(group).font(.caption.monospaced())
                        Text("签名授予，容器可打开")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("没有可用的组")
                            .foregroundStyle(.orange)
                        Text("签名没有授予 App Group，或授予的组都打不开")
                            .font(.caption2).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            Text("组名在运行时从安装包内嵌的签名描述文件读取。能用的组只有证书签名才带：免费 ID 签和 SideStore / AltStore 都用不了本机直刷。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    #if DRIFT_ENUM_PROBE
    // MARK: - Enumeration probe

    /// Temporary probe UI. The compile condition is empty in every normal
    /// build, so this section and its button do not exist there at all.
    private var probeSection: some View {
        Section("枚举测速（探针）") {
            Text("插电、前台、屏幕常亮，中途不要操作。点一次会依次跑 1→2→4→6 线程：先扫 max_inode 的前 1/4，再扫全范围，最后补跑一次 1 线程交叉复核。")
                .font(.caption).foregroundStyle(.secondary)
            Text("只枚举路径：不 consume、不探身份、不清缓存、不写壁纸；临时上限文件跑完删除。")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                startEnumerationProbe()
            } label: {
                Label(probeRunning ? "正在测速…" : "枚举测速", systemImage: "speedometer")
            }
            .disabled(probeRunning)
            // #292: while a run is going, show where it stands — tier x
            // of 9, the tier now scanning, each finished tier's time as
            // it lands, elapsed time and a rough remaining estimate.
            // Finished tiers stay listed if a later tier fails.
            if probeRunning || !probeDoneLines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if probeRunning {
                        Text("正在测速：第 \(probeTierIndex) / \(probeTierTotal) 档（\(probeCurrentTier)）")
                            .font(.caption.weight(.semibold))
                        ProgressView(value: probeDoneWeight, total: 24)
                        if let started = probeStartedAt {
                            TimelineView(.periodic(from: started, by: 1)) { context in
                                let elapsed = context.date.timeIntervalSince(started)
                                Text(probeEstimateText(elapsed: elapsed))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(Array(probeDoneLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if !probeStatus.isEmpty {
                Text(probeStatus)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("每档写一行日志：线程数、max_inode 原值、实际扫描数、命中数、耗时 ms、每秒扫描数，以及与本轮 1 线程名单是否一致。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .driftActionSheet(isPresented: $probeShowDone, title: "测速完成",
                          message: probeDoneMessage,
                          actions: [DriftSheetAction("知道了") {}])
        .driftActionSheet(isPresented: $probeShowFailed, title: "出错了",
                          message: probeFailedMessage,
                          actions: [DriftSheetAction("知道了") {}])
    }

    /// Rough remaining time from the tier weights (a full-range tier
    /// weighs four quarter tiers). Only shown once at least one tier has
    /// finished — before that there is no honest basis for an estimate.
    private func probeEstimateText(elapsed: TimeInterval) -> String {
        let used = Self.probeTimeText(elapsed)
        guard probeDoneWeight > 0 else { return "已用 \(used)" }
        let remaining = elapsed / probeDoneWeight * (24 - probeDoneWeight)
        return "已用 \(used)，粗估还剩 \(Self.probeTimeText(remaining))"
    }

    private static func probeTimeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) 秒" }
        return "\(total / 60) 分 \(total % 60) 秒"
    }

    /// One progress event from the detached probe run. The run reports
    /// through an AsyncStream because its continuation is Sendable —
    /// the callbacks capture nothing but it, which keeps Swift 6 happy
    /// without the view itself crossing into the detached task.
    private enum ProbeEvent {
        case tierStart(index: Int, total: Int, name: String)
        case tierDone(line: String, weight: Double)
    }

    private func startEnumerationProbe() {
        guard !probeRunning else { return }
        probeRunning = true
        probeStatus = ""
        probeTierIndex = 0
        probeCurrentTier = ""
        probeDoneLines = []
        probeDoneWeight = 0
        probeStartedAt = Date()
        let started = Date()
        let (stream, continuation) = AsyncStream<ProbeEvent>.makeStream()
        Task {
            for await event in stream {
                switch event {
                case .tierStart(let index, let total, let name):
                    probeTierIndex = index
                    probeTierTotal = total
                    probeCurrentTier = name
                case .tierDone(let line, let weight):
                    probeDoneLines.append(line)
                    probeDoneWeight += weight
                }
            }
        }
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.runEnumerationProbe { index, total, name in
                    continuation.yield(.tierStart(index: index, total: total, name: name))
                } onTierDone: { line, weight in
                    continuation.yield(.tierDone(line: line, weight: weight))
                }
            }.value
            continuation.finish()
            probeRunning = false
            let total = Self.probeTimeText(Date().timeIntervalSince(started))
            switch outcome {
            case .finished:
                probeDoneMessage = "9 档都跑完了，一共用了 \(total)。请回到设置页点「上传日志」，把日志传回来。"
                probeShowDone = true
            case .failed(let reason):
                // The finished tiers' lines stay on the page behind the
                // sheet — a failed run does not throw its data away.
                probeFailedMessage = reason
                probeShowFailed = true
            }
        }
    }

    private enum ProbeOutcome {
        case finished
        case failed(String)
    }

    /// Runs the nine tiers in order, reporting each tier's start and
    /// finish (one display line plus the tier's weight toward the rough
    /// estimate) through the callbacks. Tier weights: a quarter-range
    /// tier counts 1, a full-range tier 4 — 24 in all.
    private static func runEnumerationProbe(onTierStart: @Sendable @escaping (Int, Int, String) -> Void,
                                            onTierDone: @Sendable @escaping (String, Double) -> Void) -> ProbeOutcome {
        guard let bound = WorseQueryEscape.pathleakInodeUpperBound() else {
            AppLog.failure("枚举探针：无法创建 inode 上限临时文件")
            return .failed("没有跑成：建不了临时上限文件。跑完的档位数据还在上面，详情见日志。")
        }
        defer { bound.cleanup() }

        let maxInode = bound.maxInode
        let quarter = max(1, maxInode / 4)
        AppLog.write("枚举探针：开始 max_inode=\(maxInode)，1/4 范围 1...\(quarter)，全范围 1...\(maxInode)")

        var tier = 0
        let totalTiers = 9
        _ = runProbeRound(label: "1/4", limit: quarter, maxInode: maxInode, weight: 1,
                          tier: &tier, totalTiers: totalTiers,
                          onTierStart: onTierStart, onTierDone: onTierDone)
        let fullBaseline = runProbeRound(label: "全范围", limit: maxInode, maxInode: maxInode,
                                         weight: 4, tier: &tier, totalTiers: totalTiers,
                                         onTierStart: onTierStart, onTierDone: onTierDone)

        // The after-run single-thread pass exists so a hot device slowing the
        // later parallel rounds cannot be mistaken for a parallel regression.
        tier += 1
        onTierStart(tier, totalTiers, "全范围复核 · 1 线程")
        let check = WorseQueryEscape.measurePathleak(threads: 1, limit: maxInode)
        let checkComparison = compare(check.paths, to: fullBaseline)
        logProbeLine(label: "全范围复核", threads: 1, maxInode: maxInode,
                     scannedInodes: maxInode, hitCount: check.paths.count,
                     milliseconds: check.milliseconds,
                     comparison: checkComparison)
        onTierDone(probeDisplayLine(range: "全范围复核", threads: 1,
                                    milliseconds: check.milliseconds,
                                    comparison: checkComparison), 4)

        AppLog.write("枚举探针：完成 max_inode=\(maxInode)")
        return .finished
    }

    @discardableResult
    private static func runProbeRound(label: String, limit: UInt64, maxInode: UInt64,
                                      weight: Double, tier: inout Int, totalTiers: Int,
                                      onTierStart: @Sendable (Int, Int, String) -> Void,
                                      onTierDone: @Sendable (String, Double) -> Void) -> [String] {
        var baseline: [String] = []
        for threads in [1, 2, 4, 6] {
            tier += 1
            onTierStart(tier, totalTiers, "\(label)范围 · \(threads) 线程")
            let sample = WorseQueryEscape.measurePathleak(threads: threads, limit: limit)
            if threads == 1 { baseline = sample.paths }
            let comparison = threads == 1
                ? "基准（本轮 1 线程）"
                : compare(sample.paths, to: baseline)
            logProbeLine(label: label, threads: threads, maxInode: maxInode,
                         scannedInodes: limit, hitCount: sample.paths.count,
                         milliseconds: sample.milliseconds,
                         comparison: comparison)
            onTierDone(probeDisplayLine(range: "\(label)范围", threads: threads,
                                        milliseconds: sample.milliseconds,
                                        comparison: comparison), weight)
        }
        return baseline
    }

    /// One finished tier's line on the progress page: range, threads,
    /// time, and the list verdict in short form.
    private static func probeDisplayLine(range: String, threads: Int,
                                         milliseconds: Double, comparison: String) -> String {
        let verdict = comparison.hasPrefix("一致") ? "名单一致"
            : comparison.hasPrefix("基准") ? "基准"
            : "名单不一致"
        return "\(range) · \(threads) 线程：\(probeTimeText(milliseconds / 1000))（\(verdict)）"
    }

    private static func logProbeLine(label: String, threads: Int, maxInode: UInt64,
                                     scannedInodes: UInt64, hitCount: Int,
                                     milliseconds: Double, comparison: String) {
        let seconds = milliseconds / 1000
        let perSecond = seconds > 0 ? Double(scannedInodes) / seconds : 0
        AppLog.write(String(format: "枚举探针 %@：线程=%d max_inode原值=%llu 实际扫描=%llu 命中=%d 耗时=%.1fms 每秒=%.0f 名单%@",
                            label, threads, maxInode, scannedInodes, hitCount,
                            milliseconds, perSecond, comparison))
    }

    private static func compare(_ candidate: [String], to baseline: [String]) -> String {
        if candidate == baseline {
            return "一致（条数 \(candidate.count)/\(baseline.count)，逐条相同）"
        }
        let candidateSet = Set(candidate)
        let baselineSet = Set(baseline)
        let missing = baselineSet.subtracting(candidateSet).count
        let extra = candidateSet.subtracting(baselineSet).count
        let duplicates = candidate.count - candidateSet.count
        let orderOnly = candidate.count == baseline.count && candidateSet == baselineSet
        return "不一致（条数 \(candidate.count)/\(baseline.count)，少 \(missing)，多 \(extra)，重复 \(duplicates)\(orderOnly ? "，顺序不同" : "")）"
    }
    #endif

    private func deleteReceipt(_ receipt: PosterBoardLocalReceipt) async {
        do {
            let outcome = try await PosterBoardManagement.delete(
                receipt, tunnelReady: tunnelReady) { line in
                DriftEngine.shared.log(line)
            }
            receipts = PosterBoardLocalReceipts.load()
            history = ApplyHistory.load()
            if outcome.confirmed {
                // #161 applies here too: prompt by the channel the
                // receipt says flashed it; the tap executes at once.
                deleteActivationKind = switch receipt.resolvedChannel {
                case .local: .endPosterBoard
                case .direct: .restartPosterBoard
                case .airlift: .respring
                }
                deleteActivationMessage = outcome.message
                showDeleteActivation = true
            } else {
                recordsNote = outcome.message
            }
        } catch {
            receipts = PosterBoardLocalReceipts.load()
            history = ApplyHistory.load()
            session.errorText = error.localizedDescription
        }
    }

    /// Execute the post-deletion activation the user tapped (#161,
    /// Settings path). Feedback lands in the records note, like every
    /// other Settings deletion outcome.
    private func runDeleteActivation() {
        switch deleteActivationKind {
        case .endPosterBoard:
            let opened = PosterBoardLaunch.open()
            recordsNote = opened
                ? "已打开 PosterBoard：请从应用切换器中关闭它，然后检查锁定屏幕壁纸选择器，删掉的壁纸就没了。"
                : "没能自动打开 PosterBoard：请打开锁定屏幕壁纸选择器来刷新；如果删掉的壁纸还在，从应用切换器关闭 PosterBoard 后再看。"
        case .restartPosterBoard:
            Task {
                let result = await session.restartPosterBoardUnderCover()
                recordsNote = result.status.explanation + (result.confirmed
                    ? "。删掉的壁纸已经生效移除。"
                    : "。可以连上隧道再试，或改用注销。")
            }
        case .respring:
            session.respringUnderCover()
        }
    }

    /// The tunnel premises the management deletion needs, read live from the
    /// session and the monitor rather than from a snapshot.
    private var tunnelReady: Bool {
        session.paired && tunnelMonitor.status == .ready
    }

    @ViewBuilder
    private var wirelessPairingRows: some View {
        if #available(iOS 27.0, *) {
            switch wirelessPair.phase {
            case .idle:
                Button { wirelessPair.start() } label: {
                    Label("无线自配对（iOS 27）", systemImage: "wifi")
                }
            case .advertising:
                // #183 (Grace, 2026-11-11): no service-UUID line — the
                // code lives in the log when anyone needs it. Cancel
                // rides the status row's trailing edge.
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("正在等待设备连接…", systemImage: "wifi")
                        Spacer()
                        Button("取消", role: .destructive) { wirelessPair.cancel() }
                            .buttonStyle(.borderless)
                    }
                    if let pin = wirelessPair.pin {
                        Text("配对码：\(pin)").font(.body.weight(.semibold))
                        // #180: with notifications off the code can only
                        // be read here — say so where the user stands.
                        if !notificationsAllowed {
                            Text("通知没开，验证码只能回到这里看；想在系统设置里也收到，去系统设置里给 Drift 打开通知。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            case .paired:
                Label("无线配对完成", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Label("无线配对失败", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button("重试") { wirelessPair.start() }
                }
            }
        }
    }

    private func adoptWirelessRecord(at path: String?) {
        guard let path else { return }
        defer { wirelessPair.reset() }
        do {
            let record = path == AppPaths.pairingFile.path
                ? try PairingRecord.adoptFromDisk()
                : try PairingRecord.accept(contentsOf: URL(fileURLWithPath: path))
            if path != AppPaths.pairingFile.path { PairingRecord.persist(record) }
            session.adoptPairingFromDisk()
            DriftEngine.shared.log("settings: wireless pairing record adopted (\(PairingRecord.sourceLabel(record)))")
        } catch {
            session.errorText = error.localizedDescription
        }
    }

    // MARK: - Restore method (sealed)

    /// The sealed restore entry (2.0.0): visible and greyed, never
    /// selectable. There is no restore code behind it — safety by
    /// non-existence. Tapping the row shows the sealing notice; the
    /// pre-2.0.0 local-backup write-back/delete actions went away with
    /// the backup machinery they belonged to.
    private var restoreSealedSection: some View {
        Section("恢复刷") {
            Button {
                showSealedNotice = true
            } label: {
                HStack {
                    Label("恢复刷", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("已封存")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Text("2026-11-10 一次恢复刷入在重启后把设备恢复了出厂设置。查清原因并在备用机上验证之前不开放；点上面这一行看完整说明。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // Feedback #24: the history used to expand all 20 records inline and
    // stretch the whole settings page. It lives in a fixed-height box now
    // and scrolls inside itself. Feedback #83: receipts are merged into the
    // same list; the two stores stay separate underneath.
    private var historySection: some View {
        Section("刷入记录") {
            // #280 (Grace, 2026-11-13): no manager entry here any
            // more — 本机壁纸管理 lives on Home now, under the flash
            // button. This section is just the records.
            let rows = mergedRecords
            if rows.isEmpty {
                Text("暂无记录").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(rows) { row in
                            mergedRow(row)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 220)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            if !history.isEmpty {
                Button(role: .destructive) {
                    confirmClearHistory = true
                } label: {
                    Label("清空记录", systemImage: "trash")
                }
            }
            // #256 (Grace, 2026-11-12): no standing status line here any
            // more — export outcomes arrive as a popup at action time.
            // The explanatory footnote below stays, at her explicit word.
            Text("带「删除」的条目删的是设备上的壁纸；点「导出」可以把某次刷入的记录、那次的日志和壁纸包打包。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Per-record export (#237/#238)

    /// Build the tapped record's bundle, then offer the three things the
    /// user can do with it: save it as a file, share it, or save and
    /// upload it to the log inbox.
    private func startRecordExport(_ record: ApplyHistory.Record) {
        guard !recordBusy else { return }
        recordBusy = true
        Task {
            defer { recordBusy = false }
            do {
                exportBundle = try RecordExport.build(for: record)
                exportTarget = record
                showExportChoices = true
            } catch {
                presentExportOutcome(title: "出错了",
                                     message: "打包失败：\(error.localizedDescription)")
            }
        }
    }

    private func saveRecordExport() {
        guard let bundle = exportBundle else { return }
        do {
            _ = try RecordExport.saveToFiles(bundle)
            presentExportOutcome(title: "已存成文件")
        } catch {
            presentExportOutcome(title: "出错了",
                                 message: "存文件失败：\(error.localizedDescription)")
        }
    }

    private func uploadRecordExport() {
        guard let bundle = exportBundle, let record = exportTarget else { return }
        recordBusy = true
        Task {
            defer { recordBusy = false }
            // The full bundle always lands in Files first; what goes up
            // may be a slimmer rebuild of it (#257).
            do {
                _ = try RecordExport.saveToFiles(bundle)
            } catch {
                presentExportOutcome(title: "出错了",
                                     message: "存文件失败：\(error.localizedDescription)")
                return
            }
            var uploadURL = bundle.url
            if bundle.tooBigToUpload {
                // #257 (Grace, 2026-11-12): over the 24 MB door the pack
                // stays behind — rebuild without the wallpaper packs and
                // upload record + log only, the 缺失说明 inside saying
                // exactly that. The full bundle is already saved above.
                do {
                    let slim = try RecordExport.build(for: record, includePacks: false)
                    uploadURL = slim.url
                } catch {
                    presentExportOutcome(title: "出错了",
                                         message: "文件已存好，但打包上传版失败：\(error.localizedDescription)")
                    return
                }
            }
            do {
                try await LogUpload.uploadBig(package: uploadURL)
                // #256: the success popup is the title and nothing else.
                presentExportOutcome(title: "上传成功")
            } catch {
                presentExportOutcome(title: "出错了",
                                     message: "文件已存好，但上传失败：\(error.localizedDescription)")
            }
        }
    }

    @ViewBuilder
    private func mergedRow(_ row: MergedRecord) -> some View {
        switch row.kind {
        case .run(let record):
            // #185 (Grace, 2026-11-11): icon + pack name + method + time,
            // nothing else. The full detail stays in the record itself
            // and in the log package.
            HStack(spacing: 8) {
                Image(systemName: record.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(record.success ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recordTitle(record))
                        .font(.subheadline)
                    Text(recordMeta(record))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // #237/#238: one record exports on its own — record +
                // that run's log slice + the original pack, by hand only.
                Button {
                    startRecordExport(record)
                } label: {
                    Text("导出").font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(recordBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .receipt(let receipt):
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(receipt.pack).font(.subheadline)
                    Text("\(receipt.channelLabel) · \(displayTime(receipt.date))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    receiptToDelete = receipt
                } label: {
                    Text("删除").font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// #185: the row's title — the pack name when the record carries
    /// one; deletion records written before build 19 keep their name
    /// inside the mode text; older flash records have no name at all
    /// and fall back to the method text.
    private func recordTitle(_ record: ApplyHistory.Record) -> String {
        if let name = record.packName, !name.isEmpty { return name }
        if record.mode.hasPrefix("删除壁纸 · ") {
            return String(record.mode.dropFirst("删除壁纸 · ".count))
        }
        return recordMethod(record)
    }

    /// #185: the row's second line — method and time (plus the 删除
    /// marker that tells a deletion record from a flash record).
    private func recordMeta(_ record: ApplyHistory.Record) -> String {
        let time = displayTime(record.timestamp)
        if record.mode.hasPrefix("删除壁纸 · ") {
            return "删除 · \(recordMethod(record)) · \(time)"
        }
        if let name = record.packName, !name.isEmpty {
            return "\(recordMethod(record)) · \(time)"
        }
        return time
    }

    /// The method a record shows: the stamped channel when there is
    /// one, else the mode text's leading segment. Route words from the
    /// management layer are dressed back up to method names.
    private func recordMethod(_ record: ApplyHistory.Record) -> String {
        if let channel = record.channel, !channel.isEmpty {
            return channel == "本机" ? "本机直刷" : channel
        }
        return String(record.mode.split(separator: "·").first ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Record timestamps are ISO strings; rows show a human local
    /// time ("11月11日 21:44") instead.
    private func displayTime(_ raw: String) -> String {
        let date = parsedRecordDate(raw)
        guard date != .distantPast else { return raw }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                notificationsAllowed = settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
            }
        }
    }

    private var mergedRecords: [MergedRecord] {
        var rows: [MergedRecord] = []
        for (index, record) in history.enumerated() {
            rows.append(MergedRecord(
                id: "run-\(index)-\(record.timestamp)-\(record.mode)",
                date: parsedRecordDate(record.timestamp),
                kind: .run(record)))
        }
        for receipt in receipts {
            rows.append(MergedRecord(
                id: "receipt-\(receipt.id)",
                date: parsedRecordDate(receipt.date),
                kind: .receipt(receipt)))
        }
        return rows.sorted { $0.date > $1.date }
    }

    private func parsedRecordDate(_ raw: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? .distantPast
    }

    // MARK: - Records

    // MARK: - Records (feedback #23: one package, not three exports)
    //
    // The old section had a generate button plus three separate share rows —
    // slow to export and the files scattered across testers. One entry now:
    // tap, a fresh diagnostics report is written, all three files are zipped
    // together, and the share sheet opens on the package.

    private var recordsSection: some View {
        // #278 (Grace, 2026-11-13): the section is called 日志 now —
        // everything in it is log-shaped, and it no longer reads like
        // the 刷入记录 section above it.
        Section("日志") {
            NavigationLink {
                DriftLogView()
            } label: {
                Label("运行日志", systemImage: "doc.text")
            }
            Button {
                Task { await makeLogPackage() }
            } label: {
                Label(packaging ? "正在打包…" : "打包分享记录",
                      systemImage: "doc.zipper")
            }
            .disabled(packaging)
            Button {
                confirmUpload = true
            } label: {
                Label(uploading ? "正在上传" : "上传日志",
                      systemImage: "arrow.up.doc")
            }
            .disabled(uploading || packaging)
            if let recordsNote {
                Text(recordsNote)
                    .font(.caption).foregroundStyle(.secondary)
            }
            // #277/#279 (Grace, 2026-11-13): no upload or packaging
            // outcome stands in this section as small print any more —
            // they arrive as the bottom-sheet popup, like the record
            // export outcomes (#256).
            Text("出问题时点这里打包，把整包发出去就行，不用再一个个找文件。也可以点「上传日志」直接传给开发者，不用自己转发。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func uploadLogs() async {
        uploading = true
        defer { uploading = false }
        let started = Date()
        AppLog.op("设置：点上传日志")
        let package: URL
        do {
            package = try await LogPackage.build()
        } catch {
            AppLog.failure("上传日志：打包没成 — \(error.localizedDescription)")
            // #277: the outcome is the popup, not a line in the section.
            presentExportOutcome(title: "出错了", message: "上传失败：日志打包没成。")
            return
        }
        do {
            try await LogUpload.upload(package: package)
            AppLog.op("上传日志：已传 \(package.lastPathComponent)")
            AppLog.timing("上传日志", since: started)
            // #277: success is the popup and nothing else, exactly
            // like the record export's (#256).
            presentExportOutcome(title: "上传成功")
        } catch {
            AppLog.failure("上传日志：没传上去 — \(error.localizedDescription)")
            presentExportOutcome(title: "出错了",
                                 message: "上传失败：\(error.localizedDescription)")
        }
    }

    private func makeLogPackage() async {
        packaging = true
        recordsNote = nil
        defer { packaging = false }
        AppLog.op("设置：点打包分享记录")
        do {
            let package = try await LogPackage.build()
            AppLog.op("打包分享记录：已打包 \(package.lastPathComponent)")
            // #279 (Grace, 2026-11-13): no 「已打包：…」 line stands in
            // the section afterwards — the share sheet opening IS the
            // success signal. Failure still speaks, as a popup.
            sharePackage = SharePackageItem(url: package)
        } catch {
            AppLog.failure("打包分享记录：打包失败 — \(error.localizedDescription)")
            presentExportOutcome(title: "出错了",
                                 message: "打包失败：\(error.localizedDescription)")
        }
    }

    // MARK: - About

    private var appSection: some View {
        Section("应用") {
            NavigationLink {
                AppUpdateView()
            } label: {
                HStack {
                    Label("检查更新", systemImage: "arrow.down.circle")
                    Spacer()
                    if updateChecker.updateAvailable, let latest = updateChecker.latest {
                        Text("有新版 \(latest.version)")
                            .foregroundStyle(.red)
                    } else {
                        Text(updateChecker.currentVersion).foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                confirmClearCache = true
            } label: {
                HStack {
                    Label("清除缓存", systemImage: "trash")
                    Spacer()
                    Text(cacheBreakdown.map { AppCache.format($0.total) } ?? "…")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(cacheBreakdown == nil || cacheBreakdown?.total == 0)
            if let cacheNote {
                Text(cacheNote).font(.caption).foregroundStyle(.secondary)
            }
            Text("缓存只清能再生的：壁纸预览图、目录缓存、抓取临时文件、日志和检查更新下载的安装包。配对文件、回执、刷入记录、设置和导入的壁纸包都不动。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            cacheBreakdown = await Task.detached { AppCache.measure() }.value
        }
        // #293 (Grace, 2026-11-13): the clear-cache confirmation sheet
        // used to hang off THIS section. On a cold launch the section's
        // own `.task` above lands its `cacheBreakdown` write right
        // around the user's first tap, the section's view is rebuilt,
        // and a sheet presented from inside the section is torn down
        // with it — the dialog flashed and vanished, and only the
        // second tap (nothing left in flight) held. The sheet now
        // hangs off the root view like every other confirmation in
        // this file; the measurement stays here where its data lives.
    }

    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("版本")
                Spacer()
                Text("Drift \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")")
                    .foregroundStyle(.secondary)
            }
            Text("独立应用，只保留刷壁纸功能。设备写入核心源自 AirCard-iOS（Mak5er 著，MIT 许可证）的隧道写入核心（回环隧道、配对、同步写入、注入）；免注销生效、商店枚举与本机直刷通道、界面为 Drift 自有部分（AGPL-3.0）。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The run log as its own page (the cards on the wallpaper/video pages show
/// the same store inline during a run).
struct DriftLogView: View {
    @ObservedObject private var log = RunLog.shared

    var body: some View {
        List {
            if log.lines.isEmpty {
                Text("暂无日志").foregroundStyle(.secondary)
            }
            ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced())
            }
        }
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空") { RunLog.shared.clear() }
            }
        }
    }
}

/// The built log package, carried to the share sheet (feedback #23).
private struct SharePackageItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// The system share sheet for one file. The rest of the app shares through
/// `ShareLink`; the package flow needs the sheet to open BY ITSELF once the
/// zip exists, which is the one thing ShareLink cannot do.
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}


/// One row of the merged apply history: either an operation record or a
/// write receipt. The two underlying stores are not migrated or combined.
private struct MergedRecord: Identifiable {
    enum Kind {
        case run(ApplyHistory.Record)
        case receipt(PosterBoardLocalReceipt)
    }

    let id: String
    let date: Date
    let kind: Kind
}
