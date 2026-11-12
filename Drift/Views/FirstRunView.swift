import SwiftUI
import UIKit

/// The one-time setup guide: put a loopback VPN tunnel up, put a pairing record
/// in place, then let the user in.
///
/// A four-slide `TabView` (art in `FirstRunArt.swift`): Welcome with live step
/// cards, Tunnel with the values for LocalDevVPN, Pairing — the desktop app's
/// Mobile Helper first, then import / iOS 27 self-pairing as fallbacks — and
/// Finish. Order follows the dependency chain: the app reaches the device
/// through the tunnel, so no tunnel → nothing for a pairing record to connect
/// over → no device for minimuxer.
///
/// Both checks are ones the app can actually make: the VPN step is judged by
/// the interface and peer probe `Tunnel` performs, the pairing step by a
/// record at `AppPaths.pairingFile` passing the same `PairingRecord` rule the
/// restore path applies. There is deliberately no "install" button — this
/// target cannot install (`installation_proxy` is not bridged in), so the
/// tunnel slide says what to install and what to type into it instead.
struct FirstRunView: View {
    /// Non-nil when the guide is pushed from Settings rather than the gate:
    /// only then can the user leave without finishing setup.
    var onClose: (() -> Void)?

    @ObservedObject private var firstRun = FirstRunSettings.shared
    /// Shared: the advertisement outlives this page (Settings → Developer Mode).
    @ObservedObject private var wirelessPair = WirelessPairing.shared
    /// The session, for its pairing state: the guide's own pairing check is a
    /// one-off disk read, so a record the session adopts live (its disk watch
    /// noticed the wireless flow's file, say) is mirrored in below.
    @EnvironmentObject private var session: DriftSession
    @Environment(\.scenePhase) private var scenePhase

    /// The tunnel step. A live probe rather than a stored answer — see `probe()`.
    @State private var tunnel: TunnelStep = .unchecked
    /// Whether a usable pairing record is in place.
    @State private var pairingReady = PairingRecord.onDisk() != nil
    @State private var showPairingImporter = false
    @State private var errorText: String?
    /// The slide number, swiped by the user or animated to by a step-card tap.
    @State private var page = 0
    /// The last slide's index; `Finish` and `Skip` live below it.
    private let lastPage = 3

    /// The tunnel step, as the app can actually observe it. `.peerUnreachable`
    /// is not a failure: the interface is up, the peer service is just not
    /// answering yet — `Tunnel.waitForTunnel` waits on exactly this.
    private enum TunnelStep: Equatable {
        /// Not probed yet, or the last probe was interrupted.
        case unchecked
        /// 没有接口带 Tunnel.ifaceIP 这个地址——隧道 App 可能连错了网络，或者隧道 IP 还留着默认值。
        case interfaceMissing
        /// Interface up, peer port not answering yet.
        case peerUnreachable
        /// The tunnel is carrying lockdown traffic — `startMinimuxer` will go on.
        case ready

        /// The long verdict, carrying the values it judged — for the log.
        var text: String {
            switch self {
            case .unchecked: return "尚未检查"
            case .interfaceMissing: return "没有隧道——\(Tunnel.ifaceIP) 不在任何接口上"
            case .peerUnreachable: return "隧道接口已启动，正在等待 \(Tunnel.peerIP):\(Tunnel.servicePort)"
            case .ready: return "隧道已通——\(Tunnel.peerIP):\(Tunnel.servicePort) 已回应"
            }
        }

        /// The short verdict a status pill can carry.
        var shortText: String {
            switch self {
            case .unchecked: return "尚未检查"
            case .interfaceMissing: return "隧道未连接"
            case .peerUnreachable: return "正在等待隧道的另一端"
            case .ready: return "隧道已通"
            }
        }

