import Foundation

/// The hand-off box between the share extension and the app.
///
/// The extension cannot import — its memory ceiling is far below
/// what unpacking a big pack takes — so it only copies the shared
/// file into a folder inside the App Group container, and the app
/// imports whatever it finds there on its next launch or return to
/// the foreground (see `DriftRootView.drainShareInbox`). This file is
/// compiled into both targets: it is the one piece of logic the two
/// processes must agree on.
///
/// Which group: the signing decides what a process may open, so the
/// candidates are the group the app declares for itself plus every
/// group the signed profile grants, in profile order. The extension
/// writes into the first candidate whose container it can actually
/// create the folder in; the app reads from *all* candidates, so the
/// two sides cannot disagree about which one was picked.
enum ShareInbox {
    /// The group Drift declares in its own entitlements — what a
    /// signing with Drift's own profile grants.
    private static let declaredGroup = "group.com.sociart.drift"
    private static let inboxName = "ShareInbox"

    /// App Group identifiers worth trying: the declared group first,
    /// then the signed profile's `application-groups` in order.
    static func candidateGroupIdentifiers() -> [String] {
        var ids = [declaredGroup]
        for id in profileGroupIdentifiers() where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    /// The groups named by the app bundle's embedded provisioning
    /// profile, or empty when the bundle carries no readable profile
    /// (an unsigned build, where the declared group is all there is).
    /// The profile is a CMS blob wrapped around an XML plist; the
    /// plist is lifted out by locating its markers.
    private static func profileGroupIdentifiers() -> [String] {
        let profile = appBundleURL()
            .appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: profile),
              let start = data.range(of: Data("<?xml".utf8))
        else { return [] }
        // `Data.range(of:in:)` does not yield an Optional in the
        // current SDK, so the closing marker is located through
        // NSData, whose not-found answer is explicit.
        let endMarker = Data("</plist>".utf8)
        let end = (data as NSData).range(
            of: endMarker, options: [],
            in: NSRange(location: start.lowerBound,
                        length: data.count - start.lowerBound))
        guard end.location != NSNotFound else { return [] }
        let plistData = data[start.lowerBound..<(end.location + end.length)]
        guard let object = try? PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil),
              let dict = object as? [String: Any],
              let entitlements = dict["Entitlements"] as? [String: Any],
              let groups = entitlements["application-groups"] as? [String]
        else { return [] }
        return groups
    }

    /// The containing app's bundle. In the app this is `Bundle.main`;
    /// in the extension `Bundle.main` is the appex itself, which sits
    /// at `<App>.app/PlugIns/<name>.appex` — two levels down.
    private static func appBundleURL() -> URL {
        let main = Bundle.main.bundleURL
        if main.pathExtension == "appex" {
            return main.deletingLastPathComponent()
                .deletingLastPathComponent()
        }
        return main
    }

    /// The inbox directory inside the first App Group container this
    /// process can open *and write to*, created on demand. Nil when
    /// the signing grants no usable group — the extension then has
    /// nowhere to hand the file to and says so.
    static func writableInboxDirectory() -> URL? {
        let fm = FileManager.default
        for id in candidateGroupIdentifiers() {
            guard let container = fm.containerURL(
                forSecurityApplicationGroupIdentifier: id) else { continue }
            let dir = container.appendingPathComponent(inboxName,
                                                       isDirectory: true)
            do {
                try fm.createDirectory(at: dir,
                                       withIntermediateDirectories: true)
                // containerURL can hand back a URL for a group whose
                // container is not really this process's to write;
                // prove the folder is writable before trusting it.
                let probe = dir.appendingPathComponent(".write-probe")
                try Data().write(to: probe)
                try fm.removeItem(at: probe)
                return dir
            } catch {
                continue
            }
        }
        return nil
    }

    /// Files waiting in any candidate group's inbox, oldest first.
    /// Files the app has not processed yet are the only contents —
    /// the app removes each one as it imports it.
    static func pendingFiles() -> [URL] {
        let fm = FileManager.default
        var found: [(url: URL, modified: Date)] = []
        for id in candidateGroupIdentifiers() {
            guard let container = fm.containerURL(
                forSecurityApplicationGroupIdentifier: id) else { continue }
            let dir = container.appendingPathComponent(inboxName,
                                                       isDirectory: true)
            let items = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in items where !url.lastPathComponent.hasPrefix(".") {
                let modified = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                found.append((url, modified))
            }
        }
        return found.sorted { $0.modified < $1.modified }.map(\.url)
    }

    /// A collision-free destination for `name` inside `directory`:
    /// the plain name, or `name (2)`, `name (3)`, … — two packs
    /// shared before the app next launches must both survive.
    static func uniqueDestination(in directory: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            candidate = directory.appendingPathComponent(
                ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }
}
