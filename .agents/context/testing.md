# Testing

Most of Knit's behaviour is protocol logic, and that runs on Linux. Hardware is the last step of the
ladder, not the first.

## The ladder

1. **Swift Testing on Linux.** Every platform-free target has a test target, and the whole suite runs
   under `swift test`, TSan and ASan. Use `@Test` and `#expect`/`#require`; XCTest is disabled
   (`--disable-xctest`) so each target writes one xUnit report. Locks are `KnitSync`'s `Lock`, which TSan
   can see (ADR 2026-09.ahrr), so a TSan report is a real race: fix it, never rerun the gate until it passes.
2. **Golden and known-answer vectors.** knit-next's `vectors/` (the 61 codec fixtures, and keyed vectors:
   identities, signed frames, a sealed DM, the safety number, the link records and an advert), its node id,
   alias and card goldens, and the RFC 7748, 8032, 5869 and 9180 vectors. The other direction runs too:
   `EmittedVectorTests` writes frames this port signs, and knit-next's `IosEmittedVectorTest` verifies them
   with Tink and re-encodes them with kotlinx. Signatures are verified, never compared: CryptoKit
   randomizes Ed25519 signatures and swift-crypto on Linux does not.
3. **The engine and the link layer, one node at a time.** `MeshEngine` and `LinkManager` are synchronous
   (ADR 2026-09.gq84), so a test hands one a `ManualClock`, a `RecordingTransport` or a `FakeRadio`, feeds it
   frames signed by fixed `TestPeer` keys, and moves the clock itself to fire timers. `MeshTests` drives the
   `Mesh` actor the same way and awaits the fake radio's activity stream. Nothing sleeps.
4. **The app's logic, without a screen.** `KnitAppCoreTests` drives `AppSession` and every view model
   through a `FakeMesh` that writes to in-memory stores as the engine would, and reads every catalog string. A fake
   `ImageCodec` stands in for ImageIO, so choosing, cropping and saving a profile photo run there too, and so do
   picking, holding and sending a photo in a chat (`ChatPhotoTests`). A fake `PhotoClassifier` stands in for Core
   ML, so the content filter's policy, what it hides and what a pick asks run there as well (`PhotoScreeningTests`),
   and so do the words' tokenizer, word list, screening on arrival and refusal on send (`SentencePieceTokenizerTests`,
   `WordFilterTests`, `TextScreeningTests`). The models' own scores are checked on the Mac, against Android's TFLite by
   `tools/models/nsfw/parity.py` and against Detoxify's checkpoint by `tools/models/toxicity/parity.py`.
   `DemoTests` runs the real `Mesh` on `-seedDemo`'s radio, in each scene. The SwiftUI views, the Keychain store and
   `KnitBLE` compile only on Apple platforms: `scripts/check.sh xcode` builds them for iOS, `test:macos` runs
   `KnitBLETests`, and `test:ios:simulator` walks the screens (P7).
5. **The mesh lab: deferred.** Multi-node scenarios with `assertConverged`, and seeded chaos, were skipped
   for now at the maintainer's call (`.agents/memory/roadmap.md`). The synchronous engine is what would let
   a later lab run deterministically from a seed.
6. **Fuzzing.** Every parser that reads bytes off the radio has a libFuzzer harness in `Fuzz/`. A crash is
   a finding by construction; its input joins the corpus once the fix lands.
7. **The Linux peer, without a radio.** `KnitBlueZTests` runs the BlueZ radio against a fake BlueZ on a
   peer-to-peer libdbus server, with Unix `SOCK_SEQPACKET` sockets in place of L2CAP, so the whole radio runs
   in CI with no adapter and no bus daemon. The fake also plays remote devices' GATT servers, so the GATT
   read runs too. No test opens a Bluetooth socket (`.agents/context/linux-peer.md` says why). `KnitPeerTests` drives the control surface through a real `Mesh`, with a second engine signing
   the far side's frames. `KnitControlTests` covers what the app's bridge adds: changing a node through the
   session's actions, `stop` and `start`, and the event lines.
8. **Over the air, from Linux (P4).** `knit-peer` on `hci1` against Android phones running Knit: checklist
   L, through `scripts/interop.py`. Obey `.agents/rules/devices.md` before touching a phone.
