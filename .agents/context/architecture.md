# Architecture

One root SwiftPM package. xtool packs its `Knit` library product as the iOS app (`xtool.yml`); every other
target is either platform-free protocol code that builds and tests on Linux, or a thin radio adapter for
one platform. The libFuzzer harnesses live in their own package under `Fuzz/`.

## Targets

| Target | Builds on | Role | Phase |
| --- | --- | --- | --- |
| `KnitWire` | all | CBOR (kotlinx profile), wire types, registries, link records, HELLO/DIGEST, advert, NodeId/FrameId/FrameKey, UTF-16 limits, FNV fold | P1 |
| `KnitCrypto` | all | identity and bundle, node id, sign/verify, v1 DM seal/open, safety number, alias words | P2 |
| `KnitStore` | all | repository protocols and an in-memory store | P3 |
| `KnitStoreSQL` | Apple, Linux if GRDB builds there | GRDB schema and migrations | P5 |
| `KnitMesh` | all | `MeshTransport`, `LinkManager` behind a `Radio` protocol, router, SeenSet, custody, sync, receipts, key recovery, profiles, conversations, policies | P3 |
| `KnitAppCore` | all | `@Observable` view models, UI state, the copy catalog | P6 |
| `KnitBLE` | Apple | the CoreBluetooth `Radio`: central, peripheral with the GATT payload, L2CAP streams, restoration | P6 |
| `Knit` | Apple | SwiftUI, `@main`, Keychain, notifications, the composition root | P6 |
| `KnitBlueZ`, `CDBus`, `CBluetoothShim` | Linux | the BlueZ `Radio`: D-Bus advert, scan and GATT through libdbus-1, LE CoC sockets | P4 |
| `knit-peer` | Linux (a stub `main` elsewhere) | the headless peer with a JSON-lines control interface | P4 |
| `KnitLabSupport` | all | LabTransport, LabRadio, LabClock, MeshLab | P3 |

Platform-only code sits behind `#if canImport(CoreBluetooth)`, `#if canImport(SwiftUI)`, `#if os(iOS)` or
`#if os(Linux)`, so `swift build` works everywhere and an Apple-only target compiles to an empty module on
Linux. The Linux build is therefore the proof that the platform-free targets import no Apple framework.

## Seams

- **Everything above the radio talks only to `MeshTransport`.**
- **One `LinkManager` owns dialing and admission for every radio**: the HELLO exchange, the tie-break,
  duplicate and stale-link handling. KnitBLE and KnitBlueZ only move bytes. Links are keyed by link
  instance, never by node id: on Android, closing a replaced link removes its replacement
  (`BluetoothMeshTransport.kt:787` and `:806`).
- **One importing target per framework**, each enforced by a SwiftLint custom rule in `.swiftlint.yml`:

  | Framework | Only in |
  | --- | --- |
  | CoreBluetooth | `KnitBLE` |
  | SwiftUI and UIKit | `Knit` |
  | Security (the Keychain) | `Knit` |
  | GRDB | `KnitStoreSQL` |
  | CDBus and the socket shim | `KnitBlueZ` |
  | CryptoKit | nowhere: import swift-crypto's `Crypto`, which is CryptoKit on Apple platforms |

## Time, randomness and logging

- **The mesh takes two clocks:** wall time for `sentAt`, monotonic time for timers and timeouts.
- **Randomness comes from an injected generator:** frame ids and relay jitter. With both injected, the lab
  can drive a scenario to a known outcome and chaos runs reproduce from a seed. SwiftLint bans `Date()`,
  `Task.sleep`, `UUID()` and `.random(` in the protocol targets.
- **`identifierForVendor`** reaches `KnitCrypto` as a value, not as a UIKit call.
- **Logging goes through a small `KnitLog` protocol.** `print` is banned in `Sources/`, and knit-peer writes
  its JSON lines to standard output directly.

## Concurrency

- **Language mode:** Swift 6, with complete concurrency checking.
- **Actors and streams:** the mesh engine is an actor, and transports report events as AsyncStreams.
- **Radio threading:** CoreBluetooth delegates run on one serial queue. L2CAP `Stream`s run on a dedicated
  run-loop thread inside one class.
- **Locks:** `Synchronization.Mutex` (iOS 18) where a lock is needed. A database transaction sits outside
  any crypto lock, the same ordering as knit-next's `rules/mesh.md`.

## Storage

- **Database:** GRDB over SQLite, with file protection `completeUntilFirstUserAuthentication` (the mesh runs
  while the phone is locked), excluded from backups.
- **Keys:** the Keychain, as `…AfterFirstUnlockThisDeviceOnly`.
- **SQLCipher** waits until there is a reason beyond iOS's own file protection.
- **Tests and the Linux peer** use the in-memory store.

## Dependencies

- **Shipped:** swift-crypto and GRDB.swift.
- **Pinned:** `Package.resolved` is committed, and CI builds with `--only-use-versions-from-resolved-file`.
- **Tracked:** `RepoConventionTests.NoticesSyncTests` fails until every resolved package has a row in
  `THIRD-PARTY-NOTICES.md`.
- **The permissive-license rule** covers what ships in the app. knit-peer links libdbus (AFL-2.1 or
  GPL-2.0-or-later), which is fine for a tool that is never distributed.
