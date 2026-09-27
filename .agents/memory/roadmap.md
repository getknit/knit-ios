# Roadmap

What is in flight, what is next, and what is deferred on purpose. **Don't start a deferred item without
explicit direction.** Update this file in the change that ships an item.

## In flight

- **The MVP** (`.agents/specs/mvp.md`). P0 is nearly done: the repo, the gates and CI are in place,
  spikes (a), (b), (c), (d) and (f) passed, and the GitLab project `knit/knit-ios` exists with its
  `knit-local` runner registered and online. Spike (e) passed against the Pixel 3: Android finds the BlueZ
  advert, dials the LE CoC listener and completes the two-way HELLO, and the advert comes back after each
  link (`.agents/context/linux-peer.md`). Still owed: the first push.
- **P1, the wire (`KnitWire`):** the CBOR codec, every MVP wire type, link records, HELLO, DIGEST, the advert
  and the id and text rules are in. All 57 knit-next golden vectors round-trip, and 33 typed fixtures
  encode to Kotlin's exact bytes. Line coverage is 98 %, and each of the three libFuzzer harnesses ran ten
  minutes clean on 2026-09-25. Done.
- **P2, crypto and identity (`KnitCrypto`):** bundles, node ids, identity keys and their store, signing,
  v1 DM seal and open, the safety number, aliases and the device tag are in, with the RFC vectors and every
  knit-next golden. Line coverage is 97 %. A2's keyed vectors pass, the safety number among them, and
  knit-next verifies and opens the frames this port emits. Done: A2 merged, and the vectors are pinned to
  knit-next `aeba5382` (2026-09-26; nothing they hold moved since `1f3befcd`).
- **P3, the mesh engine (`KnitMesh`, `KnitStore`):** done on 2026-09-25, pending the maintainer's review.
  - **Link layer:** the `LinkManager` behind a `Radio` protocol, with A1's admission rules (ADR 2026-09.6es2).
  - **Router and custody:** flooding and custody under Android's quotas, with the rules in one `CustodyRules`
    the SQL store will share (ADR 2026-09.p6nb).
  - **The rest of the engine:** profiles, room ticks and DM receipts, key recovery with parking, message
    requests, and the pending-key outbox.
  - **Engine and driver:** the engine is synchronous behind one `Mesh` actor (ADR 2026-09.gq84), and wire ids
    key every map by their bytes (ADR 2026-09.jc2x).
  - **Tests:** the MVP cases of knit-next's `MeshRouterTest`, `ForwardSyncTest`, `ForwardRepositoryTest`,
    `ForwardDaoTest`, `AckSyncTest`, `KeyExchangeTest` and `PendingInboundTest` are ported. Line coverage is
    100 % in both targets, and the suite is clean under TSan and ASan.
  - **Still owed:** the mesh lab, deferred below; P3's exit is these gates instead.
