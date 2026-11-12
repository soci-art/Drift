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
    @ObservedObject private var updateChecker = AppUpdateChecker.shared
    @State private var cacheBreakdown: AppCache.Breakdown?
    @State private var confirmClearCache = false
    @State private var cacheNote: String?
    @State private var notificationsAllowed = true
    @State private var showAnnouncement = false
    @State private var uploading = false
    @State private var confirmUpload = false
    @State private var uploadNote: String?

    var body: some View {
        NavigationStack {
            List {
                announcementSection
                connectionSection
                localRouteSection
                restoreSealedSection
                historySection
                recordsSection
                appSection
                aboutSection
            }
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
            .alert("上传日志？", isPresented: $confirmUpload) {
                Button("上传") { Task { await uploadLogs() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("把这份记录包（诊断信息和运行日志）传给开发者，只用来排查问题。")
            }
            .onChange(of: wirelessPair.generatedRecordPath) { _, path in
                adoptWirelessRecord(at: path)
            }
            .onAppear {
                history = ApplyHistory.load()
                receipts = PosterBoardLocalReceipts.load()
                refreshNotificationStatus()
            }
            .onChange(of: wirelessPair.pin) { _, _ in
                refreshNotificationStatus()
            }
            .alert("删除这张壁纸？", isPresented: Binding(
                get: { receiptToDelete != nil },
                set: { if !$0 { receiptToDelete = nil } })
            ) {
                Button("删除", role: .destructive) {
                    guard let receipt = receiptToDelete else { return }
                    receiptToDelete = nil
                    Task { await deleteReceipt(receipt) }
                }
                Button("取消", role: .cancel) { receiptToDelete = nil }
            } message: {
                if let receipt = receiptToDelete {
                    Text("「\(receipt.pack)」将被删除。如果删的正是当前正在用的壁纸，生效后系统会换回默认壁纸。")
                }
            }
            .alert("清空全部刷入记录？", isPresented: $confirmClearHistory) {
                Button("清空记录", role: .destructive) {
                    ApplyHistory.clear()
                    history = []
                    recordsNote = "刷入记录已清空；回执没有动，管理页仍能认出已刷的壁纸。"
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("记录清空后无法恢复。此操作只清记录，不会删除设备上已刷入的壁纸——要删壁纸请用「管理刷入的壁纸」。")
            }
            .alert("删除完成", isPresented: $showDeleteActivation) {
                Button(deleteActivationKind.actionTitle) { runDeleteActivation() }
                Button("稍后再说", role: .cancel) {}
            } message: {
                Text(deleteActivationMessage + "\n\n" + deleteActivationKind.needText)
            }
            .alert("恢复刷已封存", isPresented: $showSealedNotice) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(DriftRestoreGate.notice)
            }
            .sheet(item: $sharePackage) { item in
                ActivityShareSheet(url: item.url)
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
                .alert("删除当前配对？", isPresented: $confirmResetPairing) {
                    Button("删除", role: .destructive) { session.resetPairing() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("App 会忘掉这份配对记录，文件本身保留在 App 文档里；重新导入即可恢复。")
                }
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
            // Feedback #29: the tutorial lives directly under the guide
            // row — the guide walks the connection setup once, the
            // tutorial is the standing how-to for everyday flashing.
            NavigationLink {
                DriftTutorialView()
            } label: {
                Label("使用教程", systemImage: "book")
            }
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
                Text(WorseQueryEscape.isSupported(deviceVersion: WorseQueryEscape.processVersion,
                                                 buildVersion: WorseQueryEscape.processBuildVersion)
                     ? "iOS \(WorseQueryEscape.processVersion)\(WorseQueryEscape.processBuildVersion.isEmpty ? "" : "（\(WorseQueryEscape.processBuildVersion)）")（在范围内）"
                     : "iOS \(WorseQueryEscape.processVersion)（不在范围内）")
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
            NavigationLink {
                PosterBoardManagerView()
            } label: {
                Label("管理刷入的壁纸", systemImage: "square.stack.3d.up")
            }
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
            Text("带「删除」的条目删的是设备上的壁纸；其余只是历史记录。")
                .font(.caption).foregroundStyle(.secondary)
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
        Section("记录") {
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
            if let uploadNote {
                Text(uploadNote)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("出问题时点这里打包，把整包发出去就行，不用再一个个找文件。也可以点「上传日志」直接传给开发者，不用自己转发。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func uploadLogs() async {
        uploading = true
        uploadNote = nil
        defer { uploading = false }
        let package: URL
        do {
            package = try await LogPackage.build()
        } catch {
            AppLog.write("records: upload FAILED at packaging — \(error.localizedDescription)")
            uploadNote = "上传失败：日志打包没成"
            return
        }
        do {
            try await LogUpload.upload(package: package)
            AppLog.write("records: uploaded log package \(package.lastPathComponent)")
            uploadNote = "上传成功"
        } catch {
            AppLog.write("records: upload FAILED — \(error.localizedDescription)")
            uploadNote = "上传失败：\(error.localizedDescription)"
        }
    }

    private func makeLogPackage() async {
        packaging = true
        recordsNote = nil
        defer { packaging = false }
        do {
            let package = try await LogPackage.build()
            AppLog.write("records: packaged diagnostics + logs into \(package.lastPathComponent)")
            recordsNote = "已打包：\(package.lastPathComponent)，在弹出的分享里发出去就行。"
            sharePackage = SharePackageItem(url: package)
        } catch {
            AppLog.write("records: packaging FAILED — \(error.localizedDescription)")
            recordsNote = "打包失败：\(error.localizedDescription)"
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
        .alert("清除这些缓存？", isPresented: $confirmClearCache) {
            Button("清除", role: .destructive) {
                Task {
                    let freed = await Task.detached { AppCache.clear() }.value
                    cacheBreakdown = await Task.detached { AppCache.measure() }.value
                    cacheNote = "已清除，省出约 \(AppCache.format(freed))。"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let cacheBreakdown {
                Text("预览图 \(AppCache.format(cacheBreakdown.previews))、目录缓存 \(AppCache.format(cacheBreakdown.catalogCache))、临时文件 \(AppCache.format(cacheBreakdown.fetchScratch))、日志 \(AppCache.format(cacheBreakdown.logs))、下载的安装包 \(AppCache.format(cacheBreakdown.updates))，共 \(AppCache.format(cacheBreakdown.total))。")
            }
        }
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
