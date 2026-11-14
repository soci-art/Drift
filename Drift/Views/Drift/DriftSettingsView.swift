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
    /// #315: the merged history rows, rebuilt only when the page
    /// appears or the records change — the computed property used to
    /// re-merge and re-sort on every render.
    @State private var mergedRows: [MergedRecord] = []
    @State private var packaging = false
    @State private var sharePackage: SharePackageItem?
    @State private var recordsNote: String?
    @State private var showSealedNotice = false
    @State private var receipts: [PosterBoardLocalReceipt] = PosterBoardLocalReceipts.load()
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
    // #312 (Grace, 2026-11-13): the clear-cache outcome is a popup
    // now, not a standing line under the button — the same rule the
    // upload outcomes got in #277.
    @State private var showCacheCleared = false
    @State private var cacheClearedMessage = ""
    @State private var notificationsAllowed = true
    @State private var showAnnouncement = false
    @State private var uploading = false
    @State private var confirmUpload = false
    var body: some View {
        NavigationStack {
            List {
                aboutEntrySection
                announcementSection
                connectionSection
                localRouteSection
                restoreSealedSection
                historySection
                recordsSection
                appSection
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            // #304: the one flat page background, like every page.
            .scrollContentBackground(.hidden)
            .background { DriftBackground() }
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
                refreshMergedRows()
                refreshNotificationStatus()
            }
            .onChange(of: wirelessPair.pin) { _, _ in
                refreshNotificationStatus()
            }
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
                                        // #312: the result arrives as
                                        // the popup below, presented
                                        // from the root like this
                                        // confirmation (#293).
                                        cacheClearedMessage = "省出约 \(AppCache.format(freed))。"
                                        showCacheCleared = true
                                    }
                                },
                              ])
            .driftActionSheet(isPresented: $showCacheCleared, title: "清除完成",
                              message: cacheClearedMessage,
                              actions: [DriftSheetAction("知道了") {}])
            .driftActionSheet(isPresented: $confirmClearHistory, title: "清空全部刷入记录？",
                              message: "记录清空后无法恢复。此操作只清记录，不会删除设备上已刷入的壁纸——要删壁纸请用主页的「本机壁纸管理」。",
                              actions: [
                                DriftSheetAction("清空记录", destructive: true) {
                                    ApplyHistory.clear()
                                    history = []
                                    refreshMergedRows()
                                    recordsNote = "刷入记录已清空；回执没有动，管理页仍能认出已刷的壁纸。"
                                },
                              ])
            .alert("恢复刷已封存", isPresented: $showSealedNotice) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(DriftRestoreGate.notice)
            }
            .sheet(item: $sharePackage) { item in
                FileShareSheet(url: item.url)
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

    // MARK: - About entry

    /// The About page's entry (Grace, 2026-11-13, #295/#297 merged):
    /// pinned at the very top of Settings, above even the announcement
    /// row. The author, the GitHub links, the QQ group card, the
    /// reward code and the tunnel-core credit all live on that page
    /// now — the small About section that used to sit at the bottom
    /// of this list is gone, its contents moved there.
    private var aboutEntrySection: some View {
        Section {
            NavigationLink {
                AboutAppView()
            } label: {
                Label("关于此 App", systemImage: "info.circle")
            }
            // Collection #329 (Grace, 2026-11-14): the experimental
            // features page sits with About — 内核直刷 and 恢复刷
            // live there behind their switches, nowhere else.
            NavigationLink {
                ExperimentalFeaturesView()
            } label: {
                Label("实验性功能", systemImage: "flask")
            }
        }
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

    // Collection #306 (Grace, 2026-11-13): deleting a wallpaper from
    // a record lived here until today. It moved to the management
    // page on Home — records are a ledger now, nothing on this page
    // touches the device store.

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
            let rows = mergedRows
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
            // #306 (Grace, 2026-11-13): the footnote tells the new
            // truth — records are a ledger; wallpaper deletion lives
            // in 本机壁纸管理 now. (The #256 ruling keeps a footnote
            // here; its text follows the move.)
            Text("这里只是刷入的流水账，删记录不会删掉设备上的壁纸。要删壁纸，去主页的「本机壁纸管理」。点「导出」可以把某次刷入的记录、那次的日志和壁纸包打包。")
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
            // #306 (Grace, 2026-11-13): a receipt row is display-only
            // now. Its 删除 button used to delete the wallpaper on the
            // device; that job moved to 本机壁纸管理. The receipt
            // itself stays — it is the proof the management page
            // matches a store entry against (#307), so nothing here
            // offers to remove it either.
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(receipt.pack).font(.subheadline)
                    Text("\(receipt.channelLabel) · \(displayTime(receipt.date))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
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

    /// #315: the two formatters are shared statics — displayTime and
    /// parsedRecordDate used to build a fresh one per row per render.
    private static let recordTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let recordISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let recordISOFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Record timestamps are ISO strings; rows show a human local
    /// time ("11月11日 21:44") instead.
    private func displayTime(_ raw: String) -> String {
        let date = parsedRecordDate(raw)
        guard date != .distantPast else { return raw }
        return Self.recordTimeFormatter.string(from: date)
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                notificationsAllowed = settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
            }
        }
    }

    /// Rebuilds `mergedRows` from the two stores (#315: was a
    /// computed property re-run on every render). Called when the
    /// page appears and after 清空记录 — the only in-page mutation.
    private func refreshMergedRows() {
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
        mergedRows = rows.sorted { $0.date > $1.date }
    }

    private func parsedRecordDate(_ raw: String) -> Date {
        if let date = Self.recordISOFormatter.date(from: raw) { return date }
        return Self.recordISOFractionalFormatter.date(from: raw) ?? .distantPast
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

    // MARK: - App

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
        .scrollContentBackground(.hidden)
        .background { DriftBackground() }
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
