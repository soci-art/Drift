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
/// AirLift — with the same 26.2 floor, and closed again from 27.2 beta 3.
/// What it does afterwards is the
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
/// If the refresh is not confirmed, it stops there: the wallpaper is written,
/// the user gets a manual-respring button, and this channel never falls back
/// to 注销直刷 or triggers a respring on its own.
///
/// This is a single-cycle transaction in the same tunnel write module AirLift
/// uses — the reload preferences ride inside that transaction. It is not a
/// relative of the sealed restore route.
struct PosterBoardDirectOutcome {
    let verification: PosterStoreVerification
    let effect: PosterBoardEffect
}

enum PosterBoardDirect {
    /// The bundle whose container holds the store.
    static let bundleID = "com.apple.PosterBoard"

    /// The oldest system this route is supported on: 26.2, the same floor as
    /// the other tunnel channel. 26.0–26.1 belong to 本机直刷 only.
    static let minimumVersion = "26.2"

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
            return "免注销直刷在 iOS 27.2 测试版 3 起已被系统修复。"
        }
        if let floor = PosterBoard.compareVersion(deviceVersion, minimumVersion), floor < 0 {
            return "免注销直刷需要 iOS \(minimumVersion) 或更高版本。"
        }
        if PosterBoard.compareVersion(deviceVersion, "27.2") == 0 {
            if buildVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "iOS 27.2 要按构建号判断：还没有读到设备构建号。"
            }
            if !AirliftAvailability.early272Builds.contains(
                buildVersion.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return "免注销直刷在 iOS 27.2 测试版 3 起已关闭，只有测试版 1/2（24B5084k、24B5089g）可用。"
            }
        }
        return ""
    }

    // MARK: - Apply

    /// Install the selected packs and templates, then refresh PosterBoard.
    /// Returns the store verification for the write (2.0.0): the caller
    /// grades its success wording from it.
    static func apply(
        selection: PosterBoardSelection,
        templates: [TemplateFile] = [],
        structureVersion: Int,
        deviceVersion: String,
        buildVersion: String,
        pairingPath: String,
        log: @escaping @Sendable (String) -> Void,
        progress: @escaping (Double) -> Void
    ) async throws -> PosterBoardDirectOutcome {
        // The engine checks this too; repeating it here means a caller cannot
        // start a transaction the route knows is closed for this build.
        guard isAvailable(deviceVersion: deviceVersion, buildVersion: buildVersion) else {
            throw DriftError(unavailableReason(deviceVersion: deviceVersion,
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
        guard !sources.isEmpty else { throw DriftError("没有可写入的 PosterBoard 包或模板。") }

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

        // Pre-write read (2.0.0): enumerate the device's store before
        // writing, so the structure version and the target providers are
        // checked against the device's own state rather than assumed.
        let preItems = await PosterStoreCheck.enumerateStore(
            pairingPath: pairingPath, containerPath: container,
            structureVersion: structureVersion,
            targetProviders: Set(sources.map(\.defaultExtension)), log: log)
        let versionSource = PosterStoreCheck.versionSource(
            structureVersion: structureVersion, preItems: preItems)
        log(versionSource)
        let providersSeen = Set((preItems ?? []).map(\.extension))

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

        var injected = 0
        /// What actually landed, as (provider, descriptor id) — the
        /// post-write enumeration is checked against exactly this set.
        var written: [(extensionID: String, uuid: String)] = []

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
                    throw DriftError("在 \(source.name) 中没有找到壁纸描述文件。"
                        + "对于交付容器文件的模板，需要走「恢复刷」。"
                        + DriftRestoreGate.unavailableSuffix)
                }
                log("  \(descriptors.count) descriptor(s)")

                for (position, descriptor) in descriptors.enumerated() {
                    let target = UUID().uuidString.uppercased()
                    let numericID = Int.random(in: PosterBoard.identifierRange)
                    // Destination from the descriptor's own extension ID,
                    // via the one shared constructor (铁律 1) — 1.3.0 renamed
                    // Collections to a store folder the device does not have.
                    let parent = PosterBoard.descriptorsParentPath(
                        container: container, structureVersion: structureVersion,
                        extensionID: descriptor.extensionID)
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
                        written.append((extensionID: descriptor.extensionID, uuid: target))
                        done += 1
                        log("  ✅ \(position + 1)/\(descriptors.count) → \(descriptor.extensionID)")
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
            throw DriftError("没有写入任何 PosterBoard 描述文件。设备必须保持解锁，"
                + "并让 LocalDevVPN 连通；如果当时已经解锁，那么缓存的容器信息已过期，"
                + "并已为下一次尝试清除。")
        }

        // Post-write read (2.0.0): the write's own confirmations cover the
        // staging area, not the store — enumerate the store itself before
        // claiming anything about display.
        let verification = await PosterStoreCheck.verify(
            pairingPath: pairingPath, containerPath: container,
            structureVersion: structureVersion,
            structureVersionSource: versionSource,
            providersSeen: providersSeen,
            expected: Set(written.map { "\($0.extensionID)/\($0.uuid)" }),
            log: log)

        progress(99)
        log("Refreshing PosterBoard without a respring…")
        let refresh = await PosterRefresh.attempt(pairingPath: pairingPath)
        let effect: PosterBoardEffect
        if refresh.confirmed {
            log("✅ \(refresh.status.explanation) — 免注销生效。")
            effect = PosterBoardEffect(
                kind: .noRespring,
                headline: "刷入完成，免注销生效",
                detail: "只重启了 PosterBoard，壁纸已经可见，其他 App 不受影响。")
        } else {
            log("⚠️ 免注销刷新未确认（\(refresh.status.explanation)），只提示，不自动注销。")
            effect = PosterBoardEffect(
                kind: .manualRespring,
                headline: "壁纸已写入（免注销未确认）",
                detail: "PosterBoard 刷新没有确认（\(refresh.status.explanation)）。壁纸已经在商店里，"
                    + "点「手动注销」让 PosterBoard 读到它们。App 不会自动注销，也不会改走注销直刷。")
        }
        progress(100)
        log("Installed \(injected) descriptor(s) over the pairing tunnel.")
        return PosterBoardDirectOutcome(verification: verification, effect: effect)
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
