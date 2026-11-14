// swift-tools-version: 5.9
import PackageDescription

/// The iOS 17/18 kernel chain (kexploit_opa334 + sandbox_escape) as a local
/// SwiftPM package.
///
/// Kept beside `WorseQuery/` rather than inside `Vendor/` for the same
/// reasons: `Vendor` is the golden-nugget stack, updated as a unit, while this
/// is a small self-contained Objective-C library the app links directly, and
/// its licence (GPL-3.0) is a boundary worth making obvious. The sources are
/// taken verbatim from QuinnTang74/3106 `ThreeOneOSSix/kexploit/` (see
/// README.md and NOTICE for the attribution). 3106's longjmp failure path is
/// kept: a failed chain returns an error code to Swift instead of ending the
/// process.
///
/// `import KernelDirect` comes from the umbrella header the module map is
/// generated for (`include/`), so the app calls the C functions directly — no
/// bridging header, which keeps the SwiftPM (xtool) and Xcode builds of the
/// same sources identical.
let package = Package(
    name: "KernelDirect",
    platforms: [
        // The chain targets iOS 17.0–17.7.x and 18.0–18.7.1; the app's own
        // floor is 17.0. The band gate lives in KernelDirectPremise, not here.
        .iOS("17.0"),
    ],
    products: [
        .library(
            name: "KernelDirect",
            targets: ["KernelDirect"]
        ),
    ],
    targets: [
        .target(
            name: "KernelDirect",
            path: "Sources/KernelDirect",
            publicHeadersPath: "include",
            cSettings: [
                // The upstream Xcode target is ARC; the sources carry no
                // manual retain/release, so the same setting here is the
                // faithful one.
                .unsafeFlags(["-fobjc-arc"]),
            ],
            linkerSettings: [
                // kexploit_opa334 allocates IOSurfaces for the physical-page
                // spray; UIKit/Foundation come from the headers it imports.
                .linkedFramework("IOSurface"),
                .linkedFramework("UIKit"),
                .linkedFramework("Foundation"),
            ]
        ),
    ],
    cLanguageStandard: .gnu11
)
