---
id: "2026-09.wde9"
slug: the-protocol-core-is-platform
title: "the protocol core is platform-free Swift that builds and tests on Linux"
date: 2026-09-25
topics: [architecture, build, testing]
---

# ADR 2026-09.wde9 — the protocol core is platform-free Swift that builds and tests on Linux

Status: Accepted (2026-09-25)

**Context:** the only development machine for the first weeks is Linux, with no Mac and no iPhone. xtool
cross-compiles an iOS app but cannot run one, and the iOS Simulator has no Bluetooth anyway. knit-next
already keeps its router, custody and codec free of Android imports and tests them on the JVM.

**Decision:** one SwiftPM package. `KnitWire`, `KnitCrypto`, `KnitStore`, `KnitMesh` and `KnitAppCore` import no
Apple framework, use swift-crypto for cryptography, and build and test on Linux. `KnitBLE` and the `Knit`
app sit behind `#if canImport(…)`, and the BlueZ peer behind `#if os(Linux)`. Splitting the core and the app
into two packages was the alternative. It would mean two `Package.resolved` files and two lint and
Periphery setups, and xtool wants the app product in the root package anyway.

**Consequences / limits:** Linux CI never compiles the Apple-only targets; xtool does, on the local runner, and
their tests wait for the Mac. Periphery on Linux cannot see every use of the platform-free API, so it stays
advisory until then. The Linux build is the check: a platform-free target that imports an Apple framework
fails `scripts/check.sh build`, and the SwiftLint seam rules in `.swiftlint.yml` catch the import first.