- **P4, the Linux peer (`KnitBlueZ`, `KnitPeer`, `knit-peer`):** built on 2026-09-25 (ADR 2026-09.5ftc).
  - **The radio:** BlueZ over libdbus on one `poll` thread, with the advert, the scan and LE CoC sockets on
    `hci1` only. The `ios` profile serves the GATT payload (ADR 2026-09.xzpt).
  - **The peer:** JSON-lines control, `deny-link`, `keygen` windows and `scan`. `scripts/interop.py` drives
    checklist L through knit-next's debug bridge.
  - **Tests:** a fake BlueZ on a peer-to-peer bus and Unix sockets run the whole radio in CI. Coverage is 90 %
    in `KnitBlueZ` and 99 % in `KnitPeer`, and both suites are clean under TSan and ASan.
  - **Checklist L so far** (the Pixel 3, `.agents/context/linux-peer.md` has the runs):
    - **`android` profile against Android 2.7:** 12 of 12 in both dial orders, and 14 of 14 with a blank peer
      name and a photo on the Pixel. That covers alias parity both ways and FILE records tolerated (the avatar's
      3 records discarded, the link kept).
    - **`ios` profile against Android 2.7:** the refusal reproduces (`interop.py refusal`).
    - **`ios` profile against A1:** on the reviewed branch, 14 of 14 below the Pixel's id and 13 of 13 above it,
      and the stale-link replacement held (`interop.py replace`, 9 of 9). On merged `main`, 13 of 13 in each
      order, and the 30 s hold refused early second dials and then let one replace the link; the two-process
      rig's shared ACL still drops some runs afterwards (`.agents/context/linux-peer.md`).
  - **Found on the way:** bluetoothd holds every LE link after its channels close, which blocked the advert; the
    radio now releases links itself. The `ios` profile no longer re-registers its advert when only the digest
    cue moves (`.agents/context/linux-peer.md`, "What P4 found").
    - **The Moto G on merged A1:** admitted in both orders, but it lost everything the peer sent after the profile
      in 3 of 3 checks with 8192-byte SDUs, and passed with `--send-mtu 247`, so the radio now writes 247-byte
      SDUs by default (the maintainer, 2026-09-26). The iPhone reads those, and writes 2,570-byte SDUs.
  - **Custody convergence:** a newcomer took ten minutes to converge on a stranger's backlog, on both platforms.
    knit-next's fix (ADR 2026-09.9xuu) serves profiles first and parks a whole custody quota per sender;
    `CustodySync` and `PendingInbound` mirror it. It merged unchanged as `aeba5382` on 2026-09-26, and the pin
    moved there. Done.
  - **The relay line (2026-09-26):** rehearsed with a second peer on `hci0`, shared (`--shared-adapter`), on the
    maintainer's go-ahead. `interop.py relay` passed 16 of 16: posts and DMs crossed peer A both ways, and the three
    custody sets converged (`.agents/context/linux-peer.md`, "What the relay line showed").
  - **The soak (2026-09-26):** `scripts/soak.py` ran 8.1 hours against the four lab phones in range, driving
    none of them. The peer's `status` now reports the size of each in-memory table, so the run could show them
    level off.
    - **Passed:** no crash, memory flat after the first hour, custody and the SeenSet bounded, and every post
      ticked and every DM delivered.
    - **Found:** bluetoothd cut 127 of 213 links, 30 s after a phone rotated its address
      (`.agents/context/linux-peer.md`, "What the soak found"). Ticks were slower than the MVP's 5 s.
    - **Room traffic both ways (2026-09-26):** `interop.py soak --extras` ran MVP item 11's hour against the Pixel
      3 and passed 11 of 12. There was no drop, crash or growth on our side, and reactions, typing cues, photos
      and DMs were handled. The miss was 21 room ticks lost when the Pixel's controller ended two links
      (`.agents/context/linux-peer.md`, "What the both-ways soak showed").
    - **`TemporaryTimeout = 0`:** set on 2026-09-26. The radio now forgets quiet devices itself, since bluetoothd
      no longer does and the pile power-cycled both adapters through the desktop's Bluetooth applet. A night
      rerun started that evening, `.build/soak/current`.
  - **The GATT read (2026-09-26):** in the `ios` profile the peer reads the payload of a UUID-only advert and sets
    `FLAG_DIALS_GATT_PEERS`, so it can dial an iPhone. It reads on rules in `KnitMesh`'s `GattPayloads`, which
    KnitBLE will share (ADR 2026-09.xzpt, amended). Only the fake BlueZ has served it a payload so far; the first
    real one will be the Mac's or the iPhone's.
- **P5, the store (`KnitStoreSQL`):** built on 2026-09-26 (ADR 2026-09.nyya).
  - **The stores:** every `KnitStore` protocol on GRDB 7.11.1: custody, peers, messages, accepted
    conversations and our own profile, in one `knit.sqlite` under Data Protection and out of backups.
  - **Schema v1 is frozen:** literal SQL, `STRICT` tables, and every string a UTF-8 `BLOB`, because GRDB cuts
    a bound `String` at its first NUL. `SchemaTests` pins the migrations and the schema each leaves.
  - **Found on the way:** `CustodyRules` removed evicted ids through a `Set<String>` and matched groups with
    `==`, so ids Swift calls equal could change what the overall trim kept. Both now compare by bytes.
  - **Tests:** the custody and repository contract suites run against the memory and SQL stores alike. Line
    coverage is 99 %. The SQL stores are not wired into anything yet: the app composes them in P6.
  - **Still owed:** checking the backup flag on the Mac (P7) and the protection class on the iPhone (P8).
- **P6, the app (`KnitAppCore`, `Knit`, `KnitBLE`):** begun on 2026-09-26.
  - **`KnitAppCore`:** one `AppSession` over the mesh, and a view model for every MVP screen: onboarding, the
    chat list and its status line, a thread with its composer, message requests, both profiles, Settings,
    About and Diagnostics. Diagnostics shows per-peer clock skew, and in a debug build mints an identity inside
    a node id window. The notification policy lives here too, with Android's collision-aware labels
    (`PeerLabelIndex`) and `-seedDemo`'s seed and radio. Line coverage is 99 %.
  - **The copy catalog:** every string in `Copy`, through `product-language-editor` and `humanizer` (ADR
    2026-09.ycza).
  - **`Knit`:** the SwiftUI screens, the Keychain key store (a reinstall keeps its identity, ADR 2026-09.tkww),
    local notifications, the unified log and the composition root, with `-seedDemo`.
  - **`KnitBLE`:** the CoreBluetooth radio, with GATT reads on `GattPayloads`' rules.
  - **The mesh for the app:** it reports the radio's state, stops and starts again on the same radio, marks a
    peer verified, and stores list each thread's newest message.
  - **Still owed:** no unread counts yet, and no block, delete or Sign out. The Mac (P7) still owes the UI tests
    and the accessibility audit.
