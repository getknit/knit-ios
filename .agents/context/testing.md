# Testing

Most of Knit's behaviour is protocol logic, and that runs on Linux. Hardware is the last step of the
ladder, not the first.

## The ladder

1. **Swift Testing on Linux.** Every platform-free target has a test target, and the whole suite runs
   under `swift test`, TSan and ASan. Use `@Test` and `#expect`/`#require`; XCTest is disabled
   (`--disable-xctest`) so each target writes one xUnit report. TSan sometimes reports an access race inside a
   `Mutex.withLock` body, most often in `CustodyStoreTests.concurrentStoresAndSweepsLeaveAConsistentSet` (10 of
   15 runs on its own): it cannot see `Synchronization.Mutex`'s futex on Linux, only the pthread calls it
   intercepts. It is a false positive, and the maintainer chose on 2026-09-26 to live with it for now; rerun
   the gate. The fix, a pthread-backed lock, is on the roadmap's deferred list.
2. **Golden and known-answer vectors.** knit-next's `vectors/` (the 57 codec fixtures, and keyed vectors:
   identities, signed frames, a sealed DM, the safety number, the link records and an advert), its node id,
   alias and card goldens, and the RFC 7748, 8032, 5869 and 9180 vectors. The other direction runs too:
   `EmittedVectorTests` writes frames this port signs, and knit-next's `IosEmittedVectorTest` verifies them
   with Tink and re-encodes them with kotlinx. Signatures are verified, never compared: CryptoKit
   randomizes Ed25519 signatures and swift-crypto on Linux does not.
3. **The engine and the link layer, one node at a time.** `MeshEngine` and `LinkManager` are synchronous
   (ADR 2026-09.gq84), so a test hands one a `ManualClock`, a `RecordingTransport` or a `FakeRadio`, feeds it
   frames signed by fixed `TestPeer` keys, and moves the clock itself to fire timers. `MeshTests` drives the
   `Mesh` actor the same way and awaits the fake radio's activity stream. Nothing sleeps.
4. **The mesh lab: deferred.** Multi-node scenarios with `assertConverged`, and seeded chaos, were skipped
   for now at the maintainer's call (`.agents/memory/roadmap.md`). The synchronous engine is what would let
   a later lab run deterministically from a seed.
5. **Fuzzing.** Every parser that reads bytes off the radio has a libFuzzer harness in `Fuzz/`. A crash is
   a finding by construction; its input joins the corpus once the fix lands.
6. **The Linux peer, without a radio.** `KnitBlueZTests` runs the BlueZ radio against a fake BlueZ on a
   peer-to-peer libdbus server, with Unix `SOCK_SEQPACKET` sockets in place of L2CAP, so the whole radio runs
   in CI with no adapter and no bus daemon. The fake also plays remote devices' GATT servers, so the GATT
   read runs too. No test opens a Bluetooth socket (`.agents/context/linux-peer.md` says why). `KnitPeerTests` drives the control surface through a real `Mesh`, with a second engine signing
   the far side's frames.
7. **Over the air, from Linux (P4).** `knit-peer` on `hci1` against Android phones running Knit: checklist
   L, through `scripts/interop.py`. Obey `.agents/rules/devices.md` before touching a phone.
8. **The Mac (P7).** The full suite on macOS, the `KnitBLE` delegate tests, Simulator XCUITest with
   `performAccessibilityAudit`, and a native Mac run against Android and the Linux peer: checklist M.
9. **The iPhone (P8).** The MVP checklist in `.agents/specs/mvp.md`.

## Coverage

`scripts/coverage-gate.py` compares each target's line coverage with its floor in
`scripts/coverage-floors.json`.

- **Floors only ratchet up.** A stub with no executable lines passes, and a target with lines but no floor
  fails, so every target gets its floor on purpose.
- **Floors by phase exit:** Wire 95, Crypto 90, Mesh 85, Store 85 and AppCore 80.
- **Why the script runs `llvm-cov` itself:** Swift Build runs each test target as its own binary, and
  `swift test --show-codecov-path` exports coverage for only some of them. The script passes every test
  binary to `llvm-cov export`.

## Conventions

- **Repo conventions are tests.** `RepoConventionTests` pins `COPYING` to the verbatim GPLv3 and requires a
  `THIRD-PARTY-NOTICES.md` row for every package in `Package.resolved`.
- **Name tests for the behaviour they pin** (`opensTheCFRGBaseModeVector`), and cite the knit-next test or
  constant they mirror in a comment.
- **Malformed input never traps.** A parser test feeds truncated, oversized and wrong-typed input and
  expects an error, never a crash. The fuzzers enforce the same thing at scale.
- **Never `sleep` in a test to wait for something.** Await the event, or drive the injected clock.
- **Store contracts run against every implementation.** `CustodyStoreTests` and `RepositoryTests` take a
  store kind (`memory`, `sql`) as their argument, so a new store joins by adding a case, and passes by
  keeping the rules the memory store keeps. `KnitStoreSQLTests` covers only what the SQL stores add: the
  schema pins, the file and its reopening, and how failures are reported (ADR 2026-09.nyya).
- **Shared fixtures live in `KnitTestSupport`** (`Tests/KnitTestSupport/`): the golden vectors and
  knit-next's `bytes(n, seed)`. It is a plain target, not a product, so xtool never builds it.
- **Parameterized tests over `CBOR` values leak under ASan.** Swift Testing over-retains indirect-enum
  arguments. `scripts/lsan-suppressions.txt` hides exactly those allocations, and a real leak in a test body
  still fails the gate.
