# Roadmap

What is in flight, what is next, and what is deferred on purpose. **Don't start a deferred item without
explicit direction.** Update this file in the change that ships an item.

## In flight

- **The MVP** (`.agents/specs/mvp.md`). P0 is done: the repo, the gates and CI are in place, spikes (a),
  (b), (c), (d) and (f) passed, and `main` is pushed to the GitLab project `knit/knit-ios`, whose
  `knit-local` runner is registered and online. Spike (e) passed against the Pixel 3: Android finds the BlueZ
  advert, dials the LE CoC listener and completes the two-way HELLO, and the advert comes back after each
  link (`.agents/context/linux-peer.md`).
- **P1, the wire (`KnitWire`):** the CBOR codec, every MVP wire type, link records, HELLO, DIGEST, the advert
  and the id and text rules are in. All 57 knit-next golden vectors round-trip, and 33 typed fixtures
  encode to Kotlin's exact bytes. Line coverage is 98 %, and each of the three libFuzzer harnesses ran ten
  minutes clean on 2026-09-25. Done.
- **P2, crypto and identity (`KnitCrypto`):** bundles, node ids, identity keys and their store, signing,
  v1 DM seal and open, the safety number, aliases and the device tag are in, with the RFC vectors and every
  knit-next golden. Line coverage is 97 %. A2's keyed vectors pass, the safety number among them, and
  knit-next verifies and opens the frames this port emits. Done: A2 merged, and the vectors are pinned to
  knit-next `a87d2255` (2026-09-30; nothing they hold moved since `1f3befcd`).
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
  - **A backlog whose key the carrier lost (2026-09-27):** in `android-rings` the Pixel 3 served 81 frames a fresh
    peer could not read, because it no longer held a signed copy of their senders' profiles. knit-next's fix (ADR
    2026-09.g64k) keeps the signed frame each pin came from and sends a sender's key ahead of their backlog. This
    port mirrors it in schema v2, `KeyExchange` and `CustodySync`. Against the Pixel 3 on that build,
    `android-rings` now converges custody first, and it passed 10 of 10 with all 796 live ids held in 501 s
    (`.agents/context/linux-peer.md`, "What the carrier's kept keys showed"). The fix merged as knit-next
    `06f2040e` (2026-09-27), matching the mirror. It is on knit-next's `origin/main`, and the pin moved past it on
    2026-09-28.
  - **Digests queue behind a back-fill (2026-09-27):** a post the Pixel 3 sent once custody matched took 6.5
    minutes to reach the peer on `hci1`. It was not lost. It waited behind about ten 20 KB digests the Pixel
    had queued during the 9-minute back-fill, since both platforms then queued a digest every 60 s whatever
    was already queued (`.agents/context/linux-peer.md`, "Why the frames were late"). Both now keep at most
    one digest waiting per link (knit-next's ADR 2026-09.tjfb, this port's ADR 2026-09.3ch7), which took the
    Pixel's post from 393 s to 133 s. knit-next's side merged as `11b91371` (2026-09-27), is on its
    `origin/main`, and the pin moved past it on 2026-09-28. Open: what the socket already holds, which the slot
    cannot reach; shallow paced writes or a smaller digest record would close it.
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
  - **The backup flag holds on the Mac:** `theDirectoryIsExcludedFromBackups` checks it on Darwin, and passed in
    `test:macos` (pipeline 813, 2026-09-28).
  - **The protection class holds on the iPhone:** the database's directory and files are all
    `completeUntilFirstUserAuthentication` (`interop.py iphone-reboot`, 2026-09-28).
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
  - **Still owed:** no unread counts yet, and no block, delete or Sign out.
