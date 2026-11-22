import Foundation

/// The restore route's own premises on the Alpha research line.
///
/// Two gates stand in front of any restore run, on top of the channel
/// gate (`DriftRestoreGate`, open only on Alpha builds):
/// * The user's own switch in Settings → 实验性功能 (`enabledKey`,
///   default off). The judge answers a restore pick with the
///   go-turn-it-on reminder while this is off, exactly like the kernel
///   channel's switch (`KernelDirectPremise`).
/// * The segment check, which lives in the session premises and again
///   in `DriftRestoreService`: this line's first segment is iOS 27,
///   judged by version AND build number — a build that cannot be read
///   stops the run rather than guessing.
///
/// The switch is only ever shown as a real switch on Alpha builds; on
/// the release and nightly lines the Settings row stays the sealed
/// placeholder, and this value is never consulted there because the
/// channel gate is closed first.
enum RestoreFlashPremise {
    /// UserDefaults key of the 实验性功能 switch for this method.
    static let enabledKey = "DriftRestoreFlashEnabled"

    /// Whether the user has turned the method on in Settings.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
}
