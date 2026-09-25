// swift-tools-version: 6.2

import PackageDescription

// libFuzzer harnesses for the parsers that read bytes off the radio. Build and run them with
// `scripts/fuzz.sh`, which passes `-sanitize=fuzzer,address` so the library code is instrumented too; a
// plain `swift build` of this package cannot link, because libFuzzer supplies `main`.

// swiftlint:disable:next explicit_top_level_acl
let package = Package(
    name: "KnitFuzz",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .executableTarget(name: "FuzzCBOR", dependencies: [.product(name: "KnitWire", package: "knit-ios")]),
        .executableTarget(name: "FuzzLinkRecords", dependencies: [.product(name: "KnitWire", package: "knit-ios")]),
        .executableTarget(name: "FuzzAdvert", dependencies: [.product(name: "KnitWire", package: "knit-ios")]),
    ]
)
