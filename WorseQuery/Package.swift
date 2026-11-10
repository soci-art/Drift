// swift-tools-version: 5.9
import PackageDescription

/// worse_query (forcequitOS/worse_query) as a local SwiftPM package.
///
/// Kept in its own package rather than inside `Vendor/` on purpose: `Vendor` is
/// the vendored golden-nugget stack (Minimuxer, IDevice, AirLift, ZIPFoundation)
/// and is updated as a unit. This is a small, self-contained C/Objective-C
/// library the app links directly, and its licence is GPL-3.0 while the rest of
/// the app is AGPL-3.0 — keeping it in one directory makes both the origin and
/// the licence boundary obvious. See README.md here for the attribution.
let package = Package(
    name: "WorseQuery",
    platforms: [
        // The escape targets iOS 26.0 – 26.7.2 and 27.x up to 27.2; the app's
        // own floor is 26.0, so the library states the same floor.
        .iOS("26.0"),
    ],
    products: [
        .library(
            name: "WorseQuery",
            targets: ["WorseQuery"]
        ),
    ],
    targets: [
        // A C-family target (Objective-C), not a Swift one: the whole point is
        // the dyld/XPC dance in worse_query.m, which Swift cannot express.
        // SwiftPM generates the module map for `include/`, so the app writes
        // `import WorseQuery` and calls the two C functions directly — no
        // bridging header, which is what keeps the SwiftPM (xtool) and Xcode
        // builds of the same sources identical.
        .target(
            name: "WorseQuery",
            path: "Sources/WorseQuery",
            publicHeadersPath: "include"
        ),
    ],
    cLanguageStandard: .gnu11
)
