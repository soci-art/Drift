import Foundation

/// The research-build channel (feedback #31).
///
/// A research build exists for exactly one job: running the pull-silence
/// diagnosis (feedback #14/#21) on the device where the silence was first
/// observed — Grace's main device, iOS 27.2 beta 2, which she will not
/// flash — without touching the distribution posture of feedback #30.
/// The channel is a single Info.plist key, `DriftResearchBuild`, and the
/// isolation argument is deliberately boring:
///
///   * The distribution Info.plist (`layout/Applications/Drift.app/
///     Info.plist`, the file `project.yml` points `INFOPLIST_FILE` at)
///     does NOT contain the key, and nothing in the normal build pipeline
///     adds it — so a distribution build reads `false` here, always.
///   * The key is injected only by `scripts/build-research-ipa.sh`,
///     which builds the ordinary way first and then adds the key to a
///     COPY of the finished app bundle before rezipping it under a
///     different name (`Drift-research-unsigned.ipa`). The repo's own
///     plist is never edited, so a research build cannot leak into a
///     distribution build by a forgotten working-tree change.
///   * Flipping the key on a copy someone already has breaks the code
///     signature, and the app is only ever run after Grace signs it
///     herself — the channel cannot be opened by accident downstream.
///   * Every surface that opens because of this flag also announces
///     itself: a red banner over the shell, a notice in Settings, and
///     the research actions exist only while the flag reads true.
///
/// What the flag opens: ONLY the research entries in Settings (the
/// diagnostic pull) and the banner. What it does NOT open, by explicit
/// decision (feedback #31): `DriftRestoreGate` — a research build is the
/// distribution build plus diagnostics, with the restore route still
/// closed and no write-back path reachable. A gate-open variant belongs
/// to the later spare-device (iOS 27.3) end-to-end stage and will be a
/// separate build, physically isolated from this one. The flag also
/// changes no protocol behaviour — the pull trace works identically
/// either way.
enum DriftResearchBuild {
    /// True only in a build produced by `scripts/build-research-ipa.sh`.
    static var isActive: Bool {
        Bundle.main.object(forInfoDictionaryKey: "DriftResearchBuild") as? Bool ?? false
    }

    /// The banner every research surface carries.
    static let bannerText = "研究构建 · 仅限诊断"

    /// The longer warning shown next to the research actions.
    static let notice = "这是研究构建：只多了「诊断拉取」入口，恢复式仍处于停用状态，"
        + "没有任何写回功能。仅供本次诊断使用，不要发给测试者。"
}
