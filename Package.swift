// swift-tools-version: 6.0
import PackageDescription

let root = Context.packageDirectory

let package = Package(
    name: "Drift",
    platforms: [
        // iOS 17, matching xtool.yml's `deploymentTarget` and Info.plist's
        // MinimumOSVersion.  It used to say .v16 while those two said 26: the
        // app then shipped a binary whose LC_BUILD_VERSION claimed
        // minos=16.0/sdk=16.0 next to an Info.plist that refuses to install
        // below 26, and compiled against the 26.5 SDK anyway.  One number,
        // stated once per file that has to repeat it.
        .iOS("17.0"),
    ],
    products: [
        // xtool picks the single automatic (static) library product as the app.
        // The product name IS the app binary's name, and CFBundleExecutable in
        // layout/Applications/Drift.app/Info.plist has to agree with
        // it — a mismatch here fails the xtool build at the signing step with
        // "Can't parse BundleExecute file!".  Keep the two in step.
        .library(
            name: "Drift",
            targets: ["Drift"]
        ),
    ],
    dependencies: [
        .package(path: "Vendor"),
        // worse_query (forcequitOS/worse_query), the in-process sandbox escape
        // the on-device wallpaper route uses. Its own package because it is
        // Objective-C, separately licensed (GPL-3.0, compatible with this
        // app's AGPL-3.0) and not part of the vendored golden-nugget stack.
        .package(path: "WorseQuery"),
    ],
    targets: [
        .target(
            name: "Drift",
            dependencies: [
                .product(name: "Minimuxer", package: "Vendor"),
                // The app unpacks `.tendies` wallpaper packs itself, and `.tendies` is a
                // ZIP. ZIPFoundation is already built as part of this package
                // (Minimuxer depends on it), so this is one line of manifest
                // rather than a second ZIP reader written by hand.
                .product(name: "ZIPFoundation", package: "Vendor"),
                // The AirTraffic sandbox escape, for the features that write into
                // app containers directly (Apple Wallet card art, the passcode
                // dialer's TelephonyUI caches) instead of going through a backup
                // restore. See Drift/Core/Airlift.swift for why it is separate
                // from the Minimuxer gateway.
                .product(name: "AirliftFFI", package: "Vendor"),
                // The in-process sandbox escape, used by `PosterBoardLocal`
                // to write into PosterBoard's container without a pairing
                // record or a tunnel.
                .product(name: "WorseQuery", package: "WorseQuery"),
            ],
            path: ".",
            exclude: [
                "layout",
                "scripts",
                ".github",
                "Vendor",
                // A package of its own (a dependency, below). The target path
                // is the repository root, so without this SwiftPM treats the
                // package's C sources as unhandled resources of the app.
                "WorseQuery",
                // Build products are not sources or resources.  They have to be
                // named: SwiftPM treats everything under the target path that is
                // neither a source nor excluded as a resource, and a build tree
                // holds copies of the app's `.lproj` directories — two of them,
                // which SwiftPM rejects as duplicate resources.
                "build",
            ],
            // One entry, not a hand-maintained list.  The list that used to live
            // here had already drifted — it was missing Drift/Core/InFlightCall
            // .swift — and it had to be kept in step with project.pbxproj by
            // hand.  Naming the directory means SwiftPM picks up new files on
            // its own, and it is the same expression project.yml uses
            // (`- path: Drift`).
            //
            // Drift.xcodeproj/project.pbxproj still enumerates files
            // (Xcode has no directory reference for sources), so it is reconciled
            // from this target's resolved source list by
            // scripts/sync-pbxproj-sources.py.
            sources: ["Drift"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // -Osize in release: the linked binary is ~90% prebuilt Rust
                // (idevice + em_proxy), so this is worth ~400 KB out of 15 MB,
                // and nothing outside release pays for it.  The two levers that
                // actually move the number are elsewhere: strip the symbol
                // table in scripts/build-ipa.sh, and recompress the IPA —
                // xtool writes every zip entry STORED, and the zip container is
                // not covered by the code signature, so both are safe.
                //
                // NOT here: -Xlinker -S.  Measured and dropped — SwiftPM does
                // not apply a static library target's linkerSettings to the
                // executable that links it, and xtool links the product from
                // its own throwaway manifest (xtool/.xtool-tmp/, regenerated on
                // every run, gitignored), so the flag never reaches the link.
                .unsafeFlags(["-Osize"], .when(configuration: .release)),
            ],
            linkerSettings: [
                .linkedFramework("UIKit"),
                // NeoSpring (Drift/Core/NeoSpring.swift) resprings by loading a
                // payload into a WKWebView, so WebKit has to be linked.
                .linkedFramework("WebKit"),
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
