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
        for channel in TutorialChannel.allCases where channel != .kernel && channel != .restore {
            states[channel] = state(of: channel, judged: judged, identity: identity)
        }
        states[.kernel] = kernelState()
        states[.restore] = restoreState(judged: judged, identity: identity)
        return states
    }

    /// The restore channel's standing, read off the judgement's own
    /// restore answer (the premises already folded the gate, the
    /// tunnel trio and the iOS 27 segment by build number): ready
    /// when it can run now; system-blocked when a read system is
    /// outside the segment; setup otherwise (tunnel, pairing or the
    /// build number still missing).
    private static func restoreState(judged: DriftModeJudgement,
                                     identity: DeviceIdentity) -> TutorialChannelState {
        if judged.restoreAvailable { return .ready }
        if !identity.version.isEmpty,
           !DriftJudge.isRestoreSegment(version: identity.version) {
            return .systemBlocked
        }
        return .needsSetup
    }

    /// The kernel channel has no mode in the judgement; its state
    /// comes directly from the system-band and model-table check.
    private static func kernelState() -> TutorialChannelState {
        let evaluation = KernelDirectPremise.evaluate(
            version: WorseQueryEscape.processVersion)
        return evaluation.ready ? .ready : .systemBlocked
    }

    /// The channel's mode in the judgement; the kernel channel has
    /// none — its state comes from `kernelState()` instead.
    private static func mode(of channel: TutorialChannel) -> PosterBoardApplyMode? {
        switch channel {
        case .noRespring: return .direct
        case .respring: return .airlift
        case .local: return .worseQuery
        case .kernel, .restore: return nil
        }
    }

    private static func state(of channel: TutorialChannel,
                              judged: DriftModeJudgement,
                              identity: DeviceIdentity) -> TutorialChannelState {
        guard let mode = mode(of: channel),
              let option = judged.options.first(where: { $0.mode == mode }) else {
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
            var gateOpen = switch channel {
            case .noRespring:
                PosterBoardDirect.isAvailable(deviceVersion: identity.version,
                                              buildVersion: identity.buildVersion)
            case .respring:
                Airlift.isSupported(deviceVersion: identity.version,
                                    buildVersion: identity.buildVersion)
            case .local, .kernel, .restore:
                true
            }
            // The session layer closes two tunnel bands the channels'
            // own gates pass — the whole 17 band (#314) and 26.0–26.1,
            // which the coverage table keeps local-only (#331). A pill
            // on either band is system-blocked, not merely unsetup.
            if channel == .noRespring || channel == .respring {
                if let below = PosterBoard.compareVersion(identity.version, "18.0"),
                   below < 0 { gateOpen = false }
                if let lo = PosterBoard.compareVersion(identity.version, "26.0"), lo >= 0,
                   let hi = PosterBoard.compareVersion(identity.version, "26.2"), hi < 0 {
                    gateOpen = false
                }
            }
            if !gateOpen { return .systemBlocked }
        }
        return .needsSetup
    }
}
