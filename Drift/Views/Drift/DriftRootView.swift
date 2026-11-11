import SwiftUI
import UniformTypeIdentifiers

/// Drift's root: the first-run guide until setup is complete, then the
/// four-tab shell. Also the front door for files sent into the app — a
/// pairing record or a `.tendies` pack arriving through Files' "Open in"
/// or a share sheet lands here (the document types are declared in the
/// app's Info.plist) and is routed to import.
struct DriftRootView: View {
    @StateObject private var session = DriftSession.shared
    @StateObject private var firstRun = FirstRunSettings.shared
    @StateObject private var identityMonitor = DeviceIdentityMonitor.shared
    @ObservedObject private var tunnelMonitor = TunnelMonitor.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var inboxNote: String?
    @State private var launchFlowDone = false
    @State private var permissionPassDone = false
    @State private var showAnnouncement = false

    var body: some View {
        Group {
            if firstRun.isComplete {
                DriftShell()
            } else {
                FirstRunView()
            }
        }
        .environmentObject(session)
        .environmentObject(identityMonitor)
        .task {
            session.bootstrap()
            startLiveDetection()
            runPermissionPass()
            runLaunchFlow()
        }
        .onChange(of: firstRun.isComplete) { _, complete in
            // The guide just finished: the same launch flow runs now —
            // permissions, update check, announcement.
            if complete { runLaunchFlow() }
        }
        .sheet(isPresented: $showAnnouncement, onDismiss: { AppAnnouncement.markSeen() }) {
            AppAnnouncementView { showAnnouncement = false }
                .presentationDetents([.large])
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                startLiveDetection()
                // Coming back to the app: re-read the device rather than
                // trusting the snapshot (it may have rebooted or been
                // swapped under a live tunnel).
                Task { await session.refreshIdentity() }
            } else if phase == .background {
                TunnelMonitor.shared.stop()
                DeviceIdentityMonitor.shared.stop()
                session.stopPairingWatch()
            }
        }
        .onChange(of: tunnelMonitor.status) { _, status in
            // The tunnel arriving after a failed start is the core's cue to
            // retry, instead of the session sitting dead until relaunch.
            if status == .ready {
                session.ensureCoreStarted()
            }
        }
        .onOpenURL { url in handleIncoming(url) }
        .alert("导入", isPresented: Binding(
            get: { inboxNote != nil },
            set: { if !$0 { inboxNote = nil } }
        )) {
            Button("好") { inboxNote = nil }
        } message: {
            Text(inboxNote ?? "")
        }
        .alert("出错了", isPresented: Binding(
            get: { session.errorText != nil },
            set: { if !$0 { session.errorText = nil } }
        )) {
            Button("好") { session.errorText = nil }
        } message: {
            Text(session.errorText ?? "")
        }
        // Collection #150/#151 (Grace, 2026-11-11): while a flash run is
        // going, cover the whole app with a blocking card — nothing can be
        // tapped until the run finishes. Deliberately minimal: spinner,
        // the words, nothing else.
        .overlay {
            if session.flashCover {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("正在刷入")
                            .font(.headline)
                        Text("请勿熄屏或退出 App")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 28)
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .transition(.opacity)
            }
        }
    }

    /// Live detection (Grace, 2026-11-09: tunnel and pairing record alike
    /// must be watched, not sampled once): the tunnel monitor, the identity
    /// poll — whose loop existed from the start with nothing ever calling
    /// `start()` on it — and the session's pairing-record watch. All three
    /// starts are idempotent, so calling this on every foreground is safe.
    private func startLiveDetection() {
        TunnelMonitor.shared.start()
        DeviceIdentityMonitor.shared.start()
        session.startPairingWatch()
    }

    /// The permission pass (#181) runs at first launch whether or
    /// not the guide is finished — #190 (Grace, 2026-11-11): asking
    /// only after the guide meant the pairing step inside the guide
    /// could never post its PIN notification, because notification
    /// permission had not been asked yet. The silent update check
    /// rides along: its real network request is also what asks for
    /// wireless-data permission.
    private func runPermissionPass() {
        guard !permissionPassDone else { return }
        permissionPassDone = true
        Task {
            await AppPermissions.requestUndecidedOnce()
            await AppUpdateChecker.shared.autoCheck()
        }
    }

    /// The announcement half of the launch flow (#178): only inside
    /// the shell — after the guide for new installs, on the first
    /// launch after updating for everyone else.
    private func runLaunchFlow() {
        guard firstRun.isComplete, !launchFlowDone else { return }
        launchFlowDone = true
        if AppAnnouncement.shouldShow {
            showAnnouncement = true
        }
    }

    private func handleIncoming(_ url: URL) {
        if PairingRecord.hasKnownExtension(url.pathExtension) {
            do {
                try session.importPairing(from: url)
                inboxNote = "配对文件已导入，正在连接设备。"
            } catch {
                session.errorText = error.localizedDescription
            }
            return
        }
        if url.pathExtension.lowercased() == "tendies" {
            do {
                let tendie = try PosterBoardImports.import(from: url)
                inboxNote = "壁纸包「\(tendie.url.lastPathComponent)」已导入（\(tendie.descriptorCount) 张）。到「壁纸」页勾选后刷入。"
            } catch {
                session.errorText = error.localizedDescription
            }
            return
        }
        session.errorText = "不认识这个文件：\(url.lastPathComponent)。Drift 只接收配对文件和 .tendies 壁纸包。"
    }
}
