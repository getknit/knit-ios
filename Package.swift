// swift-tools-version: 6.2

import PackageDescription

// A manifest's top-level lets are build script, not API.
// swiftlint:disable explicit_top_level_acl

// The one library product, `Knit`, is the iOS app that xtool packs (`xtool.yml`). Everything else is either
// platform-free protocol code that builds and tests on Linux, or a thin radio adapter for one platform.
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

let package = Package(
    name: "Knit",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Knit", targets: ["Knit"]),
        .executable(name: "knit-peer", targets: ["knit-peer"]),
        // For the fuzz package in Fuzz/, which needs its own sanitizer flags. xtool.yml names `Knit` explicitly.
        .library(name: "KnitWire", targets: ["KnitWire"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        // Platform-free protocol core (Linux + Apple).
        .target(name: "KnitWire", swiftSettings: pure),
        .target(name: "KnitCrypto", dependencies: ["KnitWire", crypto], swiftSettings: pure),
        .target(name: "KnitStore", dependencies: ["KnitWire"], swiftSettings: pure),
        // The app's store: the KnitStore protocols on SQLite through GRDB. Tests and the Linux peer keep the
        // in-memory stores.
        .target(name: "KnitStoreSQL", dependencies: ["KnitStore", "KnitWire", grdb], swiftSettings: pure),
        .target(name: "KnitMesh", dependencies: ["KnitWire", "KnitCrypto", "KnitStore"], swiftSettings: pure),
        // View models, UI state and the copy catalog: everything the screens show, tested on Linux.
        .target(name: "KnitAppCore", dependencies: ["KnitMesh", "KnitCrypto", "KnitStore", "KnitWire"], swiftSettings: strict),

        // Apple: the CoreBluetooth radio and the SwiftUI app. Both compile to empty modules elsewhere.
        .target(name: "KnitBLE", dependencies: ["KnitMesh", "KnitWire"], swiftSettings: strict),
        .target(
            name: "Knit",
            dependencies: ["KnitAppCore", "KnitBLE", "KnitStoreSQL", "KnitControl", "KnitMesh", "KnitCrypto", "KnitStore", "KnitWire"],
            swiftSettings: strict,
            // xtool links every target as a static archive, and the linker keeps only the members something names.
            // CoreBluetooth calls KnitBLE's delegates through the Objective-C runtime alone, so without -ObjC their
            // file never reached the app, and iOS stopped it at the first Bluetooth grant. `check.sh ios` checks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-ObjC"], .when(platforms: [.iOS]))]
        ),

        // Linux: the BlueZ radio and the headless peer used for interop runs.
        .systemLibrary(name: "CDBus", pkgConfig: "dbus-1", providers: [.apt(["libdbus-1-dev"])]),
        .target(name: "CBluetoothShim"),
        .target(
            name: "KnitBlueZ",
            dependencies: [
                "KnitMesh",
                "KnitWire",
                "CBluetoothShim",
                .target(name: "CDBus", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: strict
        ),
        // The JSON-lines control surface, platform-free: what `knit-peer` answers on standard input, and a debug build
        // of the app over USB.
        .target(name: "KnitControl", dependencies: ["KnitMesh", "KnitCrypto", "KnitStore", "KnitWire"], swiftSettings: strict),
        // The peer's logic, platform-free so its tests run anywhere: options, its state directory and keygen.
        // `knit-peer` wires it to the BlueZ radio.
        .target(name: "KnitPeer", dependencies: ["KnitControl", "KnitMesh", "KnitCrypto", "KnitStore", "KnitWire"], swiftSettings: strict),
        .executableTarget(
            name: "knit-peer",
            dependencies: [
                "KnitPeer",
                "KnitControl",
                "KnitMesh",
                "KnitCrypto",
                "KnitStore",
                "KnitWire",
                .target(name: "KnitBlueZ", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: strict
        ),

        // What more than one test target reads: the golden vectors and knit-next's fixture bytes. Not a product.
        .target(name: "KnitTestSupport", dependencies: ["KnitWire"], path: "Tests/KnitTestSupport", swiftSettings: strict),

        .testTarget(name: "KnitWireTests", dependencies: ["KnitWire", "KnitTestSupport"], swiftSettings: strict),
        .testTarget(
            name: "KnitCryptoTests",
            dependencies: ["KnitCrypto", "KnitWire", "KnitTestSupport", crypto],
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
            dependencies: ["KnitStoreSQL", "KnitStore", "KnitWire", "KnitTestSupport", grdb],
            swiftSettings: strict
        ),
        .testTarget(
            name: "KnitMeshTests",
            dependencies: ["KnitMesh", "KnitCrypto", "KnitStore", "KnitWire", "KnitTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "KnitAppCoreTests",
            dependencies: ["KnitAppCore", "KnitMesh", "KnitCrypto", "KnitStore", "KnitWire", "KnitTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "KnitControlTests",
            dependencies: ["KnitControl", "KnitMesh", "KnitCrypto", "KnitStore", "KnitWire", "KnitTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "KnitPeerTests",
            dependencies: ["KnitPeer", "KnitControl", "KnitMesh", "KnitCrypto", "KnitStore", "KnitWire", "KnitTestSupport"],
            swiftSettings: strict
        ),
        // Runs the BlueZ radio against a fake BlueZ on a peer-to-peer bus, and Unix sockets in place of L2CAP.
        .testTarget(
            name: "KnitBlueZTests",
            dependencies: [
                "KnitBlueZ", "KnitMesh", "KnitWire", "KnitTestSupport", .target(name: "CDBus", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: strict
        ),
        .testTarget(name: "RepoConventionTests", dependencies: [crypto], swiftSettings: strict),
    ]
)
// swiftlint:enable explicit_top_level_acl
