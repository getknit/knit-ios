// swift-tools-version: 6.2

import PackageDescription

// A manifest's top-level lets are build script, not API.
// swiftlint:disable explicit_top_level_acl

// The one library product, `Knit`, is the iOS app that the Xcode project packs (`App/project.yml`). Everything
// else is either platform-free protocol code that builds and tests on Linux, or a thin radio adapter for one
// platform.
// ADR 2026-09.wde9 records the split; `.agents/context/architecture.md` has the target map.

/// knit-next's `-Pknit.warningsAsErrors=false`: set `KNIT_WARNINGS_AS_ERRORS=0` to build locally through a
/// new toolchain's warnings. CI never sets it.
let warningsAsErrors = Context.environment["KNIT_WARNINGS_AS_ERRORS"] != "0"

/// Every first-party target, test targets included.
let strict: [SwiftSetting] =
    [
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
    ] + (warningsAsErrors ? [.treatAllWarnings(as: .error)] : [])

/// Platform-free targets also opt into strict memory safety, so an unsafe construct there has to say so.
/// The radio adapters stay out: every libdbus and `InputStream` call would need `unsafe`.
let pure: [SwiftSetting] = strict + [.strictMemorySafety()]

let crypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto")
let grdb: Target.Dependency = .product(name: "GRDB", package: "GRDB.swift")
let webp: Target.Dependency = .product(name: "libwebp", package: "libwebp-Xcode")
// libdbus through pkg-config, for the BlueZ radio: Linux only, where every `import CDBus` sits behind `#if os(Linux)`.
// Declared on a Mac too, the system library cost every SwiftPM build there two pkg-config warnings.
#if os(Linux)
    let dbusLibrary: [Target] = [.systemLibrary(name: "CDBus", pkgConfig: "dbus-1", providers: [.apt(["libdbus-1-dev"])])]
    let dbus: [Target.Dependency] = ["CDBus"]
#else
    let dbusLibrary: [Target] = []
    let dbus: [Target.Dependency] = []
#endif
// knit-peer's Info.plist, linked into its __TEXT segment on a Mac for the Bluetooth usage string.
let peerInfoPlist = [
    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/knit-peer/Info.plist",
]

