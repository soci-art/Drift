import Foundation

/// The kernel direct channel's compatibility premise (Grace, 2026-11-20):
/// the device must be inside the supported iOS version band and present
/// in the chip-offset table. There is no user switch or suspension gate.
/// The method needs no pairing, tunnel or App Group, and judges the
/// app's own device only.
enum KernelDirectPremise {
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
        /// Both gates passed: the method may be offered as usable.
        var ready: Bool { inBand && chipCovered }
        /// Why not, in one user-facing line (empty when ready).
        var reason: String {
            if !inBand { return pastBandTop ? "只支持到 iOS 18.7.1" : "只支持 iOS 17 / 18" }
            if !chipCovered { return "这台机型不在支持表里" }
            return ""
        }
    }

    static func evaluate(version: String) -> Evaluation {
        let band = isInBand(version: version)
        let major = Int(version.split(separator: ".").first ?? "") ?? 0
        return Evaluation(inBand: band,
                          chipCovered: isChipCovered(model: modelIdentifier),
                          pastBandTop: !band && (major == 17 || major == 18))
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
