import Foundation
import ZIPFoundation

/// PosterBoard wallpapers written over the pairing tunnel — the direct
/// (AirTraffic/Books) route.
///
/// ## What it is
///
/// This is the tunnel write path, not the restore route: it runs the same
/// one-cycle AirTraffic/Books transaction AirLift uses
/// (`Airlift.flashTransaction`), with one difference — the reload preferences
/// are merged into that same transaction instead of opening a second one. It
/// needs a pairing record, LocalDevVPN and an unlocked device, exactly like
/// AirLift — but it works from iOS 26.0, while AirLift's escape starts at
/// 26.2 and is closed again from 27.2 beta 3. What it does afterwards is the
/// other difference: only the PosterBoard daemon is restarted (`PosterRefresh`),
/// so the wallpaper appears without a respring. It is not related to the
/// protective-backup route.
///
/// ## What it does not do
///
/// It adds descriptors; it cannot remove them, so a store reset still belongs
/// to the backup route. The video stage is computed for the backup route and
/// is refused by the engine before this runs. Only one descriptor is installed
/// per transaction (the primary provider spot); the mirror spot is deferred,
/// matching the transaction shape this is ported from.
///
/// ## Refresh
///
/// After the writes this asks the device to restart only the PosterBoard
/// daemon (see `PosterRefresh`) so the wallpaper appears without a respring.
/// If the refresh is not confirmed, it falls back to `NeoSpring` and says so —
/// the wallpapers are already in the store either way.
enum PosterBoardDirect {
    /// The bundle whose container holds the store.
    static let bundleID = "com.apple.PosterBoard"

    /// The oldest system this route is known to work on. The transaction is
    /// the pre-AirLift pipeline, so the floor is the app's own floor.
    static let minimumVersion = "26.0"

    /// Where the two reload-preference copies go.
    private static let mobilePreferences = "/var/mobile/Library/Preferences"
    private static let preferencesFileName = "com.apple.PosterBoard.unprotectedUserDefaults.plist"

    /// Whether the route is in its supported range.
    ///
    /// The version alone cannot decide 27.2 any more: the route still works on
    /// beta 1 (`24B5084k`) and beta 2 (`24B5089g`) and is closed from beta 3,
    /// and all three report `27.2`. The early-build list is
    /// `AirliftAvailability.early272Builds` — one list for both tunnel routes,
    /// so they cannot disagree about which build closed. An unreadable or empty
    /// build on 27.2 fails closed rather than guessing.
    static func isAvailable(deviceVersion: String, buildVersion: String) -> Bool {
        guard let floor = PosterBoard.compareVersion(deviceVersion, minimumVersion), floor >= 0,
              let ceiling = PosterBoard.compareVersion(deviceVersion, "27.2") else {
            return false
        }
        if ceiling > 0 { return false }
        if ceiling == 0 {
            return AirliftAvailability.early272Builds.contains(
                buildVersion.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return true
    }

    static func unavailableReason(deviceVersion: String, buildVersion: String = "") -> String {
        if deviceVersion.isEmpty { return "还没有读到设备系统版本。" }
        if let ceiling = PosterBoard.compareVersion(deviceVersion, "27.2"), ceiling > 0 {
            return "直刷在 iOS 27.2 已被系统修复。"
        }
        if let floor = PosterBoard.compareVersion(deviceVersion, minimumVersion), floor < 0 {
            return "直刷需要 iOS \(minimumVersion) 或更高版本。"
        }
        if PosterBoard.compareVersion(deviceVersion, "27.2") == 0 {
            if buildVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "iOS 27.2 要按构建号判断：还没有读到设备构建号。"
            }
            if !AirliftAvailability.early272Builds.contains(
                buildVersion.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return "直刷在 iOS 27.2 测试版 3 起已关闭，只有测试版 1/2（24B5084k、24B5089g）可用。"
            }
        }
        return ""
    }

    // MARK: - Apply

    /// Install the selected packs and templates, then refresh PosterBoard.
    static func apply(
        selection: PosterBoardSelection,
        templates: [TemplateFile] = [],
        structureVersion: Int,
        deviceVersion: String,
        buildVersion: String,
        pairingPath: String,
        log: @escaping @Sendable (String) -> Void,
        progress: @escaping (Double) -> Void
    ) async throws {
        // The engine checks this too; repeating it here means a caller cannot
        // start a transaction the route knows is closed for this build.
        guard isAvailable(deviceVersion: deviceVersion, buildVersion: buildVersion) else {
            throw GoldenNuggetError(unavailableReason(deviceVersion: deviceVersion,
                                                       buildVersion: buildVersion))
        }
        let packs = selection.tendies
        struct Source {
            let name: String
            let url: URL
            let defaultExtension: String
            let extract: (URL) async throws -> Void
        }
        var sources = packs.map { pack in
            Source(name: pack.name, url: pack.url,
                   defaultExtension: pack.posterType.extensionBundleID) { stage in
                try await Airlift.extractZip(archivePath: pack.url.path, destDir: stage.path)
                if PosterBoard.shouldConvertLegacy(pack: pack, deviceVersion: deviceVersion, log: log) {
                    PosterBoard.convertLegacyPack(pack.name, at: stage, log: log)
                }
            }
        }
        sources += templates.map { template in
            Source(name: template.title, url: template.url,
                   defaultExtension: PosterBoardPosterType.collections.extensionBundleID) { stage in
                try template.extract(to: stage)
                PosterBoard.convertLegacyPack(template.title, at: stage, log: log)
            }
        }
        guard !sources.isEmpty else { throw GoldenNuggetError("没有可写入的 PosterBoard 包或模板。") }

        var container = PosterBoardAirlift.cachedContainer
        if container.isEmpty {
            log("Locating \(bundleID) over the tunnel…")
            container = try await Airlift.appContainer(
                pairingPath: pairingPath, bundleID: bundleID,
                allowUnsupportedVersion: true)
            PosterBoardAirlift.cachedContainer = container
        }
        if !container.hasSuffix("/") { container += "/" }
        log("PosterBoard container: \(container)")
        log("Store version directory: \(structureVersion)")

        // One staged preferences file, reused by every transaction. Its name
        // is the file name the system expects at both targets.
        let prefStage = FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-pref-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: prefStage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: prefStage) }
        let preferenceFile = prefStage.appendingPathComponent(preferencesFileName)
        try reloadPreferences().write(to: preferenceFile)

