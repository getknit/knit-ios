# Architecture

One root SwiftPM package. The Xcode project XcodeGen generates on the Mac packs its `Knit` library product
as the iOS app (`App/project.yml`, ADR 2026-09.de8f); every other target is either platform-free protocol
code that builds and tests on Linux, or a thin radio adapter for one platform. The libFuzzer harnesses live in their own package under `Fuzz/`.

## Targets

| Target | Builds on | Role | Phase |
| --- | --- | --- | --- |
| `KnitSync` | all | `Lock`, the lock every target uses in place of `Synchronization.Mutex` (ADR 2026-09.ahrr) | P6 |
| `KnitWire` | all | CBOR (kotlinx profile), wire types, registries, link records, HELLO/DIGEST, advert, NodeId/FrameId/FrameKey, UTF-16 limits, FNV fold | P1 |
| `KnitCrypto` | all | identity and bundle, node id, sign/verify, v1 DM and group seal/open, group ids, safety number, alias words, identities minted inside a node id window | P2 |
| `KnitStore` | all | repository protocols and in-memory stores (messages and their status lines, groups and their rosters among them), and the custody rules every store applies | P3 |
| `KnitStoreSQL` | all | the `KnitStore` protocols on SQLite through GRDB: the frozen schema, its migrations and the SQL stores | P5 |
| `KnitMesh` | all | `MeshTransport`, `LinkManager` behind a `Radio` protocol, router, SeenSet, custody, sync, receipts, key recovery, profiles, conversations, groups and their roster rules, policies, the system clock | P3 |
| `KnitAppCore` | all | one `AppSession` over the mesh, the `@Observable` view models each screen reads, collision-aware labels, the notification policy, the copy catalog (ADR 2026-09.ycza), and `-seedDemo`'s scenes, radio and shown links | P6 |
| `KnitBLE` | Apple | the CoreBluetooth `Radio`: central and GATT reads, peripheral with the GATT payload, L2CAP streams on one thread, restoration | P6 |
| `Knit` | iOS | the SwiftUI screens, `@main` and the app delegate, the Keychain store, notifications, the unified log, the composition root, and a debug build's bridge, over USB and on a pinned Wi-Fi network (ADR 2026-09.kwa8, ADR 2026-10.dz8d) | P6 |
| `KnitBlueZ`, `CDBus`, `CBluetoothShim` | Linux | the BlueZ `Radio`: one `poll` thread over a libdbus connection and LE CoC sockets; advert, scan, and serving and reading the GATT payload | P4 |
| `KnitControl` | all | the JSON-lines control protocol: commands, replies and event lines over a `Mesh` (`MeshControl`), spoken by `knit-peer` and a debug build of the app (ADR 2026-09.kwa8); the bridge's Wi-Fi pins and commands (`RouterPin`, `WiFiCommand`, ADR 2026-10.dz8d) | P8 |
| `KnitPeer` | all | the peer's logic: options, its state directory, keygen and the scan report | P4 |
| `knit-peer` | Linux and macOS (a stub `main` elsewhere) | the headless peer: `KnitPeer` on the BlueZ radio, on the adapter with the ATS2851's address unless told otherwise, or on a Mac on KnitBLE's CoreBluetooth radio for checklist M (ADR 2026-09.vcdk) | P4, P7 |
| `KnitLabSupport` | all | LabTransport, LabRadio, LabClock, MeshLab: deferred (`.agents/memory/roadmap.md`) | later |

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
  | Security (the Keychain) | `Knit`'s `KeychainSecretStore` |
  | Network | `Knit`'s `BridgeListener` and `WiFiGate`, in a debug build |
  | GRDB | `KnitStoreSQL` |
  | CDBus and the socket shim | `KnitBlueZ`, and `KnitBlueZTests`, which hosts a fake BlueZ |
  | CryptoKit | nowhere: import swift-crypto's `Crypto`, which is CryptoKit on Apple platforms |

## Time, randomness and logging

- **The mesh takes two clocks:** wall time for `sentAt`, monotonic time for timers and timeouts.
- **Randomness comes from an injected generator:** frame ids and relay jitter. With both injected, the lab
  can drive a scenario to a known outcome and chaos runs reproduce from a seed. SwiftLint bans `Date()`,
  `Task.sleep`, `UUID()` and `.random(` in the protocol targets.
- **`identifierForVendor`** reaches `KnitCrypto` as a value, not as a UIKit call.
- **Logging goes through a small `KnitLog` protocol.** `print` is banned in `Sources/`, and knit-peer writes
  its JSON lines to standard output directly. The app writes JSON lines to the unified log (`UnifiedLog`),
  every level in a debug build and warnings only in a release one.
- **The real clocks are `SystemClock`** in `KnitMesh`, the one file the clock ban exempts. The app and knit-peer
  inject it; tests inject their own.

## Concurrency

- **Language mode:** Swift 6, with complete concurrency checking.
- **One actor, synchronous state machines:** `MeshEngine` and `LinkManager` are synchronous classes that keep
  their timers as deadlines. The `Mesh` actor owns both, feeds them what the `Radio` reports through its
  AsyncStream, and runs one timer task aimed at the earliest deadline (ADR 2026-09.gq84).
- **Radio threading:** CoreBluetooth delegates run on one serial queue. L2CAP `Stream`s run on a dedicated
  run-loop thread inside one class.
- **Locks:** `KnitSync`'s `Lock`, `Mutex`'s API over a pthread mutex that TSan can see (ADR 2026-09.ahrr).
  `Atomic` is fine where one word is enough. A database transaction sits outside
  any crypto lock, the same ordering as knit-next's `rules/mesh.md`.

## Storage

- **Database:** GRDB over SQLite, one `knit.sqlite` in a directory of its own, with file protection
  `completeUntilFirstUserAuthentication` (the mesh runs while the phone is locked), excluded from backups
  (ADR 2026-09.nyya).
- **Schema:** an append-only list of literal SQL migrations; v1 to v3 are frozen, v3 adding groups and the
  status lines' `kind`. Every table is `STRICT` and every string is a UTF-8 `BLOB`, because GRDB cuts a bound
  `String` at its first NUL.
- **Errors:** a SQL store answers as if nothing were there and reports the error to the closure the app hands
  `KnitDatabase`, because the store protocols cannot throw.
- **Keys:** the Keychain, as `…AfterFirstUnlockThisDeviceOnly`. A reinstall finds them and keeps the identity,
  and onboarding republishes its profile (ADR 2026-09.tkww).
- **SQLCipher** waits until there is a reason beyond iOS's own file protection.
- **The Linux peer** uses the in-memory stores. The store contract tests run against both.

## Dependencies

- **Shipped:** swift-crypto and GRDB.swift.
- **Pinned:** `Package.resolved` is committed, and CI builds with `--only-use-versions-from-resolved-file`.
- **Tracked:** `RepoConventionTests.NoticesSyncTests` fails until every resolved package has a row in
  `THIRD-PARTY-NOTICES.md`.
- **The permissive-license rule** covers what ships in the app. knit-peer links libdbus (AFL-2.1 or
  GPL-2.0-or-later), which is fine for a tool that is never distributed.
