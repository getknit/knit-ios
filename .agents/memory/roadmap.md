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
  - **The backup flag holds on the Mac:** `theDirectoryIsExcludedFromBackups` checks it on Darwin, and passed
    in `test:macos` (2026-09-28).
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
  - **Block (2026-10-03):** presentation only, as on Android: a blocked person's messages stop at delivery and are
    still carried, relayed and ticked (ADR 2026-10.5wgg).
  - **Delete (2026-10-04):** a message from its bubble's menu, a chat or request from its swipe, and Nearby cleared,
    all local as on Android. Unlike Android, a deleted message is remembered until no carrier can re-serve it, and a
    delete never turns an accepted thread into a request (ADR 2026-10.u7cq).
  - **Reactions (2026-10-04):** six to pick from a bubble's menu, any one emoji shown, in every thread, sent and taken
    in the clear as Android floods them toward a peer without the ratchet (ADR 2026-10.ehe6). Android's full picker
    and its recents row are not ported.
  - **Still owed:** no unread counts yet, and no Sign out.
- **P7, the Mac:** begun on 2026-09-27. The Mac Mini has Xcode 27.0 and the tools, `check.sh fast` passes
  there, and the `macos` runner is online (`.agents/context/toolchain.md`, "The Mac"). XcodeGen
  generates the app project (ADR 2026-09.de8f), which builds for the iPhone and the Simulator in
  `build:ios:xcode` and runs in the Simulator. The Mac signs in its desktop session through a launchd job, so
  ssh and CI can sign and renew the profile (ADR 2026-09.zawh): `check.sh device` and the
  `build:ios:signed` job build a signed iPhone app. A Docker runner on the Mac takes untagged Linux jobs on arm64
  beside the amd64 ones (2026-09-28, `toolchain.md`).
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
  - **CI's first run of `test:macos` and `test:ios:simulator`** passed on the push of `0b44c9f`
    (2026-09-28).
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
  - **The debug bridge (ADR 2026-09.kwa8):** a debug build answers `knit-peer`'s control protocol over USB, and
    over Wi-Fi on a pinned network (ADR 2026-10.dz8d), so `scripts/interop.py iphone` runs items 2 to 6 against
    an Android phone with no one at the iPhone, once Knit is open on it.
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
  - **Still owed:** the soak's rerun (item 11), on the fixed harness with the Pixels on knit-next's early-receipt fix,
    and not before 12:17 on 2026-09-29, when that DM expires. Item 2's first link can run past 30 s, against a phone
    too: three of five to the Pixel 7 did, from gaps between sightings that restart the dwell, and from backoff built by
    dialing a phone that has left (`.agents/context/linux-peer.md`). `LinkManager` now dials when a dwell ends and never
    dials a peer quiet for more than 8 s (ADR 2026-09.6es2, amended 2026-09-29). Both held on 2026-10-01, but the Pixel
    7 probe still passed only four of eight: every slow link came from gaps over 8 s in hearing the phone, which restart
    the dwell, and one dial probably went to a late wake (`.agents/context/linux-peer.md`, "What the dwell fixes
    showed"). A raw scan on the ATS2851 split those gaps between the phones. Most were the Pixel's: its stack drops the
    presence advert when a 15 ms link opens just as the advert comes up (knit-next #112). The rest were the iPhone
    missing adverts the ATS2851 heard. With the Pixel's Meshtastic radio off, 5 of 8 came within 30 s
    (`.agents/context/linux-peer.md`, "What the raw scan showed"). On 2026-10-02, with knit-next's fix for #112 on the
    Pixel and the silence limit raised to 12 s (ADR 2026-09.6es2, amended 2026-10-02), 7 of 8 came within 30 s, still
    with the Meshtastic radio off ("What the 12 s limit showed"). With it on, and knit-next's receiver fix, 6 of 8 came
    within 30 s, and with the Pixel's Coded mode off, as a shipped build has it, both misses were the iPhone's 8 s gap
    reset ("What the Meshtastic radio showed"). Raising that reset to 12 s is the next step for item 2; replayed, it
    gives 7 or 8 of 8. knit-next could take the rules later as a paired change. Items 2 to 8 run unattended through
    the bridge; item 9's test needs someone to lock and unlock the iPhone.
- **Groups (v1), begun 2026-09-30** on `feat/groups`, at the maintainer's direction (ADR 2026-09.n393). This is
  core parity with Android, sealed with v1 and so without forward secrecy:
  - create a group of 2 to 7 contacts;
  - group threads, with Android's status lines;
  - group info, with members, rename and leave;
  - group requests and notifications.

  Out of scope: photos, per-member delivery counts, and Delete chat (which came later, ADR 2026-10.u7cq).
  Capabilities become `0xB` once the screens ship. Two companion changes in knit-next go with it:
  - **A5 (keyed group vectors):** a paired change that iOS leads. knit-next's `keyed-v1.json` gains:
    - a third identity, `dave`, from seeds 7 and 8;
    - `groupIds` known answers;
    - Alice's v1 group chat to Bob and Dave (frame id seed 23);
    - her `groupupdate` (seed 24) and her `groupleave` (seed 25).

    Its `IosEmittedVectorTest` opens Carol's iOS group chat as Alice and Bob, and verifies Carol's `groupupdate` and
    `groupleave`. It also expects `0xB` in Carol's profile. The change must be additive: `digestIds` keeps its three
    ids, and Alice's profile, HELLO and advert keep `0x9`. This side exports `ios-emitted-v1.json` into the
    Android worktree before the merge, and the Android worker commits it.
  - **A6 (two Android group fixes, knit-next #107 and #108):**
    - A stranger who set `createdBy` to our node id made the `created` row count as ours (`MessageDao.kt:294`),
      so their group skipped the request inbox (#107).
    - Android kept a group's old photo hash at the new clock until the bytes landed (`InboundPipeline.kt:2334`),
      so its own frames could switch members who showed a newer photo back (#108).

    This port already avoided both. Android fixed both on its `main` without a paired change: `cb8bc4b5`, and
    `f46770a9` with its ADR 2026-09.nxcq. Both are in the pin since 2026-10-03. The one difference left, a tie that
    went to the incoming photo, now follows Android's `photoWins` (knit-ios#1, ADR 2026-09.n393, amended). Done.
- **Profile photos and photos in chats, begun 2026-10-03** on `feat/blobs`, at the maintainer's direction (ADR
  2026-10.nh55). This is parity with Android's photos and its blob exchange:
  - **Step 0:** the pin moved to `00357abd`, and the group photo's tie follows `photoWins`. Done.
  - **Phase 1:** FILE records both ways, `blobreq` asked and answered, and our own photo published and pushed, with
    no UI yet. Code done on 2026-10-03: every Linux gate passes, sanitizers and ten minutes of fuzzing included, and
    so do the Mac build and tests. Checked the same day between the iPhone 12 and the Pixel 3 on Android 2.8.0, with
    the lab's other phones in range:
    - `interop.py iphone` passes all 22 steps on the new build.
    - The iPhone's photo, set over its bridge, reaches the Pixel 3 whole (13,109 B in 1.2 s) and shows there, and
      clearing it clears it there.
    - The iPhone shows the photo of every peer that advertises one, and every blob on its disk hashes to its name.
    - With the Pixel 3's link refused, the iPhone pulls the Pixel 3's new photo with `blobreq` through another
      phone, 37 s after the change.
    - On `interop.py iphone-relay`'s line, with the peer on hci0, the iPhone is the one node between the two ends,
      and serves each the other's photo: all 21 steps pass with `--expect-avatar --peer-avatar`.
  - **Phase 2:** profile photos in the app (ADR 2026-10.sepc). Code done on 2026-10-03: a face for every person at
    Android's sizes, the photo picker, the cropper and the viewer. Every Linux gate passes, sanitizers included, and
    so do the Mac build and all 13 Simulator walks, the new photo walk at both text sizes among them. Checked the same
    day on the iPhone 12 against the Pixel 3:
    - The iPhone draws the photos of the Pixel 3 and two other people, and their group as both photos side by
      side.
    - The profile codec, run on the Mac over a GPS-tagged picture, makes a 256-pixel JPEG that keeps only its color
      space and pixel size. Published from the iPhone, it reached the Pixel 3 in 210 ms and shows there.
    - Still owed: `KnitDeviceTests`' `PhotoTests`, which chooses, crops and saves a photo on the iPhone itself. Its run
      timed out enabling automation mode, as a first run does until someone enters the passcode on the phone (ADR
      2026-09.63em).
    - Not ported: Android's "changed their photo" line in a DM thread, and its rename line. A later change ports both.
  - **Phase 3:** photos in chats both ways, in Nearby, DMs and groups (ADR 2026-10.6cas). Code done on 2026-10-03: DMs
    and groups seal them with `AttachmentCrypto`, schema v5 keeps what each message carries, and the app picks,
    holds, sends, shows and saves them. Every Linux gate passes, sanitizers, analyze and Periphery included, and so
    do the Mac build and all 14 Simulator walks, the new chat-photo walk at both text sizes among them. Checked the
    same day on the iPhone 12 against the Pixel 3 (`.agents/context/linux-peer.md`, "What the photo runs showed"):
    - `interop.py iphone-photos` passes all 17 steps: photos cross both ways in all three threads, the iPhone
      decodes the phone's sealed ones with their keys, and the phone's screen shows the iPhone's.
    - A 480 KB photo crossed a DM in 45.6 s, the link's own rate of about 10.5 KB/s.
    - Still owed: `iphone-wake` while a photo streams to the locked iPhone, and `iphone-soak --extras` with the iPhone
      now keeping the phone's photos.
    - Out of reach here: the bubbles on the iPhone's own screen, which only a device UI test can open. The Simulator
      walks draw them, and the bridge's `photos` decodes them on the phone.
  - **Phase 4:** group photos shown but never set, and carried frames' photos pulled within Android's 128 MiB. A carrier's
    pull follows knit-next ADR 2026-10.g24x's `CarrierPullPolicy`: a DM's picture waits up to 10 min while its recipient
    is linked, and, since its 2026-10-07 amendment, a group's picture waits while the group's author is linked unless the
    carrier is a member (`GroupInfo.members`). Before that pull, a carried frame's key-less picture is copied from our own
    sealed copy under the same author test as `deliverChat`'s (`copyFromOwnStore`, ADR 2026-10.f3mv), as Android's
    `onCarriedFrame` does.
  - **Android's progress ring** (knit-next ADR 2026-10.y9qh): every header this port writes declares its size since
    2026-10-04, so an Android phone fills a ring as our photo arrives. Still owed:
    - the iPhone's own ring for a photo arriving, from the size `FileIntake` already reads;
    - resuming a cut transfer from the bytes kept (knit-next ADR 2026-10.wtyc, knit-ios #2), in the pin since
      2026-10-05. This port reads a `blobreq`'s `offset` and serves the whole file meanwhile.
  - **The blob holder query, begun 2026-10-05** on `feat/blob-query` (ADR 2026-10.m9uq), with the pin moved to
    `5f521cb9`. The iPhone answers `blobhave` in every build and claims `CAP_BLOB_HAVE` in its HELLO. Since 2026-10-09
    it queries before it asks in every build, as Android's release does since knit-next `713b29d6`, and asks the author
    on its HAVE without waiting for the other answers (knit-next ADR 2026-10.g24x's item 2; ADR 2026-10.m9uq's
    amendment). The device trial passed on 2026-10-06, with `8994da0` on the iPhone 12 and four Pixels on knit-next
    debug builds. Every Pixel queried the iPhone and fetched one copy of its photo, the iPhone took one copy of each
    Pixel's from the holder its `blob fetch` named, and a `knit-peer` from `main`, which cannot answer, was asked blind
    as the author. Every Linux gate passes. Still owed:
    - a device run of a release build's first photo fetch, querying, and of the author's HAVE deciding with a carrier
      linked that holds the photo too;
    - knit-next's second confirm, whose answer `fetchWait` never reads (`BlobExchange.kt:385`): this port mirrors the
      Kotlin, so the fix lands in knit-next first and comes here with the next pin;
    - the pin, past knit-next #140 (`fix/blob-ask-race`, the 2026-10-06 amendment to its ADR 2026-10.6e5t), once it
      merges. This port mirrored it from the working tree that day (ADR 2026-10.m9uq's amendment), so check the merged
      Kotlin against `BlobAskStandsTests` then;
    - knit-next ADR 2026-10.nxfb's holder half, a fed file kept in flight while its link feeds that peer more;
    - Closed on 2026-10-10 by ADR 2026-10.ds45's amendment (`fix/ios-blob-parity`): nsr7's holder half, a meter on
      our own feeds for an `eta` and a second ask parked behind a live feed, members served before carriers; nsr7's
      two asker changes of 2026-10-07, leaving a long stream for an idle holder and dropping an ask that found its
      neighbour lacking the blob; and a skipped file reported to its sender.
    - ADR 2026-10.xwjc's device check: knit-peer on dongle A with `--radio-profile android` against a Pixel, a photo
      near 1 MiB each way, `--feed window` against `--feed pace`.

  Out of scope: files, voice notes, link previews, direct transfer, screening, and setting a group photo.
  Capabilities stay `0xB`. One companion change goes with it:
  - **A7 (shared blob vectors):** a paired change that iOS leads. knit-next's `keyed-v1.json` gains:
    - the FILE_HEADER bytes for an AVATAR, and a whole FILE trio (an ATTACHMENT's header, with its size, came with
      knit-next ADR 2026-10.y9qh);
    - a `blobreq` frame;
    - a known answer for a sealed photo.

    Its `IosEmittedVectorTest` decodes an iOS header and opens an iOS-sealed photo. The change is additive, and
    `0xB` stays. The same change could give the debug bridge's `state` each reachable peer's `avatarHash`: until it
    does, `interop.py check --peer-avatar` sees our photo leave whole, and the phone's screen shows whether it landed.
- **Companion change A1 in knit-next:** the responder accepts a dialer it never sighted (knit-next ADR
  2026-09.shzv). Merged on 2026-09-25 as `05dc2be1`, with a 30 s floor before a held link is replaced and the
  −90 dBm score kept for peers never sighted during the link; `LinkManager` follows both (ADR 2026-09.6es2).
  Done.
- **Companion change A2 in knit-next:** merged on 2026-09-25 as `0c0756f6` and `1f3befcd`. Done.
- **The Pixel's presence advert drops out** (knit-next #112, filed 2026-10-01): when a link at a 15 ms interval opens
  just as Android's presence set comes up, its stack refuses to enable the set
  (`CONNECTION_REJECTED_LIMITED_RESOURCES`). `BleAdvertiser` does not override `onAdvertisingEnabled`, so it never
  brings the set back, and the advert stays off for 10 to 60 s while an iPhone can neither find nor dial the phone. A
  bonded Meshtastic radio set it off at every resume on the Pixel 7, and Android's own A3 read of the iPhone set it off
  once. MVP item 2 waits on it in part; nothing in this port changes for it. knit-next's fix (`c6218c68`, on
  `fix/presence-advert-reassert`, its ADR 2026-10.9utz) enables the set again after every connection. On the Pixel 7
  on 2026-10-02 the longest silence a passive scan heard fell from 43.5 s to 19.6 s, then 11.1 s. With the Meshtastic
  radio on, the fix never re-enabled the set, because its connection receiver was not exported. `288fc0ea` fixed
  that, and with the Coded mode off the Pixel's stack then refused no enable at all. Both commits are on knit-next's
  `main`, and knit-next recorded the runs in its ADR 2026-10.9utz (`.agents/context/linux-peer.md`, "What the
  Meshtastic radio showed"). Done on Android's side.

## Next, after the MVP

- **DM forward secrecy:** the v2/v3 epoch ratchet, with `CAP_RATCHET`, `CAP_CRYPTO_V3` and `CAP_INLINE_ACK`,
  and sealed receipts, reactions and profile updates. It comes before any public build. Keyed vectors come
  first (`.agents/context/crypto.md`).
- **Contacts:** contact links at a distance (`docs/CONTACT_CARD.md` in knit-next), and Android's Add contact,
  which pins a key from a scanned code. QR verification in person is in on a peer's profile (ADR 2026-10.65xx):
  the profile shows our code and scans theirs, and compares only, as Android's profile does. It passes in the
  Simulator. On the iPhone 12 on 2026-10-02, with Bluetooth off for an Android trial, `CameraTests` passed: the camera
  is asked for only at Scan their code, a refusal shows its own state, and an allow starts the scanner. The code the
  iPhone drew decoded to its 150-byte `knit-id`, and its id derives from its bundle, Android's `parseLegacy` check.
  The same day, by hand, the iPhone scanned the Pixel's code and the Pixel scanned the iPhone's, and both scans
  worked. Done; Add contact and contact links remain.
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
- **Android windows its feed to an iPhone, and reports to one** (knit-next ADR 2026-10.5buf; ADR 2026-10.xwjc): two
  gates in knit-next, which the maintainer lifts there. `BleFeedPolicy.windowed` leaves out a peer whose HELLO carries
  `CAP_DOORBELL`, so Android feeds an iPhone at its paced base. `BlobExchange.onFileProgress` sends an iPhone no
  `blobprog`, so an iPhone feeding Android hears nothing, waits out 3 s of silence, and goes on at the 4 KiB/s
  fallback. This port reports at the window's cadence and windows any reporting peer already. Check both directions
  with `interop.py iphone-photos` once both gates lift.
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
- **The rest of the owner and reviewer model** (ADR 2026-10.zjmx). Three planes have a pair: Bluetooth, blobs and
  custody, and crypto. Each piece below waits on what it would review:
  - the mesh-lab reviewer, with the lab above;
  - the crypto reviewer's ratchet-era shapes (knit-next's evidence from a dropped era, a reset that makes its own
    evidence, a send inside the peer's floor), with the DM ratchet;
  - a Wi-Fi Aware pair, if ADR 2026-10.2c6c's spike lands;
  - a Swift doc-lint like knit-next's, which flags a symbol a persona or a doc names after the code has dropped it.
    `PersonaTests` checks only the paths and ADR ids the personas cite.

- **Message features:** files and voice notes, mentions, and Android's full emoji picker for reactions. Profile photos
  and photos in chats are in flight (ADR 2026-10.nh55), reactions are in with a fixed six (ADR 2026-10.ehe6), quoted
  replies are in, in every thread (ADR 2026-10.mn29), and so are typing indicators, Android's row at a thread's foot
  (ADR 2026-10.29z9). `interop.py iphone-reply` and `iphone-typing` have yet to run against a phone.
- **Groups with forward secrecy** (knit-next's group ratchet), which comes with the DM ratchet. v1 groups are in
  flight above.
- **Search, drafts and backups.** Search has its place already: a `.searchable` on the chat list's stack, which iOS 26
  puts at the bottom on the iPhone, with Android's sections for results (Chats, People, Messages; ADR 2026-10.5waw).
- **Moderation and report.** App Store rule 1.2 requires them before a store build. Block is in (ADR 2026-10.5wgg),
  and so is screening photos from others, with Android's model in Core ML (ADR 2026-10.rpmq), and screening messages
  with Android's Detoxify model and word list (ADR 2026-10.e4kz). Report is in too (ADR 2026-10.f6kf): it deletes the
  message and blocks the person on this phone, and can email `iosreports@getknit.app`; About has the address. Terms
  of use with zero tolerance are agreed to in onboarding, and again when they change (ADR 2026-10.cgm3). Android
  has no report yet. knit-next ADR 2026-10.d62w's slur list now runs in every conversation here too (ADR 2026-10.8e2u);
  its ADR 2026-10.9rh6 is mirrored too (ADR 2026-10.spcy): the iPhone screens on sending only in Nearby, and screens
  its profile photo when it is set.
- **App Store readiness:** started on 2026-10-03 at the maintainer's direction. The privacy manifest and the export
  answer are in, Knit ships for iPhone only (ADR 2026-10.kedu), and `check.sh release`, `archive` and `upload` build,
  check, sign and upload the store build (ADR 2026-10.8cy5). The review notes, the listing and the export filing
  remain. The GPL exception is already in place.
- **Background discovery, the rest of it:** a locked iPhone with no link now seeks peers, scanning for `0xFE30`
  alone and dialing what it finds, whatever the order, within eight wakes a spell (ADR 2026-10.mueg). Three things
  stay open. Discovery while it holds links: near five phones the filtered scan kept Knit running three quarters of
  the time (P8's scan-filter check, `.agents/context/linux-peer.md`). Seeking again once the budget is spent,
  perhaps from `BGAppRefreshTask`. And a far side that keeps its connection after its app dies: the iPhone then never
  hears the link end while suspended (Android drops it; BlueZ with a GATT client of its own is untried), and a fix
  that needs the far side's help becomes a Track A item.
- **Done 2026-10-10: an iPhone below a flagged Android phone no longer waits for its dial.** This was the iPhone's
  twin of knit-next #103, and interop-audit finding AND-2. At the front the iPhone gives the phone a 12 s head start
  past the dwell, then dials it itself (ADR 2026-10.6eyf). Android admits a dialer it has not sighted, so no Android
  change was needed, and the Track A item is closed. In the background a lonely iPhone dials it anyway (ADR 2026-10.mueg).
- **Never on iOS:** Wi-Fi Aware as a mesh plane, the BLE side channel, spool relays and commons, LoRa, and Wi-Fi
  Direct. A Wi-Fi Aware lane for files between paired phones is the one shape left open, and a spike comes first
  (ADR 2026-10.2c6c). These are ADR-recorded scope decisions, not a backlog.
