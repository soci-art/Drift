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
            // The deferred half of launch (#227): native installs and
            // the tunnel verdict run here, after the first frame —
            // see DriftLaunchTasks. Before bootstrap(), so vendor
            // logging is on when the tunnel core starts.
            DriftLaunchTasks.runAfterFirstFrame()
            // Item 3: spend the cold-location bill now, while the user is
            // reading the guide or importing packs. The method itself is a
            // no-op when the in-process route is unavailable or a container
            // is already cached.
            PosterBoardLocal.startPrewarmIfNeeded()
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
            Button("知道了") { session.errorText = nil }
        } message: {
            Text(session.errorText ?? "")
        }
        .alert(session.noticeTitle, isPresented: Binding(
            get: { session.noticeText != nil },
            set: { if !$0 { session.noticeText = nil } }
        )) {
            Button("知道了") { session.noticeText = nil }
        } message: {
            Text(session.noticeText ?? "")
        }
        // Collection #150/#151 (Grace, 2026-11-11): while a flash run is
        // going, cover the whole app with a blocking card — nothing can be
        // tapped until the run finishes. The 2026-11-12 round adds the
        // same cover for restarting PosterBoard, the post-delete respring
        // and pack repair (#201/#210/#212), and a progress bar under the
        // words — phase-driven, with no text under the bar (#202).
        .overlay {
            if session.flashCover || session.cover != nil {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(session.flashCover ? "正在刷入" : (session.cover?.title ?? ""))
                            .font(.headline)
                        Text("请勿熄屏或退出 App")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let stage = session.flashStage {
                            Text(stage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let progress = session.coverProgress {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .frame(width: 220)
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 28)
                    .background {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(DriftTheme.legacyUI
                                  ? AnyShapeStyle(Color(.secondarySystemBackground))
                                  : AnyShapeStyle(.regularMaterial))
                    }
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
        guard AppAnnouncement.shouldShow else {
            // #264: the cached notes match what the user has seen, but
            // the release notes may have been EDITED since — the seen
            // key is content-based now, so check quietly and present
            // when the fetched body is a different announcement.
            Task {
                guard await AppAnnouncement.fetchNotes() != nil,
                      AppAnnouncement.shouldShow else { return }
                showAnnouncement = true
            }
            return
        }
        // Collection #222: the announcement shows the release notes,
        // which live on GitHub — present only once there is something
        // to show (the cache, or a fetch that just landed). With
        // neither, this launch presents nothing and the next one
        // retries; `markSeen` stays sheet-driven, so nothing is lost.
        if AppAnnouncement.cachedNotes() != nil {
            showAnnouncement = true
        } else {
            Task {
                if await AppAnnouncement.fetchNotes() != nil {
                    showAnnouncement = true
                }
            }
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
        if url.pathExtension.lowercased() == "tendies" || url.pathExtension.lowercased() == "zip" {
            // #269: the import pipeline normalises the name, unpacks a
            // bag zip and auto-repairs — it can take a moment, so it
            // runs off the main actor and reports when it lands.
            Task {
                do {
                    let packs = try await Task.detached {
                        try PosterBoardImports.importPicked(from: url)
                    }.value
                    if let first = packs.first {
                        inboxNote = packs.count > 1
                            ? "已导入 \(packs.count) 个壁纸包。到「壁纸」页点「壁纸包」勾选后刷入。"
                            : "壁纸包「\(first.url.lastPathComponent)」已导入（\(first.descriptorCount) 张）。到「壁纸」页点「壁纸包」勾选后刷入。"
                    }
                    let problems = packs.filter {
                        !PackRepair.isRepaired($0) && !PackDeepRepair.isDeepRepaired($0)
                            && !PackRepair.blockingIssues(of: $0).isEmpty
                    }
                    if !problems.isEmpty {
                        session.noticeTitle = "有壁纸包需要修一下"
                        session.noticeText = problems.map { "「\($0.name)」" }.joined(separator: "、")
                            + "的结构有点问题，导入时自动修了一次没修好，现在刷可能会找不到壁纸。"
                    }
                } catch {
                    session.errorText = error.localizedDescription
                }
            }
            return
        }
        session.errorText = "不认识这个文件：\(url.lastPathComponent)。Drift 只接收配对文件、.tendies 壁纸包和装着壁纸包的 zip。"
    }
}
