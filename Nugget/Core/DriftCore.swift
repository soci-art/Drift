import Foundation

/// An error whose message is meant for the operator, not for a stack trace.
///
/// Moved out of `GoldenNuggetEngine.swift` in the 2.0.0 engine swap: the type
/// is referenced across the whole app (24 files at the time of the move), so
/// it lives here, in the retained core, while the engine file goes away. The
/// name is kept so every existing reference survives untouched.
struct GoldenNuggetError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One file to deliver into the backup: the payload and where it belongs.
///
/// The Swift counterpart of the reference's `FileToRestore`.  That type carries
/// `contents` **or** `contents_path` — a `FileToRestore` is either bytes in
/// memory or a path to read — and the plist tweaks this port started with only
/// ever used the first half.  The second half is not optional any more:
/// GoldenNugget also builds `FileToRestore` for posterboard assets, where one
/// video wallpaper is a few hundred extracted JPEG frames plus the video
/// itself, and a container pack is a whole data-store snapshot.  Holding that
/// as `Data` would put all of it on the app heap, and the injector reads a
/// payload three times (write, size, digest).
///
/// So a payload is **either** in memory **or** on disk, never both, and every
/// consumer goes through `bytes()`/`byteCount` rather than touching `contents`
/// directly.
///
/// Owner/group are deliberately **not** carried here.  The reference stamps
/// every plist tweak with `Tweak.__init__`'s default `owner=501, group=501`,
/// but the device's own rows disagree per domain — the footnote row is `-2/-2`
/// while a `ManagedPreferencesDomain` row is `501/501`.  The row shape is the
/// device's contract, so it lives in `TweakRowProfile` (one place, measured)
/// and the compiler only says *what* to write.
struct TweakPayload: Equatable {
    let domain: String
    let relativePath: String
    /// The bytes, for a payload that fits in memory.  Empty when `source` is set.
    let contents: Data
    /// A file whose bytes are the payload, for one that does not.  Nil when
    /// `contents` is set.  The file has to still exist when the injector runs —
    /// the caller owns it, and this type never deletes it.
    let source: URL?
    let owner: Int?

    init(domain: String, relativePath: String, contents: Data, owner: Int? = nil) {
        self.domain = domain
        self.relativePath = TweakPayload.manifestPath(relativePath)
        self.contents = contents
        self.source = nil
        self.owner = owner
    }

    init(domain: String, relativePath: String, source: URL) {
        self.domain = domain
        self.relativePath = TweakPayload.manifestPath(relativePath)
        self.contents = Data()
        self.source = source
        self.owner = nil
    }

    /// A manifest row's `relativePath`, with no leading slash.
    ///
    /// Most producers get the shape for free: `TweakDomainMap.split` drops the
    /// `/var/mobile/` prefix and leaves `Library/SpringBoard/…`, which is what the
    /// device's own rows use (`ProtectiveBackup`'s prefixes are written the same
    /// way).  Two producers instead hand over a path that is *already*
    /// domain-relative and still carries the slash — the reference's
    /// `FileToRestore.restore_path` (`/Library/SpringBoard/StatusBarOverrides.archive`,
    /// from `status_bar_tweak.py`) reaches this port as
    /// `StatusBarMechanism.restorePath`, and PosterBoard's container walk starts
    /// from `restorePath: "/"`.
    ///
    /// The reference strips it at the boundary — `restore.py`:
    /// `rel = f.restore_path.lstrip("/")` — and a row that keeps the slash is what
    /// the device rejects with `MBErrorDomain/205 — File path is invalid:
    /// HomeDomain:/Library/SpringBoard/StatusBarOverrides.archive`.  The
    /// directory rows either producer builds are unaffected (splitting on "/"
    /// drops the empty leading component), so only the file row carried the bug.
    ///
    /// Normalised here, in the one type every payload is built through, so no
    /// producer can put the slash into a row.
    static func manifestPath(_ relativePath: String) -> String {
        var path = Substring(relativePath)
        while path.first == "/" { path = path.dropFirst() }
        return String(path)
    }

    var label: String { "\(domain)/\(relativePath)" }

    /// Where the bytes come from, for a log line.
    var origin: String { source?.lastPathComponent ?? "\(contents.count) B in memory" }

    /// The bytes, mapped rather than copied when they are on disk.
    ///
    /// `.mappedIfSafe` and not a plain read: the frames of a video wallpaper are
    /// written straight back out, and mapping lets the kernel hand the same
    /// pages over instead of the app holding a second copy of every one.
    func bytes() throws -> Data {
        guard let source else { return contents }
        do {
            return try Data(contentsOf: source, options: .mappedIfSafe)
        } catch {
            throw TweakPayloadUnavailable(payload: label,
                                          file: source.lastPathComponent,
                                          reason: error.localizedDescription)
        }
    }

    /// The payload's size without reading it.
    var byteCount: Int {
        guard let source else { return contents.count }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size
    }
}

/// A payload whose bytes are on disk and are no longer there.
///
/// Its own type rather than `GoldenNuggetError`, which lives in the engine: this
/// file is one of the five `scripts/tweak-port-diff.py` compiles for the host,
/// and the engine pulls in Minimuxer and SwiftUI, which that harness has no use
/// for.  The message is spelled the way the app's status line reads.
struct TweakPayloadUnavailable: Error, LocalizedError {
    let payload: String
    let file: String
    let reason: String

    var errorDescription: String? {
        "\(payload) 的载荷已从磁盘上消失（\(file)）：\(reason)"
    }
}

// MARK: - TweakVersion (relocated from the deleted TweakModel.swift in 2.0.0;
// the enum is a general version comparator, retained by AirliftAvailability.)

/// The subset of `packaging.version.Version` the registry's bounds need.
///
/// GoldenNugget compares with `packaging.version.Version`
/// (`src/devicemanagement/constants.py:1`).  Every bound in the registry is a
/// plain dotted release — `17.4`, `26.0`, `26.99`, `27.0` — and PEP 440 orders
/// those as zero-padded integer tuples, which is what this reproduces.
///
/// A version whose *first* component is not an integer is deliberately treated
/// as unorderable rather than guessed at: the reference wraps each comparison in
/// `try/except: pass`, which leaves the tweak visible when a parse fails, and a
/// silent "not compatible" verdict on unparseable input would be a different
/// (and worse) outcome than the reference's.
enum TweakVersion {
    private static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        var out: [Int] = []
        for part in parts {
            // A trailing non-numeric component (e.g. `27.0b1`) is dropped, the
            // same way the reference's own `HotLoad._compare` filters parts with
            // `isdigit()`.
            guard let n = Int(part) else { break }
            out.append(n)
        }
        return out.isEmpty ? nil : out
    }

    /// -1 / 0 / 1, or nil when either side has no orderable leading component.
    static func compare(_ lhs: String, _ rhs: String) -> Int? {
        guard var a = components(lhs), var b = components(rhs) else { return nil }
        let count = max(a.count, b.count)
        a += Array(repeating: 0, count: count - a.count)
        b += Array(repeating: 0, count: count - b.count)
        for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
        return 0
    }
}