9. **The Mac (P7).** `test:macos` runs the whole suite on macOS, where `KnitBLETests` has something to test:
   `L2CAPLink` over bound stream pairs (`Stream.getBoundStreams`) in place of a CoreBluetooth channel, with a far
   end on a stream thread of its own. It covers write order, the 8 KiB cuts, the digest slot, back-pressure and
   both ways a link ends. CoreBluetooth's own delegates need a radio, so the Mac's run and the iPhone's cover
   them. `KnitUITests` walks every MVP screen in the Simulator on `-seedDemo` (`scripts/check.sh uitest`,
   `test:ios:simulator`), each through `performAccessibilityAudit`, once at the default text size and once at the
   largest, where it keeps a screenshot of every screen. The Simulator has no scanner, so the scan walk reaches the
   scanner's refused and failed states through `-demoCamera` (ADR 2026-10.65xx). The system's photo picker runs
   outside Knit, so the photo walks pick a demo photo through `-demoPhoto`, on the `marketing` scene, whose
   people wear faces and whose post by the fire carries a photo (ADR 2026-10.sepc, ADR 2026-10.6cas). The faces and
   photos are files in `App/DemoMedia/`, which only a debug build bundles (ADR 2026-10.2acj). Nothing
   reaches the demo's radio, so the notification walk has `-demoNotification` post the room's notification as Knit
   goes to the background, then taps its banner on the home screen. The tap reaches Knit in the background, as one
   on the lock screen does, which is where Knit used to abort. `AuditPolicy` names what the audit
   may report without failing and why (ADR 2026-09.jcdx); everything else fails the gate. The sources live in `Tests/KnitUITests/`,
   which SwiftPM ignores and XcodeGen builds. CI runs them in a Simulator named "Knit CI", and a run over ssh in
   "Knit local", each made on first use. They used to share one: on 2026-09-28 a local run started while CI's was
   going, its test runner was killed "before establishing connection", and two of CI's tests failed. Checklist M
   runs `knit-peer` on the Mac, on KnitBLE's CoreBluetooth radio, with `interop.py check --mac` and `soak --mac`
   (ADR 2026-09.vcdk).
10. **The iPhone (P8).** The MVP checklist in `.agents/specs/mvp.md`. `scripts/interop.py iphone` drives the
    iPhone through a debug build's bridge, over USB or Wi-Fi, and an Android phone through knit-next's, for items 2 to 6
    (ADR 2026-09.kwa8). `iphone-relay` adds a peer on `hci0` beyond the iPhone for item 7, `iphone-wake`
    runs item 9's wake test, with someone to lock and unlock the iPhone, and `iphone-scan` runs the scan-filter
    check, with the same help. `iphone-reboot` runs item 1's relaunch and reboot through the bridge's `storage`
    reply, which also reports the Keychain item's class and the database's protection class and backup flag, with
    someone to close Knit and unlock the iPhone. `iphone-rings` and `android-rings` check the doorbell's rings each
    way, and `android-reads` checks that an Android phone reads the peer's GATT payload (A3). `KnitDeviceTests` (`scripts/check.sh devicetest`, ADR 2026-09.63em) runs XCUITest on the iPhone from the
    Mac, with Knit launched live and the Settings app and SpringBoard driven beside it: Stop and Start, Bluetooth
    off and on, the permission refused and allowed again, onboarding's prompt, a relaunch, and the camera prompt at a
    profile's Scan their code (`CameraTests`, which needs no radio and leaves Bluetooth as it found it). `PhotoTests`
    chooses, crops and saves our profile photo, a demo photo under `-demoPhoto`, which a debug build honours live too,
    and leaves it set for a look at the lab's phones (ADR 2026-10.sepc). It reads the status
    line's state from its identifier, never its words, and each test puts Bluetooth, the permission and the mesh
    back as it ends, `PhotoTests`' photo apart. `BackgroundTests` is the exception: two steps `interop.py` runs one at a
    time, which bring the Settings app or Knit to the front and never launch, end or restore Knit. They run from an
    xctestrun with Knit left out of the install (`KNIT_DEVICE_KEEP_KNIT`), since installing Knit ends its process and
    its links. Its sources live in `Tests/KnitDeviceTests/`, which only the `KnitDevice` scheme builds.

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
- **Store contracts run against every implementation.** `CustodyStoreTests`, `RepositoryTests` and `BlobStoreTests`
  take a store kind (`memory`, `sql`) as their argument, so a new store joins by adding a case, and passes by
  keeping the rules the memory store keeps. The SQL blob store keeps its bytes in files, so its kind runs in a
  temporary directory of its own. `KnitStoreSQLTests` covers only what the SQL stores add: the
  schema pins, the file and its reopening, and how failures are reported (ADR 2026-09.nyya).
- **Shared fixtures live in `KnitTestSupport`** (`Tests/KnitTestSupport/`): the golden vectors and
  knit-next's `bytes(n, seed)`. It is a plain target, not a product, so the app never links it.
- **Parameterized tests over `CBOR` values leak under ASan.** Swift Testing over-retains indirect-enum
  arguments. `scripts/lsan-suppressions.txt` hides exactly those allocations, and a real leak in a test body
  still fails the gate.
