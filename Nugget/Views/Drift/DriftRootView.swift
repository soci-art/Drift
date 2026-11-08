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
    @State private var inboxNote: String?

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
        .task { session.bootstrap() }
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
