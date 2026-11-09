import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @State private var autoConvert = PosterBoardPreferences.autoConvertLegacy
    @State private var packaging = false
    @State private var sharePackage: SharePackageItem?
    @State private var recordsNote: String?
    @State private var hasLocalBackup = GoldenNuggetEngine.localBackupCandidate() != nil
    @State private var confirmDeleteBackup = false
    @State private var backupBusy = false
    @State private var backupNote: String?

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                applySection
                backupSection
                historySection
                recordsSection
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
            .onChange(of: wirelessPair.generatedRecordPath) { _, path in
                adoptWirelessRecord(at: path)
            }
            .onAppear {
                history = ApplyHistory.load()
                hasLocalBackup = GoldenNuggetEngine.localBackupCandidate() != nil
            }
            .sheet(item: $sharePackage) { item in
                ActivityShareSheet(url: item.url)
            }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section("连接") {
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
                .confirmationDialog("删除当前配对？", isPresented: $confirmResetPairing, titleVisibility: .visible) {
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

    @ViewBuilder
    private var wirelessPairingRows: some View {
        if #available(iOS 27.0, *) {
            switch wirelessPair.phase {
            case .idle:
                Button { wirelessPair.start() } label: {
                    Label("无线自配对（iOS 27）", systemImage: "wifi")
                }
            case .advertising:
                VStack(alignment: .leading, spacing: 4) {
                    Label("正在等待设备连接…", systemImage: "wifi")
                    if let name = wirelessPair.serviceName {
                        Text("服务：\(name)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let pin = wirelessPair.pin {
                        Text("配对码：\(pin)").font(.caption.weight(.semibold))
                    }
                    Button("取消", role: .destructive) { wirelessPair.cancel() }
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
            GoldenNuggetEngine.shared.log("settings: wireless pairing record adopted (\(PairingRecord.sourceLabel(record)))")
        } catch {
            session.errorText = error.localizedDescription
        }
    }

    // MARK: - Apply

    private var applySection: some View {
        Section("刷入") {
            Toggle("旧格式壁纸包自动转换", isOn: Binding(
                get: { autoConvert },
                set: { autoConvert = $0; PosterBoardPreferences.autoConvertLegacy = $0 }
            ))
            Text("打开时，旧格式包刷入前会转成新格式；每个包第一次勾选时会问你转还是按原样，答案会记住。关掉后，一律按原样刷入、不转换。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Local backup (feedback #21: write back / delete, never pull)

    private var backupSection: some View {
        Section("备份") {
            Text(DriftRestoreGate.isEnabled
                 ? "刷入和清理不再从设备拉取备份。已经存在本地的备份可以在这里写回设备，或者删掉。"
                 : "刷入和清理不再从设备拉取备份。「恢复备份」属于恢复式，暂时停用；已经存在本地的备份可以先删掉。")
                .font(.caption).foregroundStyle(.secondary)
            if !DriftRestoreGate.isEnabled {
                Text(DriftRestoreGate.notice)
                    .font(.caption).foregroundStyle(.orange)
            }
            Button {
                // Feedback #30: writing a backup back IS a restore —
                // while the gate is closed this never starts (the button
                // is disabled too; this is the second lock).
                guard DriftRestoreGate.isEnabled else {
                    backupNote = DriftRestoreGate.notice
                    return
                }
                backupBusy = true
                backupNote = nil
                Task {
                    defer { backupBusy = false }
                    do {
                        try await GoldenNuggetEngine.shared.restoreLocalBackup()
                        backupNote = "已把本地备份写回设备，重启设备后生效。"
                    } catch {
                        session.errorText = error.localizedDescription
                    }
                    hasLocalBackup = GoldenNuggetEngine.localBackupCandidate() != nil
                }
            } label: {
                Label("恢复备份（写回设备）", systemImage: "arrow.down.doc")
            }
            .disabled(!hasLocalBackup || backupBusy || !DriftRestoreGate.isEnabled)
            Button(role: .destructive) {
                confirmDeleteBackup = true
            } label: {
                Label("删除本地备份", systemImage: "trash")
            }
            .disabled(!hasLocalBackup || backupBusy)
            .confirmationDialog("删除本地备份？", isPresented: $confirmDeleteBackup, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    do {
                        try GoldenNuggetEngine.shared.deleteLocalBackup()
                        backupNote = "本地备份已删除。"
                    } catch {
                        session.errorText = error.localizedDescription
                    }
                    hasLocalBackup = GoldenNuggetEngine.localBackupCandidate() != nil
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删掉的是 App 里保存的这份备份文件夹，设备上的内容不受影响。删了就不能再用它恢复了。")
            }
            if backupBusy {
                Text("正在处理…").font(.caption).foregroundStyle(.secondary)
            } else if let backupNote {
                Text(backupNote).font(.caption).foregroundStyle(.secondary)
            } else if !hasLocalBackup {
                Text("本地目前没有已保存的备份。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // Feedback #24: the history used to expand all 20 records inline and
    // stretch the whole settings page. It lives in a fixed-height box now
    // (about three and a half rows) and scrolls inside itself.
    private var historySection: some View {
        Section("刷入记录") {
            if history.isEmpty {
                Text("暂无记录").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(history.suffix(20).reversed().enumerated()), id: \.offset) { _, record in
                            HStack(spacing: 8) {
                                Image(systemName: record.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(record.success ? .green : .red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(record.mode) · \(record.ios.isEmpty ? "未知系统" : "iOS \(record.ios)")")
                                        .font(.subheadline)
                                    Text(record.timestamp).font(.caption).foregroundStyle(.secondary)
                                    if !record.success && !record.error.isEmpty {
                                        Text(record.error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 174)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        }
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
            if let recordsNote {
                Text(recordsNote)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("出问题时点这里打包，把整包发出去就行，不用再一个个找文件。")
                .font(.caption).foregroundStyle(.secondary)
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

    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("版本")
                Spacer()
                Text("Drift \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")")
                    .foregroundStyle(.secondary)
            }
            Text("独立应用：借用 GoldenNugget 的原理与壁纸／连接层代码（AGPL-3.0），界面、UI 与主题均为重新设计，只保留刷壁纸功能。")
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
