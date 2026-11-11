import Foundation
import Minimuxer
import Network
import UserNotifications

/// Collection #181 (Grace, 2026-11-11): on entering the app, ask for
/// everything Drift needs in ONE pass, in a fixed order — notifications,
/// then local network, then wireless data (which the launch update
/// check triggers by making a real request). Only permissions the
/// system still counts as undecided ever produce a prompt; once a
/// permission has been decided either way, this pass stays silent
/// forever — a refusal is respected, never nagged from the home
/// screen. Feature pages carry the "turn it back on in Settings"
/// guidance for refused permissions instead.
enum AppPermissions {
    private static let localNetworkPrimedKey = "DriftLocalNetworkPrimed"

    static func requestUndecidedOnce() async {
        // 1. Notifications — a real system prompt only when undecided.
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }

        // 2. Local network — no ask-API exists; the prompt is triggered
        // by actually browsing once. Undecided-ness cannot be queried
        // either, so prime exactly once per install: after that the
        // permission is decided one way or the other and browsing
        // again would prompt nothing anyway.
        if !UserDefaults.standard.bool(forKey: localNetworkPrimedKey) {
            UserDefaults.standard.set(true, forKey: localNetworkPrimedKey)
            await primeLocalNetwork()
        }

        // 3. Wireless data — no API at all; the launch update check
        // that the caller runs right after this pass makes the real
        // network request that triggers the system's prompt when the
        // user has never been asked.
    }

    /// A brief Bonjour browse for the pairing service type: long enough
    /// for the system to register the local-network use and ask (when
    /// undecided), short enough to never hold up the launch flow.
    private static func primeLocalNetwork() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // The vendored constant carries a trailing dot (NetService
            // spelling); NWBrowser wants the bare type.
            let rawType = MinimuxerConstants.remotePairingPairableHostServiceType
            let type = rawType.hasSuffix(".") ? String(rawType.dropLast()) : rawType
            let browser = NWBrowser(
                for: .bonjour(type: type, domain: nil),
                using: NWParameters())
            var resumed = false
            let resume = {
                guard !resumed else { return }
                resumed = true
                browser.cancel()
                continuation.resume()
            }
            browser.stateUpdateHandler = { _ in resume() }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { resume() }
        }
    }
}
