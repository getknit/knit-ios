# knit-next, the source of truth

Knit for Android lives in `~/source/knit-next` on the maintainer's machine (origin
`source.jeffmixon.com/knit/knit-next`, public mirror `github.com/getknit/knit`). Everything this repo
puts on the air has to match what that code does, byte for byte. When a doc and the Kotlin disagree, the
Kotlin wins.

## The pinned reference

- Release `v2.7.0` is commit `7e73e891`. The port started from HEAD `02051b64`, five test-only commits
  later, on 2026-09-25.
- **The pin is `a87d2255`,** knit-next's local `main` on 2026-09-30 once #103 merged, ahead of its `origin/main`
  (`b0fc4721`) until the maintainer pushes. `sync-vectors.py --check` needs a checkout that holds it.
  - **Up to `05dc2be1`** (A1's merge): A2's two commits (`0c0756f6`, `1f3befcd`: tests, `vectors/`, docs and
    Gradle's test inputs) and two ratchet fixes (`4b054362`, `fcb60d04`: v2/v3 only, which this port carries but
    never opens). Of what the files below say, only the BLE responder moved.
  - **Up to `aeba5382`** (the previous pin): `aeba5382` (ADR 2026-09.9xuu) serves profiles first and parks a whole
    backlog per sender, merged unchanged from the branch commit `CustodySync` and `PendingInbound` mirror;
    `cfa4a627` adds a debug-only link cap, the bridge's `BLECAP` (release still runs 6 links); and `e8b98398`
    keeps spool copies out of overhear suppression, and there is no spool here.
  - **Up to `033c1edf`** (the previous pin):
    - `c3191717` is A4 (ADR 2026-09.dqvb): Android rings the doorbell of a peer whose HELLO carries
      `CAP_DOORBELL`. `DoorbellPolicy.kt` holds the UUIDs, the 5 s interval and the three upkeep types that
      `LinkManager+Doorbell` matches.
    - `06f2040e` (ADR 2026-09.g64k) keeps the signed profile each pin came from, in `peer_profiles` (database
      v16), and sends a sender's key ahead of a backlog. It matches what this port mirrored before it merged:
      `ForwardSync.keylessSenders`' three rules, `KeyExchange.profileFor`'s cache then store, and
      `PeerDao.recordProfile`'s forward-only upsert are `CustodySync.missing`, `KeyExchange.serveKey` and both
      `recordProfileFrame`s.
    - `11b91371` (ADR 2026-09.tjfb) holds at most one digest waiting per link (`FramedLink.pendingDigest`),
      which `LinkOutbox` mirrors (ADR 2026-09.3ch7). `045d4e4a` only records its runs.
    - `31a313e3` (ADR 2026-09.6gk8) backs off a cleartext tick's re-sends as it did a sealed one's. The back-off
      gates only a best-effort send with no link, which here means LoRa, so this port's `AckSync`, which sends
      owed ticks only over a link, has nothing to mirror. The rest of it is LoRa.
    - The Wear OS prototype (`34d07dbb` to `033c1edf`, ADR 2026-09.wetm) serves a bonded watch its own GATT
      service outside the mesh (`ble-transport.md`). `08aab191` adds knit-next's paired-change rules.
  - **Up to `2efea24a`** (the previous pin):
    - `2efea24a` (ADR 2026-09.adpz, #100) remembers each receipt with its sender, so a DM that lands after its own
      receipt is refused on arrival. It merged unchanged from the branch commit `CustodySync` mirrors
      (`custody.md`).
    - `3000c537` (#98) puts Android's peer-row reads and writes in one transaction, because its avatar writer
      runs beside the profile writer. This port keeps no avatars and runs one engine thread, so nothing moves.
    - `ea38c08b` fixes mesh-lab races and adds `MeshManager.linksActedOn`, a test hook. It parks three repros.
      #96 is a room tick sent over a link that is gone by the time it is written: it is dropped rather than owed
      again. `AckSync` has the same shape, since `owe` trusts `isLinked` and nothing hears whether the write
      landed, so mirror knit-next's fix when it comes. #97 (DataStore) and #98 are Android's alone.
    - `e4b46a00` (the profile photo editor), `c4de3eac` (the relay indicator for a DM without the ratchet) and
      `df762e71` (CI) touch nothing this port has.
  - **Up to `82898694`** (the previous pin):
    - `82898694` (#102, an amendment to ADR 2026-09.dqvb) looks the doorbell up at link-up rather than at the first
      ring, and each lookup that finds it asks for `CONNECTION_PRIORITY_BALANCED`. An iPhone that dialed is the
      central and runs the link at a 720 ms supervision timeout; BALANCED carries 5 s, and iOS grants it. Nothing
      on the wire moves, and this port has nothing to mirror: CoreBluetooth gives a central no say in the link's
      parameters (`ble-transport.md`).
    - `3a912ce3` (ADR 2026-09.adgd, #23) adds Remove contact. It clears only local signals and sends nothing, and
      a commons member is accepted on first sighting only. This port keeps the accepted set (`ConversationStore`) but has
      no contacts list, removal or commons; mirror the rule when Contacts lands.
    - `06dd410d` (closes #97) and `bc25507c` move DataStore, and `9449fd15` shows the git SHA in debug builds'
      About screen. They are Android's alone.
  - **Up to `f3f9cb9d`** (the previous pin):
    - A3 (knit-next #101, ADR 2026-09.kwq2), rebased onto `0983824b` and merged unchanged from the branch this port
      mirrored ahead of the pin: `0c3aa685` holds the reader, `45569aa7` mends the ADR's status line, `4bf4226b` adds
      the payload lifetime's two new forget rules after the first device gate, `c5ff044a` records the gate,
      `8d7ab437` sets the flag, and `f3f9cb9d` records the iPhone checks. An Android phone with `BLE_GATT_PEERS`
      (debug builds; release keeps it dark) adds a scan filter on the `0xFE30` UUID, reads the GATT payload of a node
      that lists only the UUID (`BleGattPayloadReader.kt`), and sights that node with it. `GattPayloads.kt` ports
      `GattPayloads.swift`'s rules line for line, plus a 64-address cap on each map. A payload goes when a dial fails
      before its channel opens, when a HELLO names another node (checked before an accepted dialer's verdict, and on
      a dial's reply), or after 60 000 ms of presence-scan windows with the address unheard and unlinked; each logs
      `bt gatt forget <addr> (dial|hello <id>|quiet)`. A HELLO refusal keeps it, and so does a quiet stranger's wait.
      A dialed link takes its capabilities from the HELLO reply, so A4 rings it (`BluetoothMeshTransport.kt`).
      `BleAdvertPayload.kt` names `FLAG_DIALS_GATT_PEERS` (`0x02`), advertised whenever the reader runs, and
      `docs/WIRE_COMPAT.md` says every parser tests only the bits it knows. The payload, the flag and `weDial` were law
      in this port first; the forget rules are mirrored in `GattPayloads`, `LinkManager` and both radios (ADR
      2026-09.xzpt, amended 2026-09-29). ADR 2026-09.shzv (A1) and 2026-09.dqvb (A4) are amended, and A1 stays whole.
    - `0983824b` lets a user clear the Nearby room's messages like any chat's. It clears them locally, sends
      nothing and leaves custody alone, so this port has nothing to mirror.
  - **Up to `b0fc4721`** (the previous pin):
    - The put-back race (#102, a further amendment to ADR 2026-09.dqvb), rebased and merged unchanged from the
      branch the device runs used: `3e566b1f` (built as `ed9446bf`) asks for BALANCED again when a report shows a
      timeout under 5 s after the lookup's ask, at once or 2 s later, at most twice a lookup, and logs
      `bt doorbell priority <id> again (put-back <ms>ms|settle)`. `fe2eeed6` (built as `24bac000`) spends no re-ask
      on a report whose status is not 0. `8d3c5551` and `b0fc4721` record the runs. Nothing on the wire moves, and
      this port only checks it (`interop.py android-reads --links`, `iphone --links`; "What the put-back race
      showed", `linux-peer.md`).
    - `0b9d19ea` labels an animated image "GIF", from its frames, read locally after the blob lands and stored on
      the message (database v17). It adds no wire field, so this port has nothing to mirror.
    - `2d059df6` moves Android's dependencies, `cb295894` its CI, and `e40135f2` and `3031fe60` its tests.
  - **Since then:**
    - #103 (knit-next ADR 2026-09.hj4a), rebased onto `c1b7c19c` and merged unchanged from the branch this port
      mirrored ahead of the pin (`b6336ddf`, `f4d43637`, `8258350a`): `36f04b8d` is the change, `11505341` records
      its device trial in the ADR, and `a87d2255` words its changelog line. An Android phone that has held no BLE
      link for 180 000 ms, counted from the later of the transport's start and its last link going down
      (`noLinkSince`), dials the strongest peer it sights above it, on an ordinary dial's filters and backoff, one at
      a time (`LonelyDialPolicy.kt`). It logs `bt lonely dial <id> (alone=<ms>ms rssi=<dBm> dwell=<ms>ms)` just
      before that dial's `bt initiating to`, and its debug `bt state` line gains `alone=<ms>ms`. A responder that
      sighted the phone refuses it, which the phone counts as a `HANDSHAKE` failure, and a failed dial to a peer it
      already holds a link to bumps no backoff. This port's `admit()` already gives Android's verdict (ADR
      2026-09.6es2), so no Swift mirrors it, and only the harness moves: `interop.py`'s `_dialed_by` and
      `phone-never-dialed` report a lonely dial rather than fail it. Run offline over that trial's logs (the lonely
      Pixel 8's two lonely dials, both linked, and four runs without one), they report both dials, pass the other
      runs, and fail each dial once its lonely line is deleted.
    - `cbbb1e0c` (knit-next ADR 2026-09.hp88, #67) awaits an absent Meshtastic board with `autoConnect` after three
      dials. It is LoRa alone, which this port does not carry, so there is nothing to mirror.
    - `c1b7c19c` settles a stuck attachment's spinner to a still hourglass after 30 s, and `adad2d41` enables a
      Claude plugin. Both are Android's alone.
  - No wire bytes or vectors moved.
- The `.agents/context/` files in this repo (`wire-format.md`, `ble-transport.md`, `crypto.md`,
  `custody.md`) were read at `02051b64`, and what moved was checked again at each pin since, last at `a87d2255`.
  Moving the pin means re-reading the files below and updating those four, in the same change, then running
  `scripts/sync-vectors.py`.

## Where to look

All paths are under `app/src/main/java/app/getknit/knit/` unless they start with `docs/` or `app/src/test`.

| Question | Kotlin |
| --- | --- |
| What the advert, the L2CAP link and the handshake look like | `mesh/bluetooth/BluetoothMeshTransport.kt`, `BleAdvertPayload.kt`, `BleAdvertiser.kt`, `BleScanner.kt`, `BleConstants.kt`, `mesh/link/LinkFraming.kt`, `LinkHandshake.kt`, `FramedLink.kt` |
| Who dials, who gets promoted, how long to back off | `mesh/bluetooth/PromotionPolicy.kt`, `ConnectBackoffPolicy.kt`, `BlePresenceTracker.kt` |
| The CBOR envelope and every payload type | `mesh/protocol/Wire.kt`, `Protocol.kt`, `FrameId.kt`, `CanonicalText.kt` |
| Keys, node ids, DM sealing, safety numbers, aliases | `mesh/crypto/PublicKeyBundle.kt`, `MessageCrypto.kt`, `SafetyNumber.kt`, `identity/NodeId.kt`, `Alias.kt`, `AliasWords.kt` |
| Flooding, dedup, custody, sync, receipts, key recovery | `mesh/MeshRouter.kt`, `SeenSet.kt`, `ForwardSync.kt`, `data/forward/ForwardRepository.kt`, `mesh/InboundPipeline.kt`, `MeshManager.kt`, `AckSync.kt`, `KeyExchange.kt`, `PendingInbound.kt`, `IngressBudget.kt` |
| Groups: ids, rosters, rename, leave and status lines | `data/message/Conversations.kt` (`groupIdFor`), `GroupNaming.kt`, `StatusNotices.kt`, `data/GroupRepository.kt`, `data/group/GroupEntity.kt`, `mesh/InboundPipeline.kt` (`reconcileGroup`, `rejoinBy`, `vetRoster`, `handleGroupLeave`), `MeshManager.kt`, `ui/contacts/ContactUniverse.kt`, `ui/group/`; `docs/GROUP_FORWARD_SECRECY.md` for v1 against v2 |
| Byte-exact fixtures | `vectors/` (`wire-v1.json`, `keyed-v1.json`, `ios-emitted-v1.json`; `vectors/README.md`), checked by `mesh/protocol/GoldenVectorTest`, `KeyedVectorTest` and `IosEmittedVectorTest`; also `NodeIdTest.kt` and `AliasTest.kt` |
| The additive-change rules | `docs/WIRE_COMPAT.md`, `docs/NEXT_WIRE_BREAK.md` |

## Docs that are out of date

Read these for design reasons, never for bytes:

- `docs/IOS_PORT_REVIEW.md` describes the pre-launch wire. A2 put a list of corrections at its top; the
  body's node id scheme (`knit-node-id-v1:`, 8 bytes mapped `% 36`), 16-byte advert with a version byte,
  one-way HELLO, 64 KiB file chunks and Tink-prefixed signatures were all replaced before v1.
- `docs/NEXT_WIRE_BREAK.md` gives the database version as 11. The code is at 15.

A2 also corrected `docs/ARCHITECTURE.md` §14: the L2CAP link is insecure, and two frame types are unsigned.

## Companion changes (Track A)

Changes this port needs in knit-next. They follow knit-next's own `AGENTS.md`: its ADR tooling, changelog
gate, mesh-lab rules and wire-compatibility rules. Status lives in `.agents/memory/roadmap.md`.

- **A1:** Android's responder accepts a HELLO from a dialer it never sighted, whatever the node id order;
  it replaces a stale link from such a dialer; teardown removes a link only if it is still the registered
  one; an unsighted link scores −90 dBm rather than −127. Without A1, an iPhone links to an Android phone
  only when the iPhone's node id sorts higher. Merged as `05dc2be1` (knit-next ADR 2026-09.shzv), with two
  changes from review: a held link is replaced only once it is 30 s old (`REPLACE_MIN_HOLD_MS`), and only a
  link whose peer was never sighted during it scores −90 dBm; one sighted and then lost still scores −127.
  `.agents/context/linux-peer.md` has its trial.
- **A2** (merged as `0c0756f6` and `1f3befcd`): the golden vectors moved into JSON in `vectors/` that
  `GoldenVectorTest` reads, joined by keyed vectors (fixed identities, signed frames, a sealed v1 DM, the
  safety number, advert, HELLO, DIGEST and FNV hex) and a test that checks the fixtures this repo emits.
- **A3** (knit-next #101, ADR 2026-09.kwq2, merged and in the pin at `f3f9cb9d`): Android finds and dials iPhones:
  it reads the `0xFE30` GATT payload from an advert that carries no service data, and sets `FLAG_DIALS_GATT_PEERS`.
  Its own advert needs no UUID list, since an iPhone's scan filtered on `0xFE30` matches the service data, locked or
  not (P8's scan-filter check, `.agents/context/linux-peer.md`). A dialed iPhone's capabilities must then come from
  its HELLO reply, or A4 never rings it.
- **A4** (`c3191717`, knit-next ADR 2026-09.dqvb, in the pin): Android rings the GATT
  doorbell of a peer whose HELLO carries `CAP_DOORBELL` (`0x1000`), after the frames it writes on a link it
  accepted, on this port's schedule and with the same three upkeep types left out (ADR 2026-09.khjj). It never
  claims the bit itself. `.agents/context/ble-transport.md` has the details.
- **A5** (planned, a paired change iOS leads, ADR 2026-09.n393): keyed v1 group vectors.
  - **`keyed-v1.json`** gains:
    - a third identity, `dave`, from seeds 7 and 8;
    - `groupIds`, `{members, id}` known answers for `Conversations.groupIdFor`, including unsorted and duplicate
      input;
    - Alice's v1 group chat to Bob and Dave (frame id seed 23), which `KeyedVectorTest` opens as each of them;
    - her rename `groupupdate` (seed 24) and her `groupleave` (seed 25).
  - **`IosEmittedVectorTest`** opens Carol's iOS-sealed group chat as Alice and Bob, derives its id from the roster,
    verifies Carol's `groupupdate` and `groupleave`, and expects `0xB` in Carol's profile.
  - **Additive only.** `digestIds` keeps its three ids, so the DIGEST, its fold and the advert stay put. Alice's
    profile, HELLO and advert keep `0x9`.
- **A6** (planned, ADR 2026-09.n393): two Android group fixes this port already makes.
  - A forged `createdBy` naming the recipient counts the `created` row as theirs (`MessageDao.kt:294`), so a
    stranger's group skips the request inbox.
  - The old photo hash rides at the new clock until the bytes land (`InboundPipeline.kt:2334`).
