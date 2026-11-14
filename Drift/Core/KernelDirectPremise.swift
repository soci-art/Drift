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

    /// Whether the user has turned the method on in Settings.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// The outcome of the band + table check for one device.
    struct Evaluation {
        let inBand: Bool
        let chipCovered: Bool
        /// Both gates passed: the method may be offered as usable.
        var ready: Bool { inBand && chipCovered }
        /// Why not, in one user-facing line (empty when ready).
        var reason: String {
            if !inBand { return "只支持 iOS 17 / 18" }
            if !chipCovered { return "这台机型不在支持表里" }
            return ""
        }
    }

    static func evaluate(version: String) -> Evaluation {
        Evaluation(inBand: isInBand(version: version),
                   chipCovered: isChipCovered(model: modelIdentifier))
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