        let planned = sources.reduce(0) { $0 + PosterBoardAirlift.countDescriptors(inArchiveAt: $1.url) }
        var done = 0
        let overall = { (completed: Int) -> Double in
            guard planned > 0 else { return 0 }
            return min(100, Double(completed) / Double(planned) * 100)
        }
        progress(overall(done))

        let origin = container + "Library/Application Support/"
            + PosterBoard.storeDirectoryName + "/\(structureVersion)/Extensions/"
        var injected = 0

        for (index, source) in sources.enumerated() {
            log("[\(index + 1)/\(sources.count)] \(source.name)")
            do {
                let stage = PosterBoard.workDirectory
                    .appendingPathComponent("direct-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: stage) }

                try await source.extract(stage)

                let descriptors = PosterBoardAirlift.findDescriptors(
                    in: stage, defaultExtension: source.defaultExtension, log: log)
                guard !descriptors.isEmpty else {
                    throw GoldenNuggetError("在 \(source.name) 中没有找到壁纸描述文件。"
                        + "对于交付容器文件的模板，请改用「恢复式」。")
                }
                log("  \(descriptors.count) descriptor(s)")

                for (position, descriptor) in descriptors.enumerated() {
                    let target = UUID().uuidString.uppercased()
                    let numericID = Int.random(in: PosterBoard.identifierRange)
                    let currentExtension = descriptor.extensionID == PosterBoardPosterType.collections.extensionBundleID
                        ? "com.apple.Posters.CollectionsPosterApp" : descriptor.extensionID
                    let parent = origin + currentExtension + "/descriptors"
                    do {
                        try PosterBoardAirlift.randomizeIdentifiers(
                            in: descriptor.url, numericID: numericID,
                            extensionID: descriptor.extensionID)
                        try await Airlift.flashTransaction(
                            pairingPath: pairingPath,
                            folderPath: descriptor.url.path,
                            targetParentDir: parent,
                            destName: target,
                            preferenceFile: preferenceFile.path,
                            preferenceTargetA: container + "Library/Preferences",
                            preferenceTargetB: mobilePreferences)
                        injected += 1
                        done += 1
                        log("  ✅ \(position + 1)/\(descriptors.count) → \(currentExtension)")
                        progress(overall(done))
                    } catch {
                        PosterBoardAirlift.cachedContainer = ""
                        done += 1
                        progress(overall(done))
                        log("  ❌ \(descriptor.extensionID): \(error.localizedDescription)")
                    }
                }
            }
        }

        guard injected > 0 else {
            throw GoldenNuggetError("没有写入任何 PosterBoard 描述文件。设备必须保持解锁，"
                + "并让 LocalDevVPN 连通；如果当时已经解锁，那么缓存的容器信息已过期，"
                + "并已为下一次尝试清除。")
        }

        progress(99)
        log("Refreshing PosterBoard without a respring…")
        let refresh = await PosterRefresh.attempt(pairingPath: pairingPath)
        if refresh.confirmed {
            log("✅ \(refresh.status.explanation) — 免注销生效。")
            progress(100)
        } else {
            log("⚠️ 免注销刷新未确认（\(refresh.status.explanation)），改用注销。")
            let triggered = await MainActor.run { NeoSpring.trigger() }
            guard triggered else {
                throw GoldenNuggetError("壁纸已经写入，但自动刷新失败，而且没有可用的窗口来触发注销。"
                    + "手动注销一次，PosterBoard 就会读到它们。")
            }
            progress(100)
        }
        log("Installed \(injected) descriptor(s) over the pairing tunnel.")
    }

    /// The reload-preferences payload written into both target directories.
    ///
    /// Binary, and deliberately the combined shape the transaction was
    /// verified with: the flag that lets PosterBoard rewrite file protections,
    /// the locale-change flag, and the provider / migration lists. The lists
    /// are harmless on systems that do not read them.
    private static func reloadPreferences() -> Data {
        let plist: [String: Any] = [
            "PBF_RESET_FILE_PROTECTIONS": true,
            "PBF_LOCALE_DID_CHANGE": true,
            "PersistedPosterContainerBundleIdentifiers": [
                "com.apple.Posters.CollectionsPosterApp",
                "com.apple.WallpaperKit.CollectionsPoster",
                "com.apple.MercuryPoster",
                "com.apple.Posters.MercuryPosterApp",
                "com.apple.PhotosUIPrivate.PhotosPosterProvider",
            ],
            "CompletedPosterBundleIdentifierMigrations": [
                "com.apple.Posters.UnityPosterApp.ExtragalacticPoster",
                "com.apple.Posters.WeatherPosterApp.WeatherPoster",
                "com.apple.Posters.UnityPosterApp.Unity2025Poster",
                "com.apple.Posters.UnityPosterApp.UnityPosterExtension",
                "com.apple.Posters.UnityPosterApp.RhizomePoster",
                "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster",
            ],
        ]
        return (try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0)) ?? Data()
    }
}