        var isReady: Bool { self == .ready }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcomeSlide.tag(0)
                tunnelSlide.tag(1)
                pairingSlide.tag(2)
                finishSlide.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            footer
        }
        .background(FirstRunBackground())
        .navigationTitle("设置向导")
        .navigationBarTitleDisplayMode(.inline)
        // No menu button: there is no sidebar behind this page in either state.
        // As the gate this is the root; as a Settings page it is pushed onto a
        // stack, where the bar already carries "back".
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { onClose() }
                }
            }
        }
        .task {
            pairingReady = PairingRecord.onDisk() != nil
            await probe()
        }
        // Live pairing detection, mirroring the session's disk watch: a
        // record adopted anywhere ticks this step without a re-read here.
        .onChange(of: session.paired) { _, paired in
            if paired { pairingReady = true }
        }
        // Coming back from Settings is when a tunnel that was just switched on
        // becomes visible, and nothing in this process is told when an interface
        // appears — so the re-check is on foreground, not only on appear.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await probe()
        }
        // Re-probe until it is ready: the user's half of this step happens in
        // another app, so this screen would otherwise sit on "no tunnel" for as
        // long as they took. The `id` stops the loop the moment it succeeds, so a
        // working setup costs no more probes.
        .task(id: tunnel.isReady) {
            while !tunnel.isReady, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await probe()
            }
        }
        // UIKit picker, not SwiftUI `fileImporter` — see
        // `DocumentPicker` for the tap-swallowing failure that moved it.
        .sheet(isPresented: $showPairingImporter) {
            DocumentPicker(contentTypes: PairingRecord.types) { urls in
                showPairingImporter = false
                if let url = urls.first {
                    importRecord(from: url)
                }
            } onCancel: {
                showPairingImporter = false
            }
        }
        // A pairing file arriving as a link (AirDrop, Files "Open in"), which is
        // how it usually reaches a phone.
        .onOpenURL { url in
            guard PairingRecord.hasKnownExtension(url.pathExtension) else { return }
            importRecord(from: url)
        }
        // The wireless pairing wrote a record of its own; adopt it through the
        // same contract an import goes through.
        .onChange(of: wirelessPair.generatedRecordPath) { _, path in
            adoptGeneratedRecord(at: path)
        }
        .alert("设置向导", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好") {}
        } message: {
            Text(errorText ?? "?")
        }
    }

    // MARK: - Footer

    /// The chrome under the slides: back, the dots, the forward action — and
    /// on the last slide the two ways out. `Finish` lives here so it can never
    /// be scrolled away.
    private var footer: some View {
        VStack(spacing: 12) {
            HStack {
                if page == 0 {
                    // The first slide's leading edge carries the exit instead of
                    // a back button there is nothing to go back to.
                    Button("先跳过设置") { skip() }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        withAnimation(.snappy) { page -= 1 }
                    } label: {
                        Image(systemName: "chevron.left")
                            .flipsForRightToLeftLayoutDirection(true)
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.quaternary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("上一页")
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0...lastPage, id: \.self) { index in pageDot(index) }
                }
                Spacer()
                if page < lastPage {
                    Button {
                        withAnimation(.snappy) { page += 1 }
                    } label: {
                        HStack(spacing: 6) {
                            Text(page == 0 ? "开始" : "继续")
                            Image(systemName: "chevron.right")
                                .flipsForRightToLeftLayoutDirection(true)
                        }
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    // Width-balances the back button so the dots stay centred on
                    // the last slide too.
                    Color.clear
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                }
            }
            if page == lastPage {
                NativePrimaryButton(title: "完成设置", systemImage: "checkmark", disabled: !canFinish) {
                    finish()
                }
                Button("先跳过设置") { skip() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                NativeNote("跳过不是死胡同：这个向导之后在设置里还能打开。")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// One of the four dots; the live one stretches into a capsule.
    private func pageDot(_ index: Int) -> some View {
        Capsule()
            .fill(index == page ? Color.accentColor : Color(.tertiaryLabel))
            .frame(width: index == page ? 20 : 7, height: 7)
            .animation(.spring(duration: 0.25), value: page)
            .accessibilityLabel("第 \(index + 1) 页，共 \(lastPage + 1) 页")
            .accessibilityHidden(index != page)
    }

    // MARK: - Slides

    /// Slide 0: what the app does, plus the two steps as live cards that jump
    /// to their slide — the same probes as below, one name per state.
    private var welcomeSlide: some View {
        SlideLayout(
            art: { FirstRunWelcomeArt(active: page == 0) },
            title: "Drift",
            subtitle: LocalizedStringKey(localReady
                ? "给这台 iPhone 刷入交互壁纸。本机直刷已可用，可以直接完成设置。"
                : "给这台 iPhone 刷入交互壁纸。本机直刷不可用，先走完隧道与配对两个步骤。"))
        {
            VStack(alignment: .leading, spacing: 12) {
                if localReady {
                    NativeNote("本机直刷可用（iOS \(WorseQueryEscape.processVersion)，签名授予了可用的 App Group）：直接点「完成设置」就能刷，下面的隧道与配对只是要走两条隧道通道时才需要。")
                }
                stepCard(number: 1, title: "隧道", done: tunnel.isReady,
                         working: tunnel == .peerUnreachable, status: tunnel.shortText,
                         destination: 1)
                stepCard(number: 2, title: "配对", done: pairingReady,
                         working: wirelessPair.isRunning,
                         status: pairingReady ? "配对记录已就位" : "尚无配对记录",
                         destination: 2)
                NativeNote(localReady
                    ? "第 1、2 步可选：只有想走两条隧道通道时才需要；本机直刷不用配对，也不用隧道。"
                    : "第 2 步可以在电脑上用 iLoader 配对——生成配对文件后传到这台 iPhone 上导入。")
                NativeNote("隧道状态实时检测：打开 App 之后再连上隧道，这一页会自动变绿，不用重开 App。")
            }
        }
    }

    /// Slide 1: the tunnel. `Tunnel.requirements` is the same string the home
    /// page's diagnostics print, so the two cannot disagree.
    private var tunnelSlide: some View {
        SlideLayout(
            art: { FirstRunTunnelArt(ready: tunnel.isReady, active: page == 1) },
            title: "1 · 隧道",
            subtitle: "装好 LocalDevVPN（或同类隧道 App），填入下面的值并保持开启——两条隧道通道（免注销直刷 / 注销直刷）需要它；本机直刷不需要。")
        {
            VStack(alignment: .leading, spacing: 12) {
                statusPill(done: tunnel.isReady, working: tunnel == .peerUnreachable,
                           text: tunnel.shortText)
                Text(Tunnel.requirements)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = Tunnel.requirements
                    } label: {
                        Text("把这些值抄进隧道 App")
                    }
                    .driftGlassButton()
                    Button {
                        Task { await probe() }
                    } label: {
                        Label("再检测一次", systemImage: "arrow.clockwise")
                    }
                    .driftGlassButton()
                }
                if tunnel == .interfaceMissing {
                    NativeNote("没有接口带 \(Tunnel.ifaceIP) 这个地址——隧道 App 可能连错了网络，或者隧道 IP 还留着默认值。")
                }
                if Tunnel.isCustomised {
                    NativeSafetyNote("当前用的是自定义隧道地址——必须和 LocalDevVPN 里填的一致。")
                }
            }
        }
    }

    /// Slide 2: a pairing record — the desktop app's Mobile Helper first, then
    /// the two fallbacks (import; iOS 27 self-pairing).
    private var pairingSlide: some View {
        SlideLayout(
            art: { FirstRunPairArt(linked: pairingReady, active: page == 2) },
            title: "2 · 配对")
        {
            VStack(alignment: .leading, spacing: 12) {
                statusPill(done: pairingReady, working: wirelessPair.isRunning,
                           text: pairingReady ? "配对记录已就位" : "尚无配对记录")
                if wirelessPair.isRunning {
                    wirelessCard
                } else {
                    helperCard
                    actionCard(icon: "doc.badge.plus", title: "导入配对文件") {
                        showPairingImporter = true
                    }
                    actionCard(icon: "wifi", title: "不用电脑配对") {
                        wirelessPair.start()
                    }
                    NativeNote("没有电脑工具？也可以在电脑上配对（idevicepair、Sideloadly——手机弹窗时点「信任」），把 .plist 配对文件发到这台 iPhone，在上面导入。")
                }
            }
        }
    }

    /// The desktop app's route, as an informative card — the work happens in
    /// another app on another machine, so it must not read as a button. Its
    /// file lands exactly where `PairingRecord.adoptFromDisk` reads it, and
    /// the slide's check turns green on its own after that.
    private var helperCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("用 iLoader 在电脑上配对")
                    .font(.headline)
                Text("用 USB 连上这台 iPhone 并点「信任」，在电脑上打开 iLoader 完成配对，导出 .plist 配对文件，传到这台 iPhone 后在上方导入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                NativeNote("导入后这一页会自己打勾，不用重开 App。")
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Slide 3: both verdicts and the buttons out; the confetti follows
    /// `canFinish`, never promising a finish the button refuses.
    private var finishSlide: some View {
        SlideLayout(
            art: { FirstRunFinishArt(ready: canFinish, active: page == lastPage) },
            title: "都齐了",
            subtitle: "点完成会连上设备并打开主页。")
        {
            VStack(alignment: .leading, spacing: 12) {
                if localReady {
                    NativeNote("本机直刷可用：现在就能完成设置并刷壁纸，不需要配对或隧道。下面的两步可以以后在设置里补。")
                }
                stepCard(number: 1, title: "隧道（可选）", done: tunnel.isReady,
                         working: tunnel == .peerUnreachable, status: tunnel.shortText,
                         destination: 1)
                stepCard(number: 2, title: "配对（可选）", done: pairingReady,
                         working: wirelessPair.isRunning,
                         status: pairingReady ? "配对记录已就位" : "尚无配对记录",
                         destination: 2)
                NativeNote("点「完成设置」后打开壁纸页。")
                if !canFinish {
                    NativeNote("本机直刷不可用，所以完成按钮要等隧道和配对都就绪。")
                }
            }
        }
    }

    // MARK: - Pieces

    /// A step card (welcome/finish slides): number, name, short verdict, and a
    /// tap that jumps to the step's slide.
    private func stepCard(number: Int, title: LocalizedStringKey, done: Bool, working: Bool,
                          status: String, destination: Int) -> some View {
        Button {
            withAnimation(.snappy) { page = destination }
        } label: {
            HStack(spacing: 12) {
                Text(verbatim: "\(number)")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(done ? Color.green : Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(.quaternary, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(done ? Color.green : working ? Color.orange : Color.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .flipsForRightToLeftLayoutDirection(true)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开这一步的页面")
    }

    /// A pairing-slide action as a full-width card (two halves truncate at
    /// large Dynamic Type sizes).
    private func actionCard(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .flipsForRightToLeftLayoutDirection(true)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// A step's verdict as a pill: done (green), working (orange), not yet.
    private func statusPill(done: Bool, working: Bool = false, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : working ? "ellipsis.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? Color.green : working ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quinary, in: Capsule())
    }

    /// The in-flight wireless pairing: host status, PIN if asked, cancel.
    private var wirelessCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                if wirelessPair.serviceName != nil {
                    // #189 (Grace, 2026-11-11): the service UUID is not
                    // user information — the status is just this.
                    Text("正在等待配对…")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("正在启动配对服务…")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let pin = wirelessPair.pin {
                Text("配对码：\(pin)")
                    .font(.title3.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                NativeNote("在 设置 → 隐私与安全性 → 开发者模式 →「与 \(WirelessPairing.displayName) 配对」里确认。")
            } else {
                NativeNote("设置 → 隐私与安全性 → 开发者模式 →「与 \(WirelessPairing.displayName) 配对」")
            }
            Button(role: .destructive) {
                wirelessPair.cancel()
            } label: {
                Label("Cancel pairing", systemImage: "xmark.circle")
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The in-process route needs neither the tunnel nor a pairing record, so
    /// when it is usable the guide must not put its two optional steps in front
    /// of Finish. Only a device that cannot use it walks the full flow.
    private var localReady: Bool {
        WorseQueryEscape.isAvailable(deviceVersion: WorseQueryEscape.processVersion,
                                       buildVersion: WorseQueryEscape.processBuildVersion)
    }

    private var canFinish: Bool { localReady || (tunnel.isReady && pairingReady) }

    // MARK: - Actions

    /// Leave the guide with both steps satisfied.
    ///
    /// Drift has no media feature: unlike the app this guide came from,
    /// finishing setup here deliberately does NOT start a photo/video copy.
    private func finish() {
        firstRun.complete(reason: localReady
            ? "本机直刷已就绪；隧道和配对可选"
            : "隧道和配对记录都已就绪")
        onClose?()
    }

    /// Leave the guide without the setup; the gate's log tells the two ways out
    /// apart, and everything here stays reachable from Settings.
    private func skip() {
        firstRun.complete(reason: "skipped by the user")
        onClose?()
    }

    /// Fill the tunnel step's state, off the main actor.
    ///
    /// `Task.detached` on purpose: `probePeer` waits for the peer's lockdown port,
    /// and this runs from a view body-adjacent task that the user is scrolling —
    /// the same two-second stall the home page's `refreshTunnelStatus()` is written
    /// to avoid, in a place with nowhere to hide it.
    private func probe() async {
        let (interfaceUp, peerReachable) = await Task.detached(priority: .utility) {
            (Tunnel.isInterfaceUp(), Tunnel.probePeer(timeout: 1.0))
        }.value
        let next: TunnelStep = interfaceUp ? (peerReachable ? .ready : .peerUnreachable) : .interfaceMissing
        if next != tunnel {
            DriftEngine.shared.log("setup guide: tunnel — \(next.text)")
        }
        tunnel = next
    }

    /// Import a record and record it the way the home page's import does.
    ///
    /// The home page adopts it on its first `.task`, reading the canonical file
    /// first — so this deliberately does **not** start anything itself: two
    /// starters would be the duplicate-start race `startMinimuxer`'s lock was added
    /// to prevent.
    private func importRecord(from url: URL) {
        do {
            let record = try PairingRecord.accept(contentsOf: url)
            PairingRecord.persist(record)
            pairingReady = true
            DriftEngine.shared.log("setup guide: pairing file imported "
                + "(\(PairingRecord.sourceLabel(record)), \(record.count) bytes)")
        } catch {
            errorText = error.localizedDescription
            DriftEngine.shared.log("setup guide: pairing file import failed "
                + "(\(url.lastPathComponent)): \(error.localizedDescription)")
        }
    }

    /// Take the record the wireless pairing produced.
    ///
    /// Routed through `PairingRecord` either way — the library's own file is the
    /// canonical one, so it is adopted in place rather than rewritten, and a
    /// library that wrote somewhere else is imported like any other file. Both
    /// paths apply `usable(_:)`, so a record produced inside the app gets the same
    /// rejection a picked file would.
    private func adoptGeneratedRecord(at path: String?) {
        guard let path else { return }
        defer { wirelessPair.reset() }
        do {
            let record = path == AppPaths.pairingFile.path
                ? try PairingRecord.adoptFromDisk()
                : try PairingRecord.accept(contentsOf: URL(fileURLWithPath: path))
            if path != AppPaths.pairingFile.path { PairingRecord.persist(record) }
            pairingReady = true
            DriftEngine.shared.log("setup guide: wireless pairing record adopted "
                + "(\(PairingRecord.sourceLabel(record)))")
        } catch {
            errorText = error.localizedDescription
            DriftEngine.shared.log("setup guide: wireless pairing record rejected — "
                + "\(error.localizedDescription)")
        }
    }
}

// MARK: - Slide scaffolding

/// One slide's frame: illustration, title, subtitle, then the content — which
/// scrolls when Dynamic Type or a small phone leaves it no room, while the
/// illustration keeps its space and stays the slide's face.
private struct SlideLayout<Art: View, Content: View>: View {
    @ViewBuilder var art: () -> Art
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            art()
                .padding(.top, 16)
            VStack(spacing: 8) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 20)
            ScrollView(.vertical) {
                content()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The slides' backdrop: the system background with one quiet accent wash from
/// the top, behind every slide. Semantic colours only — the wash fades to
/// nothing rather than to a fixed colour, so dark mode needs no second version.
private struct FirstRunBackground: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear],
                           startPoint: .top,
                           endPoint: UnitPoint(x: 0.5, y: 0.6))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