- **P8, the iPhone:** begun early on 2026-09-26, without the Mac: an iPhone 12 on iOS 27.0, installed over USB
  by xtool on free provisioning. The app runs and links the Linux peer and the lab's Android phones. Against
  the peer, items 3 to 5 pass: safety numbers match, the room works both ways with ticks, and DMs go request,
  accept, reply, delivered. Items 3 to 5 pass against the Pixel 3 too, with Android sending the first DM and the
  iPhone accepting it. Item 8 passes in both orders (`.agents/context/linux-peer.md`, "What the iPhone
  showed").
  - **Fixed on the way:** the linker dropped KnitBLE's delegates (`-ObjC`); a relaunch to restore Bluetooth never
    scanned; the debug log went unrelayed; a back-fill posted a notification per message; a GATT payload was
    read again every few seconds; a relaunch's restored connections were cancelled before the central was
    powered on, which CoreBluetooth refused, and a dial to a phone they held hung until Stop and Start.
  - **The debug bridge (ADR 2026-09.kwa8):** a debug build answers `knit-peer`'s control protocol over USB, so
    `scripts/interop.py iphone` runs items 2 to 6 against an Android phone with no one at the iPhone, once Knit
    is open on it.
  - **The rig for iPhone runs:** the Linux peer on a shared `hci0`, since `hci1`'s 23-byte fragments stall the
    iPhone, and bluetoothd without its battery plugin, which asked the iPhone to pair.
  - **Still owed:** relay (item 7), the wake test (item 9), the scan-filter check, and the soak. Items 2 to 6
    pass against the Pixel 3 through the bridge, unattended (`.agents/context/linux-peer.md`).
- **Companion change A1 in knit-next:** the responder accepts a dialer it never sighted (knit-next ADR
  2026-09.shzv). Merged on 2026-09-25 as `05dc2be1`, with a 30 s floor before a held link is replaced and the
  −90 dBm score kept for peers never sighted during the link; `LinkManager` follows both (ADR 2026-09.6es2).
  Done.
- **Companion change A2 in knit-next:** merged on 2026-09-25 as `0c0756f6` and `1f3befcd`. Done.

## Next, after the MVP

- **DM forward secrecy:** the v2/v3 epoch ratchet, with `CAP_RATCHET`, `CAP_CRYPTO_V3` and `CAP_INLINE_ACK`,
  and sealed receipts, reactions and profile updates. It comes before any public build. Keyed vectors come
  first (`.agents/context/crypto.md`).
- **Contacts:** QR verification in person, and contact links at a distance (`docs/CONTACT_CARD.md` in
  knit-next).
- **Companion change A3:** Android finds and dials iPhones.

## Deferred by design

- **A lock TSan can see.** TSan on Linux reports false races inside `Synchronization.Mutex` bodies, since it
  cannot see the futex (`.agents/context/testing.md`). The fix is a pthread-backed lock beside `Mutex` and a
  change to `.agents/rules/coding.md`; the maintainer chose on 2026-09-26 to live with the flake for now.

- **The mesh lab:** multi-node scenarios over a lab transport and radio, `assertConverged`, seeded chaos runs
  and the mesh-lab-reviewer persona. The maintainer asked on 2026-09-25 to skip it for now, so P3 closed on
  unit tests, coverage and both sanitizers. Because the engine is synchronous, a later lab could run
  deterministically from a seed (ADR 2026-09.gq84).

- **Message features:** avatars, attachments, reactions, replies, mentions and typing indicators.
- **Groups,** with group keys and roster rules.
- **Search, drafts and backups.**
- **Moderation, block and report.** App Store rule 1.2 requires them before a store build.
- **App Store readiness:** the privacy manifest, the export-compliance answers and the review notes. The
  GPL exception is already in place.
- **Background discovery,** once P8 shows what iOS allows.
- **Never on iOS:** Wi-Fi Aware, the BLE side channel, spool relays and commons, LoRa, and Wi-Fi Direct.
  These are ADR-recorded scope decisions, not a backlog.