- **P7, the Mac:** begun on 2026-09-27. `mac.example` has Xcode 27.0 and the tools, `check.sh fast` passes
  there, and the `macos` runner is online (`.agents/context/toolchain.md`, "The Mac Mini"). XcodeGen
  generates the app project (ADR 2026-09.de8f), which builds for the iPhone and the Simulator in
  `build:ios:xcode` and runs in the Simulator. The Mac signs in its desktop session through a launchd job, so
  ssh and CI can sign and renew the free profile (ADR 2026-09.zawh): `check.sh device` and the
  `build:ios:signed` job build a signed iPhone app. The `mac-docker-runner` runner takes untagged Linux jobs on
  arm64 beside linux-host and service (2026-09-28, `toolchain.md`).
  - **Tests (2026-09-28):** `test:macos` runs the whole suite on the Mac, where `KnitBLETests` runs `L2CAPLink`
    over bound stream pairs. `test:ios:simulator` walks every MVP screen through the accessibility audit, at the
    default and the largest text size, and all 7 walks pass (ADR 2026-09.jcdx). The audit's first run found over a
    hundred issues. Fixing them gave the app a WCAG AA palette, opaque bars under text, and rows and onboarding that
    rearrange at the accessibility sizes. MVP item 12's audit half is met.
  - **Installing from the Mac (2026-09-28):** `check.sh device`, then `devicectl` installs and launches the signed
    `.dev` build on the iPhone 12, and its debug bridge answers `interop.py` as the xtool build's did.
  - **Checklist M (2026-09-28):** `knit-peer` runs on the Mac on KnitBLE's CoreBluetooth radio, in the desktop
    session (ADR 2026-09.vcdk). Against the Pixel 3, `check --mac` passed 13 of 13 below its id and 14 of 14 above
    it, with alias parity and FILE records, and the hour's `soak --mac --extras` passed 11 of 12. The miss was
    custody at the end, the Pixel's quota case that takes up to 11 minutes (`.agents/context/linux-peer.md`,
    "What the Mac showed"). Checklist M's `android` group cannot run as written: a Mac, like an iPhone, has no
    service-data advert, so every run is the `ios` profile against A1.
  - **xtool retired (2026-09-28):** every iPhone build now comes from the Mac, and `verify:periphery` moved
    to the `macos` runner, still advisory (ADR 2026-09.fkqb).
  - **Periphery blocks (2026-09-28):** on the Mac, over the iPhone build's index too, and on Linux for
    `KnitBlueZ` (ADR 2026-09.xgtz).
  - **CI's first run of `test:macos` and `test:ios:simulator`** passed on the push of `76d98fd` (pipeline 813,
    2026-09-28).
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
  - **Relay (item 7):** passes through the iPhone. `scripts/interop.py iphone-relay` ran the line twice, with
    the Pixel 3, then the iPhone, then a peer on `hci0` that refused the Pixel 3. It passed 17 of 17 both times:
    posts and DMs crossed the iPhone both ways, and the three custody sets converged.
  - **Background (item 9):** L2CAP data does not wake a suspended Knit. With the iPhone locked, the link to the
    Pixel 3 held for 14 minutes and none of ten DMs arrived. All ten arrived within a second of Knit opening,
    which is the item's fallback. A write to a GATT doorbell does wake it (ADR 2026-09.khjj): tried by hand, a
    locked iPhone took the peer's DM 4.8 s after a ring. `LinkManager` now rings after frames, and the Linux peer
    rings. Item 9 passes against it: `iphone-wake --sender peer` passed 9 of 9, with every DM of ten minutes
    locked read within 0.5 s and notified. Against Android it passes with A4: `iphone-wake --sender phone
    --expect-wakes` passed 10 of 10 against the Pixel 3, and a phone without A4 falls back.
  - **Scan filter:** a scan filtered on `0xFE30` matches Android's advert, which has no UUID list, with Knit open
    and with the iPhone locked (`scripts/interop.py iphone-scan`). Locked, it found new peers in 30 to 120 s, but
    each match woke Knit, which then ran three quarters of the time among five Android phones, so Knit keeps its
    scan unfiltered. Android needs no UUID list for A3.
  - **The background copy (2026-09-28):** onboarding, the chat list and Settings now say that Knit stays linked in
    the background and that messages from some phones wait until it is next open. They used to say open links keep
    working there, which holds only for a phone that rings.
  - **The soak (item 11, 2026-09-28):** `scripts/interop.py iphone-soak --peer --extras` ran the hour on the iPhone,
    in `iphone-relay`'s line with the Pixel 3 and a peer on a shared `hci0`, so every post crossed both of the
    iPhone's links. It reads the iPhone's log through `idevicesyslog` for why each link ended, and its crash and
    jetsam reports, and the bridge's `status` now reports Knit's memory headroom. It passed 21 of 27: no crash, no
    link ended by the iPhone or the peer, every post delivered and ticked, and the tables and memory level. None
    of the misses was the iPhone's. Custody never matched because of a receipt that arrives before its DM, which
    both platforms leave (below, "A receipt ahead of its DM"). The Pixel's own room retention trimmed the peer's
    posts, which the run now avoids, and a check asked for FILE records the phone did not send
    (`.agents/context/linux-peer.md`, "What the iPhone's soak showed").
  - **Identity (item 1, 2026-09-28):** the identity survives a relaunch and a reboot. `scripts/interop.py
    iphone-reboot` reads a new bridge reply, `storage`, for the node id, the Keychain item's class, the database's
    protection class, and how the launch went. Knit now also starts when it comes to the front while it still waits
    for the first unlock, in case iOS suspended a launch from before the unlock by the time protected data arrived.
    With a passcode set, the reboot passed 12 of 12. iOS did not launch Knit before the first unlock, though without a
    passcode it had, 20.5 s after the boot. It launched Knit in the background 8.4 s after the unlock, and that launch
    read its keys at once. The launch that waits for the first unlock has still not run on a phone, and its stages
    have no test (`.agents/context/linux-peer.md`, "What the iPhone's reboot showed"). Item 1 passes.
  - **Status (item 10, 2026-09-28):** passes on the iPhone 12, checked by hand against the bridge's `status` and the
    radio states in the iPhone's log. The line counted the links the bridge reported, and Stop mesh and Start mesh in
    Settings stopped the mesh and brought all three links back in 16 s. Bluetooth off and Bluetooth refused each
    showed its own line, and the refusal's Settings button opened Knit's page. iOS ends Knit's process when the
    permission is taken away and again when it is given back. The unsupported device's line is checked in
    `test:ios:simulator` (`.agents/context/linux-peer.md`, "What the iPhone's status line showed").
  - **Device UI tests (2026-09-29):** `KnitDeviceTests` runs XCUITest on the iPhone from the Mac (`scripts/check.sh
    devicetest`, ADR 2026-09.63em), with Knit launched live and the Settings app and SpringBoard driven beside it. It
    checks item 10 without anyone at the phone: Stop and Start, Bluetooth off and on, and the permission refused and
    given back. It also covers onboarding's prompt and a relaunch for item 1. It passed 5 of 5 twice in a row, about
    3.5 minutes of tests in a 6-minute run. The Mac's command line could not make the runner's profile, since it
    finds no account, so Xcode's window made it (ADR 2026-09.zawh, amended).
  - **Both id orders and the peer (items 2 to 6, 2026-09-29):** `interop.py iphone` passed 20 of 20 against the
    Pixel 7, whose id sorts below the iPhone's, and 17 of 17 against the Pixel 3, above it. The Pixel 7 had never
    talked to the iPhone, so the run read the iPhone's first DM off its Requests screen and tapped Accept there.
    `interop.py iphone-peer` ran the same items against a fresh peer on a shared `hci0`, and passed 18 of 20 in each
    order. Both misses were custody, on one DM the iPhone took before the early-receipt fix (below). Item 6 now runs
    both ways. The phones linked again in 13.8 and 16.7 s, but against the peer three of ten first links and one of
    three relinks took 30.5 to 54.7 s: the iPhone hears the peer's BlueZ advert late and seldom, and dials at the
    first sighting after the 12 s dwell (`.agents/context/linux-peer.md`, "What both id orders showed").
  - **Still owed:** the soak's rerun (item 11), on the fixed harness with the Pixels on knit-next's early-receipt
    fix, and not before 12:17 on 2026-09-29, when that DM expires. Item 2's first link can run past 30 s, against
    a phone too: three of five to the Pixel 7 did, from gaps between sightings that restart the dwell, and from
    backoff built by dialing a phone that has left (`.agents/context/linux-peer.md`). `LinkManager` now dials when
    a dwell ends and never dials a peer quiet for more than 8 s (ADR 2026-09.6es2, amended 2026-09-29); the Pixel 7
    probe is owed again on a build that has them. The 8 s gap reset is unchanged, and knit-next could take both
    rules later as a paired change. Items 2 to 8 run unattended through the bridge; item 9's test needs someone to
    lock and unlock the iPhone.
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
- **Companion change A3** (knit-next #101): Android finds and dials iPhones. It is the paired change `gatt-peers`, on
  `feat/gatt-peers` in both repos (knit-next ADR 2026-09.kwq2). Android reads the GATT payload of a node that
  advertises only the `0xFE30` UUID, on `GattPayloads`' rules, dials it when its own id sorts higher, and takes a
  dialed link's capabilities from the HELLO reply, so A4 rings it. Then it sets `FLAG_DIALS_GATT_PEERS`, and an
  iPhone below it waits to be dialed. Nothing in `KnitWire`, `KnitMesh` or `KnitBLE` moves: the payload, the flag and
  `weDial` were already law here. This side owns the device checks: `interop.py android-reads` is the gate, against
  the Pixel 7 (API 37) and the Pixel 3 (API 31, the pre-33 read callback) with the flag clear and again with it set,
  and then `iphone` in both orders and `iphone-wake` with the Pixel 3. knit-peer gained two test switches for them, `--never-sight` and
  `--no-gatt-payload`. The gate passed on 2026-09-29, after the payload lifetime's two new forget rules became
  shared law (ADR 2026-09.xzpt, amended), and the flag build (`8a6d1a58`) passed `android-reads`, `iphone` in both
  orders and `iphone-wake` (`.agents/context/linux-peer.md`, "What A3's flag showed"). knit-next merged it as
  `f3f9cb9d`, which is the pin. Done.
- **Companion change A4:** Android rings an iPhone's doorbell (ADR 2026-09.khjj) after the frames it writes on the
  iPhone's link, on `LinkManager`'s schedule: a GATT write without response over the link's own connection, once
  service discovery finds the doorbell. Built as knit-next `c3191717` (its ADR 2026-09.dqvb), for a peer whose
  HELLO carries `CAP_DOORBELL` (`0x1000`); it is pushed to knit-next's `main`, and in the pin. This port sends
  the bit whenever its radio serves the doorbell, and rings nothing for `typing`, `blobreq` and `keyreq`, as
  Android does. On 2026-09-27 `scripts/interop.py android-rings` passed against the Pixel 3, and so did
  `iphone-wake --sender phone --expect-wakes`, with every DM of ten locked minutes waking Knit. Still owed: the
  link-up drops that run found. Twice in three links the iPhone read a record tag outside 1..7 while the Pixel was
  still looking up its doorbell, and dropped the link. A snoop log on the Pixel did not catch one in 19 more
  relinks, and showed the Pixel keeping every L2CAP frame whole (`.agents/context/linux-peer.md`, "What A4
  showed"). A bad record's warning now carries what the link read around it, so the next one can be read from the
  iPhone's log. Android rings only links the iPhone dialed until A3, which must then take a dialed iPhone's
  capabilities from its HELLO reply rather than its advert.
- **An iPhone's links run on a 720 ms supervision timeout** (knit-next #102): iOS sets it as the central, and Android's
  stack puts it back after the doorbell lookup briefly raises it to 5 s. One dropped at about 10 m in the walk test
  (`.agents/context/linux-peer.md`, "What the walk test showed"). The fix is on Android's side: knit-next `82898694`
  (2026-09-29, in the pin) looks the doorbell up at link-up and asks for `CONNECTION_PRIORITY_BALANCED`, whose timeout
  is 5 s. The stack's put-back could land after that ask and win, 720 ms from an iPhone and 420 ms from BlueZ, so
  `3e566b1f` and `fe2eeed6` (2026-09-30, in the pin) ask again, and every link in forty ended at 5 s
  (`.agents/context/linux-peer.md`, "What the put-back race showed"). Still owed: knit-next's push, and the walk
  again with Wi-Fi Aware off on the Pixels, checking that the snoop shows the 5 s update after `bt doorbell found`
  and none back to 720 ms, and comparing the ranges.
- **Two iPhones both ways:** an iPhone rings only the peers it dialed, so of two iPhones the one with the smaller id
  cannot wake the other. A second GATT connection toward its dialer would let it; nothing needs it before two
  iPhones are on hand.
- **A receipt ahead of its DM** (knit-next #100): a receipt that arrived before the DM it acknowledges purged
  nothing, on both platforms, so the DM was carried to its expiry and offered at every exchange to neighbours that
  refused it. Back-fill's newest-first order makes it common, and so does the recipient, which sends its receipt at
  once and relays the DM after the jitter. It kept custody from matching in `iphone-soak` on 2026-09-28. knit-next
  now remembers each receipt with its sender for the tombstone's 24 h and refuses the DM on arrival when it is
  addressed to that sender (its ADR 2026-09.adpz). `CustodySync` mirrors it (2026-09-28,
  `.agents/context/custody.md`). It merged unchanged as `2efea24a`, now on knit-next's `origin/main`, and the pin
  moved past it. Still owed: an `iphone-soak` rerun with a Pixel build that holds it, whose custody
  checks should then pass. The fix refuses such a DM on arrival and purges no copy already held, and the iPhone
  holds one from 12:17 on 2026-09-28, with its receipt, which every fresh node refuses. Custody checks against the
  iPhone miss it until it expires, at 12:17 on 2026-09-29 (`.agents/context/linux-peer.md`, "What both id orders
  showed").

## Deferred by design

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
- **Background discovery:** a locked iPhone's scan filtered on `0xFE30` finds Android phones and other Knit peers,
  in 30 to 120 s, but wakes Knit for every match (P8's scan-filter check, `.agents/context/linux-peer.md`). It
  needs a design that bounds the wakes, such as filtering only while Knit has too few links. It will also meet a
  limit A3 leaves: an Android phone that sets `FLAG_DIALS_GATT_PEERS` cannot see a backgrounded iPhone, whose UUID
  sits in Apple's overflow area, so a backgrounded iPhone whose id sorts below the phone's waits for a dial that
  cannot come. Today that costs nothing, since a backgrounded iPhone's unfiltered scan finds no new peers either.
  Once background discovery lands, `weDial` must ignore a service-data peer's flag while Knit is in the background.
- **An iPhone below a flagged Android phone waits for its dial,** the iPhone's twin of knit-next #103, and stays open
  as a later Track A item: #103 lets only a lonely Android phone dial a peer above it.
- **Never on iOS:** Wi-Fi Aware, the BLE side channel, spool relays and commons, LoRa, and Wi-Fi Direct.
  These are ADR-recorded scope decisions, not a backlog.