let package = Package(
    name: "Knit",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Knit", targets: ["Knit"]),
        .executable(name: "knit-peer", targets: ["knit-peer"]),
        // For the fuzz package in Fuzz/, which needs its own sanitizer flags. App/project.yml names `Knit` explicitly.
        .library(name: "KnitWire", targets: ["KnitWire"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        // Upstream libwebp's sources as one C target: ImageIO reads WebP but writes none (ADR 2026-10.m4ah).
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", from: "1.6.0"),
    ],
    targets: [
        // A lock ThreadSanitizer can see, which every target uses in place of Synchronization.Mutex (ADR 2026-09.ahrr).
        .target(name: "KnitSync", swiftSettings: pure),

        // Platform-free protocol core (Linux + Apple).
        .target(name: "KnitWire", swiftSettings: pure),
        .target(name: "KnitCrypto", dependencies: ["KnitWire", crypto], swiftSettings: pure),
        .target(name: "KnitStore", dependencies: ["KnitSync", "KnitWire"], swiftSettings: pure),
        // The app's store: the KnitStore protocols on SQLite through GRDB, and the store unit they commit in, whose state
        // sits behind KnitSync's Lock. Tests and the Linux peer keep the in-memory stores.
        .target(name: "KnitStoreSQL", dependencies: ["KnitSync", "KnitStore", "KnitWire", grdb], swiftSettings: pure),
        .target(name: "KnitMesh", dependencies: ["KnitWire", "KnitCrypto", "KnitStore"], swiftSettings: pure),
        // View models, UI state and the copy catalog: everything the screens show, tested on Linux.
        .target(name: "KnitAppCore", dependencies: ["KnitSync", "KnitMesh", "KnitCrypto", "KnitStore", "KnitWire"], swiftSettings: strict),

        // libwebp's encoder behind a small Swift API: a picked GIF leaves as an animated WebP, as Android's does. Not
        // `pure`: every call into the C library is unsafe.
        .target(name: "KnitWebP", dependencies: [webp], swiftSettings: strict),

        // Apple: the CoreBluetooth radio and the SwiftUI app. Both compile to empty modules elsewhere.
        .target(name: "KnitBLE", dependencies: ["KnitMesh", "KnitWire"], swiftSettings: strict),
        .target(
            name: "Knit",
            dependencies: [
                "KnitAppCore", "KnitBLE", "KnitStoreSQL", "KnitControl", "KnitWebP", "KnitMesh", "KnitCrypto", "KnitStore", "KnitWire",
            ],
            swiftSettings: strict,
            // The app links every target as a static archive, and the linker keeps only the members something names.
            // CoreBluetooth calls KnitBLE's delegates through the Objective-C runtime alone, so without -ObjC their
            // file never reached the app, and iOS stopped it at the first Bluetooth grant. `check.sh xcode` checks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-ObjC"], .when(platforms: [.iOS]))]
        ),

        // The headless peer used for interop runs, on BlueZ under Linux and CoreBluetooth on a Mac, and its Linux radio.
        .target(name: "CBluetoothShim"),
        .target(name: "KnitBlueZ", dependencies: ["KnitSync", "KnitMesh", "KnitWire", "CBluetoothShim"] + dbus, swiftSettings: strict),
        // The JSON-lines control surface, platform-free: what `knit-peer` answers on standard input, and a debug build
        // of the app over its bridge, with the bridge's Wi-Fi pins and screen recordings, whose files it hashes.
        .target(name: "KnitControl", dependencies: ["KnitMesh", "KnitCrypto", "KnitStore", "KnitWire", crypto], swiftSettings: strict),
        // The peer's logic, platform-free so its tests run anywhere: options, its state directory and keygen.
        // `knit-peer` wires it to the BlueZ radio.
        .target(
            name: "KnitPeer",
            dependencies: ["KnitSync", "KnitControl", "KnitMesh", "KnitCrypto", "KnitStore", "KnitWire"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "knit-peer",
            dependencies: [
                "KnitSync",
                "KnitPeer",
                "KnitControl",
                "KnitMesh",
                "KnitCrypto",
                "KnitStore",
                "KnitWire",
                .target(name: "KnitBlueZ", condition: .when(platforms: [.linux])),
                .target(name: "KnitBLE", condition: .when(platforms: [.macOS])),
            ],
            // Linked into the binary on a Mac: macOS asks for Bluetooth with its usage string, and ends a process that
            // touches CoreBluetooth without one.
            exclude: ["Info.plist"],
            swiftSettings: strict,
            linkerSettings: [.unsafeFlags(peerInfoPlist, .when(platforms: [.macOS]))]
        ),

        // What more than one test target reads: the golden vectors and knit-next's fixture bytes. Not a product.
        .target(name: "KnitTestSupport", dependencies: ["KnitWire"], path: "Tests/KnitTestSupport", swiftSettings: strict),

        .testTarget(name: "KnitSyncTests", dependencies: ["KnitSync"], swiftSettings: strict),
        .testTarget(name: "KnitWireTests", dependencies: ["KnitWire", "KnitTestSupport"], swiftSettings: strict),
        .testTarget(
            name: "KnitCryptoTests",
            dependencies: ["KnitSync", "KnitCrypto", "KnitWire", "KnitTestSupport", crypto],
            swiftSettings: strict
        ),
        // The store contract tests run against every implementation, the SQL one included.
        .testTarget(
            name: "KnitStoreTests",
            dependencies: ["KnitStore", "KnitStoreSQL", "KnitWire", "KnitTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "KnitStoreSQLTests",
            dependencies: ["KnitSync", "KnitStoreSQL", "KnitStore", "KnitWire", "KnitTestSupport", grdb],
            swiftSettings: strict
        ),
        .testTarget(
            name: "KnitMeshTests",
            dependencies: ["KnitSync", "KnitMesh", "KnitCrypto", "KnitStore", "KnitWire", "KnitTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "KnitAppCoreTests",
            dependencies: ["KnitSync", "KnitAppCore", "KnitMesh", "KnitCrypto", "KnitStore", "KnitWire", "KnitTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "KnitControlTests",
            dependencies: ["KnitSync", "KnitControl", "KnitMesh", "KnitCrypto", "KnitStore", "KnitWire", "KnitTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "KnitPeerTests",
            dependencies: ["KnitSync", "KnitPeer", "KnitControl", "KnitMesh", "KnitCrypto", "KnitStore", "KnitWire", "KnitTestSupport"],
            swiftSettings: strict
        ),
        // Runs the BlueZ radio against a fake BlueZ on a peer-to-peer bus, and Unix sockets in place of L2CAP.
        .testTarget(
            name: "KnitBlueZTests",
            dependencies: ["KnitSync", "KnitBlueZ", "KnitMesh", "KnitWire", "KnitTestSupport"] + dbus,
            swiftSettings: strict
        ),
        // KnitBLE's stream code over bound stream pairs, on the Mac; an empty target elsewhere, like KnitBLE itself.
        .testTarget(name: "KnitBLETests", dependencies: ["KnitSync", "KnitBLE", "KnitMesh"], swiftSettings: strict),
        .testTarget(name: "KnitWebPTests", dependencies: ["KnitWebP", webp], swiftSettings: strict),
        .testTarget(name: "RepoConventionTests", dependencies: [crypto], swiftSettings: strict),
    ] + dbusLibrary
)
// swiftlint:enable explicit_top_level_acl
