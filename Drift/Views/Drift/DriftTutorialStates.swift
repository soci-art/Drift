import Foundation

/// The bridge between the live mode judgement and the tutorial's four
/// spoken states (#231). The tutorial views are pure display; this is
/// the one place that reads the judge, the tunnel device identity and
/// the raw version gates to decide what each channel's pill and banner
/// say. Kept apart from the views so they can render unchanged in the
/// simulator preview target with canned states.
enum DriftTutorialStates {
    /// Every channel's standing right now.
    static func current(identity: DeviceIdentity,
                        tunnelReady: Bool) -> [TutorialChannel: TutorialChannelState] {
        let judged = DriftJudge.judge(identity: identity,
                                      selection: PosterBoardSelection(),
                                      pick: .auto, tunnelReady: tunnelReady)
        var states: [TutorialChannel: TutorialChannelState] = [:]
        for channel in TutorialChannel.allCases {
            states[channel] = state(of: channel, judged: judged, identity: identity)
        }
        return states
    }

    private static func mode(of channel: TutorialChannel) -> PosterBoardApplyMode {
        switch channel {
        case .noRespring: return .direct
        case .respring: return .airlift
        case .local: return .worseQuery
        }
    }

    private static func state(of channel: TutorialChannel,
                              judged: DriftModeJudgement,
                              identity: DeviceIdentity) -> TutorialChannelState {
        guard let option = judged.options.first(where: { $0.mode == mode(of: channel) }) else {
            return .systemBlocked
        }
        if option.available { return .ready }
        if channel == .local {
            return option.sealed ? .groupBlocked : .systemBlocked
        }
        // Tunnel channels: the system gate itself is closed only when a
        // real device version was read and the gate rejects it; anything
        // else (no pairing, no tunnel, no identity yet) is setup.
        if !identity.version.isEmpty {
            let gateOpen = switch channel {
            case .noRespring:
                PosterBoardDirect.isAvailable(deviceVersion: identity.version,
                                              buildVersion: identity.buildVersion)
            case .respring:
                Airlift.isSupported(deviceVersion: identity.version,
                                    buildVersion: identity.buildVersion)
            case .local:
                true
            }
            if !gateOpen { return .systemBlocked }
        }
        return .needsSetup
    }
}
