import SwiftUI
import UniformTypeIdentifiers

/// Drift's settings: connection (pairing, tunnel), apply preferences and
/// history, logs/diagnostics, and About. Only what the wallpaper feature
/// needs — the base app's tweak/developer/update settings do not exist here.
struct DriftSettingsView: View {
    @EnvironmentObject private var session: DriftSession
    @ObservedObject private var wirelessPair = WirelessPairing.shared

    @State private var importingPairing = false
    @State private var showGuide = false
    @State private var confirmResetPairing = false
    @State private var history: [ApplyHistory.Record] = ApplyHistory.load()
    @State private var autoConvert = PosterBoardPreferences.autoConvertLegacy
    @State private var diagnosticsReady = FileManager.default.fileExists(atPath: AppPaths.diagnostics.path)

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                tunnelSection
                applySection
                historySection
                recordsSection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            .fileImporter(isPresented: $importingPairing,
                          allowedContentTypes: PairingRecord.types,
                          allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                do { try session.importPairing(from: url) }
                catch { session.errorText = error.localizedDescription }
            }
            .sheet(isPresented: $showGuide) {
                FirstRunView(onClose: { showGuide = false })
            }
            .onChange(of: wirelessPair.generatedRecordPath) { _, path in
                adoptWirelessRecord(at: path)
            }
            .onAppear { history = ApplyHistory.load() }
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
                Text(Tunnel.isInterfaceUp() ? "接口已就绪" : "未检测到隧道")
                    .foregroundStyle(.secondary)
            }
            Button {
                showGuide = true
            } label: {
                Label("重新打开设置向导", systemImage: "wand.and.stars")
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

    // MARK: - Tunnel address

    private var tunnelSection: some View {
        Section {
            DriftTunnelAddressEditor()
        } header: {
            Text("隧道地址")
        } footer: {
            Text("LocalDevVPN 里要填的值和这里保持一致。填错的地址会被标出来并按默认值探测。改完地址后，把 App 关掉重开一次。")
        }
    }

    // MARK: - Apply

    private var applySection: some View {
        Section("刷入") {
            Toggle("旧格式壁纸包自动转换", isOn: Binding(
                get: { autoConvert },
                set: { autoConvert = $0; PosterBoardPreferences.autoConvertLegacy = $0 }
            ))
            Text("关掉后，旧格式的包在导入时会逐个问你转不转。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var historySection: some View {
        Section("刷入记录") {
            if history.isEmpty {
                Text("暂无记录").foregroundStyle(.secondary)
            }
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
            }
        }
    }

    // MARK: - Records

    private var recordsSection: some View {
        Section("记录") {
            NavigationLink {
                DriftLogView()
            } label: {
                Label("运行日志", systemImage: "doc.text")
            }
            Button {
                Task {
                    _ = await GoldenNuggetEngine.shared.diagnostics()
                    diagnosticsReady = true
                }
            } label: {
                Label("生成诊断报告", systemImage: "doc.text.magnifyingglass")
            }
            if diagnosticsReady {
                ShareLink(item: AppPaths.diagnostics) {
                    Label("分享 diagnostics.txt", systemImage: "square.and.arrow.up")
                }
            }
            if FileManager.default.fileExists(atPath: AppPaths.appLog.path) {
                ShareLink(item: AppPaths.appLog) {
                    Label("分享 App 日志", systemImage: "square.and.arrow.up")
                }
            }
            if FileManager.default.fileExists(atPath: AppPaths.rustLog.path) {
                ShareLink(item: AppPaths.rustLog) {
                    Label("分享 minimuxer 日志", systemImage: "square.and.arrow.up")
                }
            }
            Text("出问题时，把这三份一起发出去最好定位：诊断报告是结论，App 日志是过程，minimuxer 日志是设备原话。")
                .font(.caption).foregroundStyle(.secondary)
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
            Text("基于开源项目 GoldenNugget 移植壁纸与连接层代码，只保留刷壁纸功能。沿用 AGPL-3.0 许可证。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The four tunnel address fields, validated on commit: an invalid value is
/// flagged and not stored (the engine then probes with the defaults — the
/// base app's behaviour).
struct DriftTunnelAddressEditor: View {
    @State private var iface = Tunnel.ifaceIP
    @State private var peer = Tunnel.peerIP
    @State private var port = String(Tunnel.servicePort)
    @State private var prefix = String(Tunnel.ifacePrefixLength)
    @State private var invalidFields: Set<String> = []
    @State private var copied = false

    var body: some View {
        Group {
            field("本机隧道 IP", value: $iface, id: "iface") { newValue in
                guard Self.isIPv4(newValue) else { return false }
                UserDefaults.standard.set(newValue, forKey: Tunnel.Key.ifaceIP)
                return true
            }
            field("对端 IP", value: $peer, id: "peer") { newValue in
                guard Self.isIPv4(newValue) else { return false }
                UserDefaults.standard.set(newValue, forKey: Tunnel.Key.peerIP)
                return true
            }
            field("端口", value: $port, id: "port") { newValue in
                guard let number = Int(newValue), (1...65535).contains(number) else { return false }
                UserDefaults.standard.set(number, forKey: Tunnel.Key.port)
                return true
            }
            field("前缀长度", value: $prefix, id: "prefix") { newValue in
                guard let number = Int(newValue), (0...32).contains(number) else { return false }
                UserDefaults.standard.set(number, forKey: Tunnel.Key.prefixLength)
                return true
            }
            HStack {
                Button("恢复默认") {
                    Tunnel.resetToDefaults()
                    iface = Tunnel.ifaceIP; peer = Tunnel.peerIP
                    port = String(Tunnel.servicePort); prefix = String(Tunnel.ifacePrefixLength)
                    invalidFields = []
                }
                Spacer()
                Button {
                    UIPasteboard.general.string =
                        "地址：\(Tunnel.ifaceIP)/\(Tunnel.ifacePrefixLength)\n对端：\(Tunnel.peerIP)\n端口：\(Tunnel.servicePort)"
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制要填进 LocalDevVPN 的值",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
        }
    }

    private func field(_ title: String, value: Binding<String>, id: String,
                       commit: @escaping (String) -> Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, text: value)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.numbersAndPunctuation)
                .frame(maxWidth: 170)
                .foregroundStyle(invalidFields.contains(id) ? .red : .primary)
                .onSubmit {
                    if commit(value.wrappedValue) {
                        invalidFields.remove(id)
                    } else {
                        invalidFields.insert(id)
                    }
                }
            if invalidFields.contains(id) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
        }
    }

    private static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let number = Int(part), String(number) == String(part) || part == "0" || !part.hasPrefix("0") else { return false }
            return (0...255).contains(number)
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
