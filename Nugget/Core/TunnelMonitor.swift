import Foundation
import SwiftUI

/// The loopback tunnel's state, kept current while the app is on screen.
///
/// Every page used to judge the tunnel for itself, once, when it happened to
/// render: Settings drew `Tunnel.isInterfaceUp()` inline in its body, so the
/// row said whatever was true at that instant forever, and the home page had
/// no tunnel state at all. A user who opened LocalDevVPN *after* Drift — the
/// normal order — watched nothing change until some unrelated action forced
/// a redraw (Grace, 2026-11-09: 「本地回环隧道不会实时检测」).
///
/// So the judgement lives here, polled: the interface check is a local
/// `getifaddrs` walk and the peer check one short TCP connect, both cheap
/// and both run off the main actor. Two seconds is the interval because the
/// fact being reported — "the VPN came up" — is one the user is standing
/// there waiting to see acknowledged. `status` is written only on a change,
/// for the reason `DeviceIdentityMonitor` gives: a `@Published` write per
/// tick would redraw every observer for nothing.
@MainActor
final class TunnelMonitor: ObservableObject {
    static let shared = TunnelMonitor()

    enum Status: Equatable {
        /// No interface carries the tunnel IP: the VPN app is not connected.
        case down
        /// The interface is up but the lockdown peer is not answering yet.
        case interfaceUp
        /// Interface up and the peer answered: the tunnel carries traffic.
        case ready
    }

    @Published private(set) var status: Status = .down

    private var loop: Task<Void, Never>?

    static let interval: Duration = .seconds(2)

    private init() {}

    /// Start polling. Idempotent, like the identity monitor's.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: TunnelMonitor.interval)
            }
        }
    }

    /// Stop polling, so a backgrounded app is not probing.
    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func poll() async {
        let next = await Task.detached(priority: .utility) { () -> Status in
            guard Tunnel.isInterfaceUp() else { return .down }
            return Tunnel.probePeer(timeout: 1.0) ? .ready : .interfaceUp
        }.value
        guard next != status else { return }
        status = next
        GoldenNuggetEngine.shared.log("tunnel monitor: \(next.logText)")
    }
}

private extension TunnelMonitor.Status {
    var logText: String {
        switch self {
        case .down: return "tunnel down — \(Tunnel.ifaceIP) not on any interface"
        case .interfaceUp: return "tunnel interface up, waiting for \(Tunnel.peerIP):\(Tunnel.servicePort)"
        case .ready: return "tunnel ready — \(Tunnel.peerIP):\(Tunnel.servicePort) answered"
        }
    }
}
