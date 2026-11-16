import Foundation

/// The kernel direct channel's premises (collections #319/#329,
/// Grace 2026-11-13/14): a fifth flash method for iOS 17 / 18 that
/// needs no pairing, no tunnel and no App Group. Like the local
/// premise, it judges the app's own device only.
///
/// Two gates, both deliberate:
/// * The user's own switch in Settings → 实验性功能 (`enabledKey`,
///   default off). The method does not exist anywhere in the UI
///   until the user turns it on.
/// * The version band plus the chip-offset table. The band is
///   iOS 17.0–17.7.x and 18.0–18.7.1; 18.7.2 and later sit outside
///   even though the table would reach them (the upstream gate
///   closes there). A model outside the offset table is not
///   covered — the upstream code silently fell back to its oldest
///   values in that case, and Drift's guard exists to refuse
///   instead (RESEARCH-17-18-KERNEL-OFFSETS.md).
///
/// Phase note: the channel itself lands separately. Until it does,
/// the judge blocks kernel picks with an honest "being wired up"
/// reason, so nothing in this file can make a run start.
enum KernelDirectPremise {
    /// UserDefaults key of the 实验性功能 switch for this method.
    static let enabledKey = "DriftKernelDirectEnabled"

    /// Formal-line suspension (#341, Grace, 2026-11-16): on the
    /// formal line the kernel channel is closed for now — the build
    /// it carries predates the fix for the iOS 17.0.3 whole-device
    /// restart, and the fixes land on the nightly line first. A
    /// device that would otherwise be ready reads as not ready,
    /// with the closure itself as the reason, so every surface
    /// (Home row, judge, flash entry) refuses in the same words.
    /// This constant exists only in the formal tree; the nightly
    /// tree does not carry it.
    static let channelSuspended = true

    /// Whether the user has turned the method on in Settings.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// The outcome of the band + table check for one device.
    struct Evaluation {
        let inBand: Bool
        let chipCovered: Bool
        /// The system is one of the kernel generations (iOS 17 / 18)
        /// but past the top of the band — iOS 18.7.2 and later. The
        /// reason then names the top of the band instead of the
        /// generations (Grace, 2026-11-16: the coarse 「只支持
        /// iOS 17 / 18」 told an 18.7.7 user nothing about where
        /// they stand).
        var pastBandTop: Bool = false
        /// The formal line's closure (#341): set when this device
        /// would be ready but the channel is suspended — see
        /// `channelSuspended`.
        var suspended: Bool = false
        /// Both gates passed and the channel is not suspended: the
        /// method may be offered as usable.
        var ready: Bool { inBand && chipCovered && !suspended }
        /// Why not, in one user-facing line (empty when ready).
        var reason: String {
            if suspended { return "内核直刷暂时关闭" }
            if !inBand { return pastBandTop ? "只支持到 iOS 18.7.1" : "只支持 iOS 17 / 18" }
            if !chipCovered { return "这台机型不在支持表里" }
            return ""
        }
    }

    static func evaluate(version: String) -> Evaluation {
        let band = isInBand(version: version)
        let covered = isChipCovered(model: modelIdentifier)
        let major = Int(version.split(separator: ".").first ?? "") ?? 0
        return Evaluation(inBand: band,
                          chipCovered: covered,
                          pastBandTop: !band && (major == 17 || major == 18),
                          suspended: channelSuspended && band && covered)
    }

    /// iOS 17.0–17.7.x and 18.0–18.7.1.
    static func isInBand(version: String) -> Bool {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        guard let major = parts.first else { return false }
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        switch major {
        case 17: return minor <= 7
        case 18: return minor < 7 || (minor == 7 && patch <= 1)
        default: return false
        }
    }

    /// Every iPhone that can run iOS 17 / 18 is in the offset
    /// table (XS through the 16 series, i.e. iPhone11,x–iPhone17,x);
    /// anything else — including iPads, which the table does not
    /// cover — is refused rather than approximated.
    static func isChipCovered(model: String) -> Bool {
        guard model.hasPrefix("iPhone") else { return false }
        let head = model.dropFirst("iPhone".count).split(separator: ",").first
        guard let major = head.flatMap({ Int($0) }) else { return false }
        return (11...17).contains(major)
    }

    /// The hardware model identifier (e.g. iPhone15,3).
    static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
