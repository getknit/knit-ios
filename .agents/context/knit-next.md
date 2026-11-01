# knit-next, the source of truth

Knit for Android lives in `~/source/knit-next` on the maintainer's machine, and publicly at
[`github.com/getknit/knit`](https://github.com/getknit/knit). Everything this repo
puts on the air has to match what that code does, byte for byte. When a doc and the Kotlin disagree, the
Kotlin wins.

## The pinned reference

- Release `v2.7.0` is commit `7e73e891`, `v2.8.0` is `45e09f19`, `v2.9.0` is `3286edd8`, and `v2.10.0` is
  `20696bad`. The port started from HEAD `02051b64`, five test-only commits after `v2.7.0`, on 2026-09-25.
- **The pin is `e63f15f4`,** knit-next's `main` on 2026-10-25, moved to take in what this port had mirrored ahead of
  the last one. Every commit since `5f521cb9` was read for it, and "Since then" below says what each means here.
  `sync-vectors.py --check` needs a checkout at the pin, since a later one may carry vectors this port has not taken.
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
      the message (database v17). It adds no wire field. This port mirrors the label in schema v11 (ADR 2026-10.ytvx),
      since Android sends every GIF as an animated WebP and a type alone cannot say it moves.
    - knit-next ADRs 2026-10.unqn (a clean, bounded picture is stripped, not re-encoded) and 2026-10.8hmx (an
      animated picture keeps its frames) shape the pick pipeline. This port mirrors both, numbers and allow-lists
      included, with libwebp in place of Android's encoder (ADR 2026-10.m4ah). Android's GIF door samples with
      `android.graphics.Movie` and its WebP door composites by hand; ImageIO composites here.
    - `2d059df6` moves Android's dependencies, `cb295894` its CI, and `e40135f2` and `3031fe60` its tests.
  - **Up to `a87d2255`** (the previous pin):
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
  - **Up to `00357abd`** (the previous pin; 39 commits, release `v2.8.0` among them):
    - **A6, both halves** (knit-next #107 and #108):
      - `cb8bc4b5`: a stranger's group can no longer name the recipient as its creator to skip the request inbox.
        This port never allowed that.
      - `f46770a9` (knit-next ADR 2026-09.nxcq): a group photo's decided hash is stored and advertised at once, and
        the shown hash waits for the bytes (database v18). A tie goes to the incoming photo only when nothing is
        held (`photoWins`). This port already stored the decided hash at once, and now mirrors the tie
        (`GroupRoster`).
    - **The file pace follows the link's PHY** (`00357abd`, #114). `FramedLink` reads a `PaceConfig` before each
      chunk (`CodedPhyPolicy`, `TransferPacePolicy`):
      - 28 KiB/s in 16 KiB chunks on 1M and 2M;
      - 1 KiB/s in 2 KiB chunks on Coded.

      Chunk size is the sender's choice, so nothing on the wire moves (`ble-transport.md`).
    - **The Coded PHY experiment** (knit-next ADR 2026-10.yvn6; `3e775bcb`, `1cc17dca`, `12618cc7`, `e08806c9`,
      `1b0610be`, and `5cc511cd` for #113). It adds:
      - a second, extended presence set on Coded;
      - dials to a peer's Coded address;
      - a GATT client that steps a link between PHYs.

      It was dark in release then (`BLE_CODED_PHY`, on since `713b29d6`, below) and touches only peers heard on
      Coded, which an iPhone never is. Nothing to mirror. Its later, more aggressive form is under "Mirrored ahead of
      the pin".
    - **Relinking** (`17dc62ea`, knit-next ADRs 2026-10.ryak and 2026-10.pj9w; `5e9f267d`, ADR 2026-09.w3xk):
      - the presence advert runs at full power;
      - the connect loop wakes when a candidate's dwell ends, and its waits run on the elapsed clock;
      - after its last link drops, a phone hunts at the 12 s scan gap for three minutes.

      The floors did not move, so a never-sighted link, which is often an iPhone's, is shed at the budget a little
      more often (`ble-transport.md`). `LinkManager` already wakes at a dwell's end.
    - **The presence advert re-asserted** (`c6218c68`, `288fc0ea`, `2b736ef7`; knit-next #112, its ADR 2026-10.9utz):
      recorded in the roadmap.
    - **Reachable indirectly** (`e2cbaf0b`, knit-next ADR 2026-10.fw8g): a fourth reach tier, for authors heard only
      through relays and read from signed frames. It is Android's UI alone.
    - **Nothing to mirror:**
      - `937cf785` answers a ratchet intro that opened before its prekey pinned, and this port carries no ratchet.
      - `f4491d44` never wipes the database or mints an identity when the keystore refuses, which
        `IdentityKeys.load` already refuses to do (`crypto.md`).
      - The rest is Android's alone: backup, storage, the 2.8.0 release, the Wear OS docs, a debug Wi-Fi Aware switch,
        CI, lint and screenshot tests.
    - No wire bytes or vectors moved.
  - **Up to `e4ff84b3`** (the previous pin; two commits):
    - **The header's size** (`e4ff84b3`, knit-next #115 and its ADR 2026-10.y9qh). A receiver shows how far an
      incoming attachment has got:
      - the `FILE_HEADER` gains `size`, the length of the stream that follows;
      - `keyed-v1.json` gains a `fileHeader` record that pins it, and no other vector moved.

      This port writes the size whenever it serves or pushes a blob, and reads it leniently: a size that will not
      decode costs the label, never the file (`LinkTests`, `LinkVectorTests`). Android's ring, its `rx` log lines and
      `arrivingFiles()` carrying a count are its own. The iPhone shows an incoming photo's progress since 2026-10-24
      (ADR 2026-10.eyad).
    - `f6ecf8ac` drops an unused `Unit` from a test.
  - **Up to `5f521cb9`** (the previous pin; 30 commits; five vectors added, none moved):
    - **The blob holder query** (`403cd861`, knit-next ADR 2026-10.6e5t), on top of **the likeliest holder first**
      (`1c82da2d`, #136, knit-next ADR 2026-10.f7gg). Mirrored here (ADR router, "blob holder"):
      - the iPhone answers `blobhave` with `blobhas` in every build, and every HELLO claims `CAP_BLOB_HAVE` (`0x2000`);
      - it queries the neighbours that answer and asks the best holder alone, as Android does behind
        `BuildConfig.BLOB_QUERY`: at the pin in a debug build and knit-peer, and in every build since knit-next turned the
        flag on in release (below). Off, it asks blind: the author first, then the hop the frame came from, then
        everyone once a 5 s grace is up;
      - the three vectors `blobHaveContent`, `blobHasContent` and `blobHasContentReserved`.
    - **A file is on its way until it is stored** (`c1437646`, #138, an amendment to knit-next ADR 2026-09.4tx5):
      mirrored as `LinkManager`'s landing files and `MeshTransport.fileTaken`. `512b72bc` (#139) keeps Android's file
      collector alive past one bad file, which helps what this port serves, and needs nothing here.
    - **A blob is not asked of a peer streaming to us** (`dedd985e`, #121, knit-next ADR 2026-10.nxfb): its asker half
      is mirrored (`MeshTransport.isFileArriving(from:)`, which also counts a file this port skips). Its holder half, a
      fed file kept in flight while the link goes on feeding that peer, is not: `isFileInFlight` ends at our own END,
      so an Android asker on an older build can still be served twice across the stack's buffer (roadmap).
    - **Resuming a cut transfer** (`e13c2c76`, #116, knit-next ADR 2026-10.wtyc): mirrored (ADR 2026-10.w6rn). A
      `blobreq`'s `offset` in `1...length` is served as the tail under a resumed `FILE_HEADER`, and a parked ask keeps
      it. A cut attachment's prefix is kept on disk for the session, the next ask names its length, and a failed
      splice starts over from 0. `blobReqContentResumed` and `fileHeaderResumed` round-trip. The 2026-10-15 amendment
      (`0e96bb0c`, #161, one resumed header per key per link per 45 s) is mirrored too, in the same 45 s window
      (`FileIntake.swift`), and in the pin since `e63f15f4`. Where the Kotlin
      has moved past wtyc's text (no `onNeighborAdded`; `reaskFromZero` opens a forced cycle rather than asking
      everyone), this port follows the Kotlin at `0108d8df1`.
    - **One file pace budget** (`99ee3f81`, `37dd5f22`, knit-next ADR 2026-10.8jwn): Android feeds at most 4 KiB/s across
      every 1M and 2M link it feeds, in chunks of 2 to 16 KiB (`ble-transport.md`). Sender-side only; mirrored with
      5buf's window, below (ADR 2026-10.xwjc). Since #120, an Android peer's link that earns the boost takes 18 KiB/s
      of its own; an iPhone's never does.
    - **An attachment keeps its arrival identity** (`01b2fd5d`, knit-next ADR 2026-10.mptm): a sealed DM or group message
      may name a room picture by its plaintext hash with no key, and one blob may recur across messages
      (`crypto.md`). This port took both already, and since ADR 2026-10.f3mv mirrors the rest: a held pick goes as its
      blob, and a key-less frame from someone in the chain is copied from our own store, in `deliverChat` alone until
      carrier pulls land. `7dd7dcc3` screens spool-pulled
      pictures and never adopts a held avatar its filter refused; this port keeps a flagged face adopted and hides it
      when drawn (ADR 2026-10.rpmq), so nothing moves.
    - **Nothing to mirror:**
      - `ab0d17aa` hunts a Coded peer lost at range (knit-next ADR 2026-10.yvn6), never an iPhone (`ble-transport.md`);
      - `d6c3be1b` gives up a GATT payload read on the elapsed clock, still after 12 s;
      - `38e425b5` keys the DM ratchet's receive state by root tag (ADR 2026-10.gcrd), and this port has no ratchet;
      - `540bf032` re-sends a direct transfer's READY, `d9b6f1c4` paces LoRa, and `47485429` fades stranger name clashes
        after a week (ADR 2026-10.k8ge);
      - `280bf959` and `5f521cb9` change Android's photo picks, within the types this port takes;
      - the rest is Android's alone: notifications, the debug bridge, metrics, agents, tooling and tests.
  - **Since then** (396 commits, releases `v2.9.0` and `v2.10.0` among them; 24 fixtures added to `wire-v1.json` and
    `ratchet-v1.json` new, none moved). Read on 2026-10-25, and the merged code checked at `e63f15f4`:
    - **Owed here.** j67x's rule can bite between honest phones, and the last needs a failed database write.
      `FLAG_NO_AWARE` (knit-ios #16) was owed here too, until `808472a3` turned it around past the pin ("Mirrored
      ahead of the pin", below), and #13's two decoder items were too, until they landed ("Taken since the pin"):
      - **j67x's third rule** (`6d9627b7`, knit-ios #15): over our own unanswered reset, still draining, Android keeps the drained root
        as `prevRoot`, and `sealReset` takes the held one (`crypto.md`). It belongs with j67x's other two rules, below.
      - **A blob that fails to store** (knit-ios #17): Android keeps the want and its asks (`BlobExchange.onReceived`,
        `BlobExchange.kt:2016-2021`). `receiveFile` here marks the blob obtained and withdraws its asks whether or not
        the insert landed (`MeshEngine+Blobs.swift:315-320`), and the next re-arm wants it again.
    - **Taken since the pin** (knit-ios #14), each refused or accepted here as Android refuses or accepts it:
      - **A negative `ttl` or `hops`** (`9c56cd31`, from #13): `WireEnvelope` refuses one once it has decoded, as
        `decodeWire` does (`Wire.kt:1071-1076`), before the crossing and the seen set.
      - **A code point split across text chunks** (`a0a29148`, knit-next ADR 2026-10.qjap, from #13): KnitWire joins an
        indefinite-length string's chunks before its one UTF-8 check, as `CborText.chunks` (`CborText.kt:52`,
        `:99-109`) and kotlinx do, so a code point may straddle two chunks; joined bytes that are not UTF-8 stay
        refused.
      - **A negative label** (`97e1747f`, kotlinx 1.12.0, from #13): `CBORLabeledFields` reads a v3 plaintext's
        negative key with argument `n` as the label `~n`, the bits of kotlinx's wrapped `Long`: `20` (−1) is skipped as
        unknown, and `3B FFFFFFFFFFFFFFEF` reads as 16, `video`.
      - **Fields Android now types** (`13387e0a`, `651cdc25`, `e3e41a2e`, `33d83aca`, `236f56b5`, `8724b6b3`): KnitWire
        checks each one's CBOR type without modelling it, so a wrong-typed room post stays out of custody and a
        wrong-typed sealed message fails to open (`wire-format.md`). `xf` and a blob request's `fastOnly`, older but
        unchecked, are checked too.
      - **kotlinx 1.12.0's decoding:** the null mark, the `Int` and `Long` wraps, tags, integer keys and duplicated keys
        read as on Android. Three gaps stay where Android skips its `CborText` walk (`wire-format.md`, "The CBOR
        profile").
    - **Mirrored ahead of the last pin, and checked again at this one:**
      - **Canonical frame ids** (`a81f2050`, #178, and its HELLO half `99fbcad1`, #199; knit-next ADR 2026-10.9qr4):
        every inbound door refuses a frame whose id is not the shape its type is minted with. This port's door is
        `Router.admit`, which refuses before the seen check and the meter and counts `router.nonCanonical` (ADR
        2026-10.h7xw). `FrameId.kt`'s `TALK_LENGTH`, `admits` and `profileId` are unchanged since, and agree with
        `FrameId.swift` and `FrameIdAdmitsTests`. A HELLO's node id this port checks at `admit`. The spool's door is
        Android's alone.
      - **A card's name** (`3d587088`, for Add contact, ADR 2026-10.tpr5): Android cuts it at 32 UTF-16 units on a
        code-point boundary (`clampToUtf16`), as `ContactCard.clampName` does. `docs/CONTACT_CARD.md` moved only for the
        spool (`3cd25bc0`). `795b0883` and `f5a6edab`, no intro to a peer whose profile lacks `CAP_RATCHET`, are
        Android's alone while this port sends no intro.
      - **The wire vectors,** synced alone at `9c3d487b` (2026-10-19), then with the rest at the pin:
        - **What came in at `9c3d487b`:** 14 fixtures for features this port has not taken. Calls (`messageContentCall*`,
          `bd7c905b`, knit-next ADR 2026-10.3tee), supporter badges on the profile (`profilePayloadBadges`,
          `messageContentV2ProfileBadges`, `e3e41a2e`, knit-next ADR 2026-10.r99s, knit-ios #10), short videos
          (`messageContentVideo`, `messageContentV2Video`, `chatContentVideo`, `13387e0a`, knit-ios #9), and two blob
          request fields: `fastOnly`, which asks before a large Bluetooth-only download (`3b03c5f9`), and `pull` with
          its `until` (`385bfba0`).
        - **What this port does with them:** decodes each to the type it already has and drops the new fields, which
          `GoldenVectorTests.whatThisBuildDoesNotModelStillDecodes` pins, except `pull`, `until` and `chatContentVideo`'s
          `attachmentSize`, which this port sends since knit-ios #7 (its `video` waits on #9). `fastOnly` marks an asker
          that takes the bytes over Wi-Fi Aware alone (knit-next ADR 2026-10.js2p), which this port cannot honour.
          Android sends one only to a neighbour with a Wi-Fi Aware route (`BlobExchange.kt:493`), so an iPhone never
          gets one. `pull` and `until` carry knit-next ADR 2026-10.2drc's hop budget and deadline for a pull-through.
          This port models them since ADR 2026-10.8hek, which ports `385bfba0` and its amendment `1ce131fd`, and
          `blobReqContentPull` and `blobReqContentPullSpent` have typed tests.
        - **What came in after:** seven more fixtures, and none of the 78 moved:
          - two scope-config ctls (`messageContentScopeConfigDm` and `Group`, `33d83aca`), which this port takes as the
            chain-advancing no-op Android counts on;
          - two commons posts (`commonsPostAttachment`, `commonsReaction`, `651cdc25`), which only a spool carries
            (knit-ios #11), so they only round-trip;
          - a message's formatting (`messageContentStyles`, `messageContentV2Styles`, `chatContentStyles`, `8724b6b3`,
            knit-next ADR 2026-10.p95v): style ranges in one byte string beside a plain body, under `"s"` or compact
            label 17. This port drops them and shows the body plain, which the ADR expects until the iPhone's half
            lands. Android refuses a sealed message whose `"s"` or label 17 is not a byte string (`DECRYPT_FAILED`),
            so the iPhone's half must refuse one too (above).

          `whatThisBuildDoesNotModelStillDecodes` pins the two ctls and the three styled fixtures.
      - **Companion changes A9 and A10** (ADR 2026-10.5sk9), merged as `2325775f` to `768b6cd0` and `4f3cd995`:
        `ratchet-v1.json`'s known answers, profiles, DM transcripts and refusals, control plane, group form, and Carol's
        races and first contacts. It now syncs with the rest at the pin. Its bytes last moved in `3e3e044c`, which adds
        `groupSkippedPerMint` for #177. `1b5e72fa` regenerated it for #174: 139 `state.session.peerBasePub` leaves carry
        the init's prekey where they had null, and no frame, header, plaintext or ciphertext byte moved (phase P7f). The
        IV seam (`newIv`, default `AesGcm.randomIv`) changes nothing in production, and the port's engines mirror it.
      - **The ratchet's fixes past `72684a86`,** followed in phase P7f (ADR 2026-10.5sk9's P7f amendment):
        - `458c2eee` (knit-next ADR 2026-10.dmgw): #174, an initiator records the prekey its init names as its base
          (`RatchetEngine.initiate`, `prekeyBase`); #172, a low-order key is "cannot seal" and a low-order prekey is
          never pinned (`RatchetCrypto.acceptsPublicKey`, `verifiedPrekey`, `MessageCrypto.seal`, `recipientBundles`,
          `groupRatchetEligible`); #171, a reset's re-seal goes out once more past the dedup window (`ResetReseal`);
          #177, a group skipped key spent by its full key, which this port already did. Its #173, `AckSync`'s
          live-link tick chunked at `MAX_BATCH_ACKS`, is the blobs plane's, followed in phase P7g
          (`AckSync.flushOverLink`). This port already makes its `MessageContentV2` change, a canonical check on a
          profile's `loraKey` when encoding (`CanonicalText.keyBytes`).
        - `09cacf5b` (knit-next ADR 2026-10.9wvr): an `EPOCH_GONE` on a retired local epoch behind the peer's own ack
          is never reset evidence (`RatchetResetPolicy.isRetiredBase`, `RatchetStore.lowestLocalEpoch`). Its follow-ups
          #179, #180 and #181 have not landed.
        - At the pin, every function these touch is byte-identical to `4f3cd995`, and `prekeyBase` and `isRetiredBase`
          agree with `RatchetEngine.swift` and `RatchetResetPolicy.swift`. The only ratchet commits since are a Qodana
          refactor (`3b2f624c`) and `sealDm`'s `confirmedOnly`, for scope configs alone (`33d83aca`).
      - **Not followed: j67x** (`6d9627b7`, knit-next ADR 2026-10.j67x). It gives the spool's scopes to our unanswered
        reset, reads a frame that predates our session, carrying the init of the root we replaced, under the drained
        root rather than racing it (`RatchetEngine.resolveSession`'s `predatesSession`, `derivesPrevRoot`), and keeps
        the drained root over our own reset (above). The scopes are the spool's, which this port leaves out; the other
        two change what a peer accepts, and are owed a phase of their own.
      - **Mentions** (ADR 2026-10.nbhj and 2026-10.jwst): a picked mention as a chip that backspace deletes whole
        (`d47ad76c`), a mention's color moved until it reads 4.5:1 on its bubble (`eafb0721`, merged unchanged as
        `bb87222c`), and `@everyone` in a group (`ac491f4c`, knit-next ADR 2026-10.6h2g, merged unchanged as
        `f2be66c5`). UI only, and nothing on the wire moves. `MentionText.kt`'s chip and `@everyone` code is unchanged
        since, so `MentionTextTests` and `MentionEveryoneTests` stand; `8724b6b3` only draws styles over the mentions,
        and `ReadableColor.kt` is unchanged. `3a6f5d08` and `1870384c` make a mention's alert say only that words are
        hidden when the filter flagged them, which this port's alert already does. Companion change A8, mentions on
        Android's debug bridge, is owed.
      - **The quote check** (`1870384c`, knit-next ADR 2026-10.gpa3; ADR 2026-10.x246): followed since 2026-10-30, ported
        from knit-next `main` at `7439fd9cc`, where `QuoteCheck.kt` and `QuoteVerifier.kt` differ from `1870384c` only by
        a Qodana cleanup (`3b2f624c`) and a reaction quote's ellipsis (`0d64a1b6`). Until then this port stored a
        received quote as sent, and the ledger never said `1870384c`'s main change was not followed. A received quote is
        admitted as `admitReply` admits one, judged against the original by `quoteVerdict`, rebuilt by `settleQuote`, and
        settled on whichever of reply and original lands second, with the start's backlog (`MeshEngine+Quotes`). Schema
        v20 takes Android's `replyCheck` and `replyToFlagged` (its DB v22), and `QuoteState` mirrors `quoteViewFor`. The
        one difference: the app screens after the engine stores, so a verified quote can wait on its original's screen,
        and the store passes the verdict on when it lands.
      - **A photo's declared size** (`eac3debc`; knit-next ADRs 2026-10.js2p and 2026-10.hmfe; knit-ios #7): a picture
        of 1,000,000 bytes or more declares its plaintext length, sealed in a DM or a group and in the clear in a room
        post, so Android's "Ask before large Bluetooth downloads" can hold it (`BluetoothFetchGate.kt`'s
        `declaresSize`, `MeshManager.kt:1468`, `:1549`). `BluetoothFetchGate.kt` is unchanged, and this port's
        `BluetoothFetchGate.declaresSize` drops only the `named` arm, since it sends no file (`BluetoothFetchGateTests`).
        An Android carrier holds its own Bluetooth pull of such a room photo too (`roomPostWaits`,
        `MeshManager.kt:2936-2946`).
      - **A payload that won't decode** (`03c4c3b1`) counts as `PAYLOAD_DECODE_FAILED`, so a broken group typing cue no
        longer lights the room. The iPhone's `handleTyping` counts one `undecodable` (ADR 2026-10.29z9).
      - **The blob plane's parity order** (`79f38d3d`, `09f70b3e`, `e2191bb9`, `3890f16b`; ADR 2026-10.ds45's amendment
        of 2026-10-10, for the interop audit's IOS-1, AND-5 and AND-7), checked against the tests named then:
        - the asker's `stuckOn`, `streamWait`, `askedLacking`, `idleHolderPast`, `lackedWhileStuck` and `recheckAt`
          (`BlobExchange.kt:574-731`) are unchanged since `8dc60836`, and `FramedLink.rxEtaMs` equals
          `fileArrivingLeftMilliseconds`: `InteropAuditMeshTests` and `BlobStreamWaitTests`;
        - the holder's parking (`BlobExchange.kt:1649-1957`) changed only to keep a parked ask's offset, `pull` and
          `until` (`385bfba0`), which this port does: `MeshEngineBlobParkTests`;
        - `FeedMeter.kt`, `FramedLink.feed` and `notePaced`, and `BluetoothMeshTransport.fileFeed` and
          `expectedFileRate` are unchanged since `8dc60836`, and `FeedMeter.swift` lacks only Coded's `forgetDrain`:
          `FeedMeterTests` and `LinkFileFeedTests`;
        - a skipped file's reports (`FileIntake.kt:134-160`, `RxReports.kt:48-70`): `LinkFileProgressTests` and
          `FileIntakeTests`;
        - nsr7's rules from `79f38d3d`: `PROGRESS_EVERY_MS` (2 s), `HOLD_SLACK_MS` (30 s), `HOLD_CAP_MS` (15 min),
          `hold`, the `CAP_BLOB_HAVE` gate `onFileProgress` and `withdrawAsk` share, `onCancel`, `Want.over`,
          `withdrawAsks` at landing, and `Want.withdraw` with `Answer.receivedAt`, but for the failed store above.

        This port took nsr7's holder half, the meter and the parking, and g24x's per-link budget and one copy at a
        time, on 2026-10-10, and g24x's item 2, asking the author on its HAVE (`BlobExchange.answersIn`), on
        2026-10-09. Only g24x's carrier hold waits, for Phase 4's carrier pulls: `CarrierPullPolicy.kt` is unchanged
        since `79f38d3d`.
      - **#140, an ask to a holder that stands until its link goes** (the 2026-10-06 amendment to knit-next ADR
        2026-10.6e5t), ported from the uncommitted `fix/blob-ask-race` (ADR 2026-10.m9uq's amendment) and merged as
        `a294fe30`. `graceUp`, `hold`, `confirmWait`, `askHolder`, `askable`, `answersIn` and the round-trip waits
        (`BlobExchange.kt:736-892`, `:1047-1076`) match `BlobAskStandsTests`' Swift.
      - **Every BLE flag on in release** (`713b29d6`; `6760b843` documents them in `docs/BLUETOOTH_PLANE.md`):
        `BLE_SIDE_PLANE`, `BLE_GATT_PEERS`, `BLOB_QUERY`, `BLE_CODED_PHY` (always AUTO), `BLE_LINK_BOOST` and
        `BLE_FEED_WINDOW` (`app/build.gradle.kts:456-468`). Only `BLOB_QUERY` changes what this port does: the app
        queries in every build (ADR 2026-10.m9uq's amendment of 2026-10-09). With the others, a release Android phone
        finds a foreground iPhone through its GATT payload and dials it, hunts a Coded peer in windows deaf to an
        iPhone, and never boosts an iPhone link.
      - **5buf** (knit-next ADR 2026-10.5buf with both amendments of 2026-10-08, and 8jwn's budget as its fallback; ADR
        2026-10.xwjc): `6dee7666`, `e4624be3`, `e3654bb2` and `e8458feb`, with `e658eb6f` lifting the two gates that left
        iPhones out (`BleFeedPolicy.windowed`, `BlobExchange.onFileProgress`). `FeedWindow.kt`, `RxReports.kt` and
        `TransferPacePolicy.kt` are unchanged since `e8458feb`, so `713b29d6`'s tree is the merged code. `FeedWindow`
        agrees with every branch and constant but the Coded ones (`FeedWindowTests`, `FeedWindowSimTests`), and the
        report cadence with `LinkFileProgressTests`. Android lets an armed trailing report run to its next wake, where
        this port drops it at the next file's header, which reports sooner and never later. The device run is owed
        (knit-ios #6).
      - **AND-3** (`a03fe167`, built and trialled as `b7c13e57`), with `a2cec531` noting Android's re-dial from
        presence. It amends knit-next ADRs 2026-09.shzv and 2026-09.kwq2. A link whose HELLO carried `CAP_DOORBELL`
        scores −90 out of presence, never −127, and a doorbell dialer counts as sighted for admission only if heard in
        the last 12 s, with the bit backed by the phone's own evidence (`BleAdmissionPolicy.kt:54-125`). Nothing on the
        wire moves, and this port changes no Swift for it: an Android peer never leaves presence the way an iPhone does
        (`LinkManager+Configuration.swift`). Its lines, `bt state … linkScores=` and the admission lines'
        `doorbell=true heardAgoMs= inPresence=` suffix, with ` doorbellTrusted=false` when the evidence fails, are what
        `interop.py android-keeps-iphone` reads (`ble-transport.md`, `linux-peer.md`).
      - **Whitespace as ART measures it** (`e0c8d969`, knit-next ADR 2026-10.swst; ADR 2026-10.7uyt):
        `app.getknit.knit.text.ArtTextSemanticsTest` walks the BMP on API 33, 34, 36 and 37. It is unchanged, and its
        two lists equal `TextLimits.isKotlinWhitespace` and `isJavaRegexWhitespace`; U+180E is in neither.
      - **Dead links, canonical HELLO ids and Coded,** 2026-10-14 to 2026-10-20, first read at `85cf0baa`. Since then
        only `9552995d` touched their Bluetooth files, and not `LinkSilence`. No Swift behaviour moves here:
        - **A link this phone can show is dead goes down** (`f8b5d544`, `b49f7f13`, `ec37724e`; knit-next ADR
          2026-10.697m, #203). An empty `KEEPALIVE` is now an announce, a probe and an answer, and Android closes a
          silent link about 150 to 210 s after the last byte in (`LinkSilence.kt`, `ble-transport.md`). A link whose
          HELLO carries `CAP_DOORBELL` is exempt (`LinkSilence.kt:39,146,158`; `BluetoothMeshTransport.kt:2744`, where
          `advert` is the HELLO on a dialed link and an accepted one alike), and every CoreBluetooth HELLO carries the
          bit. The ADR calls its knit-ios half "a notice, not code". This port takes it as `interop.md`'s rule never to
          write a keepalive, `LinkRecord.Tag.keepalive`'s comment,
          `LinkAdmissionTests.aKeepaliveIsNeverWrittenNorAnsweredDoorbellOrNot` and an amendment to ADR 2026-09.6es2.
          The Linux peer's `android` profile, whose HELLO lacks the bit, gets Android's announce and never answers, so
          Android never probes it.
        - **One redial bump per link end** (`9a68b225`, #205, `LinkDownOnce.kt`): Android's first redial now comes at
          about 10 s. This port's `retire` already acts once per link.
        - **The Coded PHY, more aggressive** (`ba14a876`, #169; the Bluetooth parts of `d7da26f6`; `752922da`; knit-next
          ADR 2026-10.yvn6). The step-up backs off after flaps, a 1M hit weaker than −90 no longer blocks `codedOnly`,
          and a cold sighting starts a bounded hunt. All of it is on in release. An iPhone is never heard on Coded, so
          there is nothing to mirror. Three indirect costs to an iPhone are listed in `ble-transport.md` and wait on a
          trial (roadmap). `d7da26f6` also appends `near=[…]` to `bt state` after `linkScores=`, and later commits add
          `awareNear=`, `awareHeard=`, `noAware=` (`aware=` since `808472a3`) and `newcomers=` after it and `gattBudget=` after `gattReads=`;
          `interop.py`'s patterns ignore them. Its Wi-Fi Aware half is Android's alone.
    - **New since the last pin, and nothing to mirror:**
      - **Custody before the air** (`85baeeb9`, #141): Android custodies each of its own frames before it floods it.
        This port sends, then carries, in one synchronous step, so no link comes up between them (`custody.md`).
        `00a466e7` (#141) reads custody before the rows in Android's carrier re-arm, which this port does not make.
      - **One builder for a file DM's sealed content** (`7f454603`, #131), so a re-seal keeps its name and size. This
        port's `MeshEngine.content(of:)` already is one, for the send, the wait and the re-seal.
      - **The interop audit's IOS-6 and IOS-7:** Android keeps a member's leave and rejoin clocks on the group
        (`c141ffac`, `group_member_clocks`), as `GroupRoster` does, and seals a ctl DM only to a peer whose profile
        carries `CAP_RATCHET` (`63101c20` and `c70c08b9`), as `RatchetOutbound.receiptPlan` does.
      - **AND-9** (`90150f7d`, `23597c28`, cherry-picked from `fix/android-interop-hardening`): Android's copy toward a
        peer without `CAP_RATCHET` stops promising that an update brings files, direct transfers or forward secrecy, and
        an iPhone added by its code no longer shows "Waiting to reach…" for good. A current iPhone carries
        `CAP_RATCHET`, so those strings no longer show toward it.
      - **Proof queries** (`6ecd4447`): an Android phone asks a DM photo's recipient, over Bluetooth, whether it holds
        the photo, with an ordinary `blobhave`, at most one per hash and peer every 10 s, and keeps it off the spool on
        a HAVE. The iPhone answers it like any query.
      - **Calls** (knit-next ADR 2026-10.3tee and the rest, in release since `v2.10.0`): `CAP_CALL` and `CAP_WALKIE` in
        the signed profile alone, `CTL_CALL` (ctl 10) only toward a profile carrying `CAP_CALL`, and the unsigned
        `talk` frame, which this port relays and never opens (`wire-format.md`). An iPhone is offered no call.
      - **Bluetooth:** the GATT payload read budget (`8246d2ec`, #154), the ACL arms (`8dc95c3e`, `d39759dc`; #142,
        #150; knit-next ADR 2026-10.b8yf), the link boost toward Android peers (`cdd6ef32`, #120) and keepalives between
        a file's chunks (#203), all in `ble-transport.md`; the BLE decision glue pulled into pure policies (`6d257161`,
        `673c1df9`) with every constant unchanged; `a0d8b488` (the Coded fallback dial's watchdog).
      - **Staged for the next wire break** (`docs/NEXT_WIRE_BREAK.md`): custody for 7 days (`8400dd11`, item 12) and a
        group's roster, name and photo sealed (`5c7ce27a`, item 11), in `custody.md`. `a871ccb2` adds `WIRE_COMPAT`'s
        rule 6, and `a81f2050` its rule 7 (`wire-format.md`).
      - **Builds:** kotlinx-serialization 1.12.0 and Tink 1.24.0 (`97e1747f`); only cbor's key reader moved for this
        port (above), and every vector is byte-identical. The database is at v25.
      - **Android's alone:** the spool and Knit Anywhere (tickets, TURN, proof-of-work stamps, several commons rooms per
        relay, home spools and scope configs), LoRa (MeshCore's id elision, the dedicated setup in release, a DM held
        until its recipient is heard), Wi-Fi Aware (asleep while no Aware phone is near, and instant mode stood down),
        low-power mode, offline translation, voice-note transcription, short video re-encoding and screening, the
        supporter badge's production key, the field log, the developer view, Wear watch faces, pt-BR, notifications,
        the debug bridge, tooling and tests.
  - **Mirrored ahead of the pin:** `eccabcd72`'s `RoomAttachments` (its ADR 2026-10.79j9): a room post's attachment
    that is not a picture, a link card or a video is left off the row, and a post that is nothing else keeps none
    (`RoomAttachments.swift`, ADR 2026-10.vzem, knit-ios #21). The frame and the wire are unchanged.
    And `e0cbb842a` (its ADR 2026-10.7mqm, knit-ios #18, ADR 2026-10.9e7g): the custody cap evicts from the largest
    sender, and custody refuses a group frame whose roster does not derive to its id or name its sender. Its
    `vectors/custody-v1.json` was copied with `sync-vectors.py --only custody-v1.json` from `820187443e`, where the
    file is unchanged since `e0cbb842a`. `015fff823`, blob traffic marked for relay, is not mirrored.
    And `808472a3` (GitHub #44, the 2026-10-27 amendment of its ADR 2026-10.2t49, knit-ios #16): advert bit 2,
    `FLAG_NO_AWARE` at the pin (`9552995d`, `438ffc72`), becomes `FLAG_AWARE` with the opposite meaning, "count on my
    Wi-Fi Aware now". `AdvertPayload.awareFlag` reserves it, and no advert this port writes sets it
    (`ble-transport.md`). The clear bit it always wrote already reads right, so only names, comments and tests moved.
    And `ce56fec6e` (its ADR 2026-10.mqzv, knit-next #227, knit-ios #34, ADR 2026-10.6n48), merged to knit-next's
    `main` from `fix/custody-byte-cap`: custody refuses a frame whose `signed` is longer than 61,440 bytes, before
    every other refusal, and the sweep deletes the rows over the cap. Its `vectors/custody-v1.json` (30 steps, a
    2,048-byte rig cap) was copied with `sync-vectors.py --only custody-v1.json` from `ce56fec6e`. The wire is
    unchanged.
    And `7439fd9cc` on knit-next's `fix/name-confusables`, not yet merged (its ADR 2026-10.2kfr, knit-next #228,
    knit-ios #30, ADR 2026-10.k99b): `NameKey` folds 73 Latin, Greek and Cyrillic lookalikes and I/l to i, and
    drops marks, default-ignorables and U+2800, so a lookalike or invisible name gets a discriminator. A received
    profile's name and status are cleaned of controls and bidi overrides at store (`TextLimits.cleanReceived`), and
    a group's name is cleaned where it shows. Its new `vectors/name-key-v1.json` was copied with `sync-vectors.py
    --only name-key-v1.json` from `7439fd9cc`. Android's rename line for a peer compares the cleaned old name; this
    port writes none. The wire is unchanged.
    And `a0b52f865` (its ADR 2026-10.jgeg, knit-next #234,
    knit-ios #22, ADR 2026-10.r88m): a cleartext profile whose `signed` is longer than 8,192 bytes is refused at the
    door, ahead of verify, custody and every write, and custody refuses and sweeps it too. Each side's local sweep
    deletes a stored proof of key over the cap and keeps the pin. A profile photo over 1 MiB is never fetched past
    the ceiling or shown as a face: a holder that streams or claims more is passed over for that photo for the
    session, whoever asks for the hash later (a neighbour's ask moves no ceiling, `BlobExchange.kt:116`, ported
    2026-10-31 with `Want.ownWant` and `Want.passedOver`), and a held one is cleared. Its `vectors/custody-v1.json` (33 steps, a 1,024-byte rig profile cap) and
    `vectors/keyed-v1.json` (`aliceProfileAtCap`, `aliceProfileOverCap`) were copied with `sync-vectors.py --only`
    from `a0b52f865`, merged to knit-next's `main` from `fix/profile-door-cap` (`295e54dca`, `d97cfd36b`, `a0b52f865`),
    unchanged since `295e54dca`. The wire is unchanged.
    And `c112277ce` (its ADR 2026-11.nsbf, knit-next #249, knit-ios #37, ADR 2026-11.y793), merged to knit-next's
    `main` from `fix/block-hides-profile` (rebased from `20520d63f`, adding only a test seam): a blocked person's profile still pins, is kept as the proof of key and moves
    their prekey, but their name, status and photo stay as they were at the block, their face is cleared, and their
    photo is neither fetched nor kept. An unblock re-applies the held frame and brings the face back. Android records
    the held frame in the row's own transaction and re-reads the block list after it (`settleBlockMovedMidProfile`),
    a race this port cannot have: the engine handles a profile with no suspension point inside the `Mesh` actor. No
    vector moved, and the wire is unchanged.
- The `.agents/context/` files in this repo (`wire-format.md`, `ble-transport.md`, `crypto.md`,
  `custody.md`) were read at `02051b64`, and what moved was checked again at each pin since, last at `e63f15f4`.
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
| The verify code: drawing, scanning and what a scan does | `mesh/crypto/VerifyPayload.kt`, `ContactCard.kt` (`parseLegacy`), `ui/verify/EncryptionSection.kt`, `ui/profile/ProfileDetailsViewModel.kt` (`onScanned`), `ui/addcontact/AddContactViewModel.kt`, `ui/scan/`, `ui/image/QrCode.kt` |
| Flooding, dedup, custody, sync, receipts, key recovery | `mesh/MeshRouter.kt`, `SeenSet.kt`, `ForwardSync.kt`, `data/forward/ForwardRepository.kt`, `mesh/InboundPipeline.kt`, `MeshManager.kt`, `AckSync.kt`, `KeyExchange.kt`, `PendingInbound.kt`, `IngressBudget.kt` |
| Groups: ids, rosters, rename, leave and status lines | `data/message/Conversations.kt` (`groupIdFor`), `GroupNaming.kt`, `StatusNotices.kt`, `data/GroupRepository.kt`, `data/group/GroupEntity.kt`, `mesh/InboundPipeline.kt` (`reconcileGroup`, `rejoinBy`, `vetRoster`, `handleGroupLeave`), `MeshManager.kt`, `ui/contacts/ContactUniverse.kt`, `ui/group/`; `docs/GROUP_FORWARD_SECRECY.md` for v1 against v2 |
| Byte-exact fixtures | `vectors/` (`wire-v1.json`, `keyed-v1.json`, `ios-emitted-v1.json`; `vectors/README.md`), checked by `mesh/protocol/GoldenVectorTest`, `KeyedVectorTest` and `IosEmittedVectorTest`; also `NodeIdTest.kt` and `AliasTest.kt` |
| The additive-change rules | `docs/WIRE_COMPAT.md`, `docs/NEXT_WIRE_BREAK.md` |

## Docs that are out of date

Read these for design reasons, never for bytes:

- `docs/IOS_PORT_REVIEW.md` describes the pre-launch wire. A2 put a list of corrections at its top; the
  body's node id scheme (`knit-node-id-v1:`, 8 bytes mapped `% 36`), 16-byte advert with a version byte,
  one-way HELLO, 64 KiB file chunks and Tink-prefixed signatures were all replaced before v1.
- `docs/NEXT_WIRE_BREAK.md` gives the database version as 11. The code is at 25.

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
    verifies Carol's `groupupdate` and `groupleave`, and expects `0xF` in Carol's profile, which reactions moved it to
    (ADR 2026-10.ehe6). knit-next's copy of the file still holds the `0x9` it was exported with.
  - **Additive only.** `digestIds` keeps its three ids, so the DIGEST, its fold and the advert stay put. Alice's
    profile, HELLO and advert keep `0x9`.
- **A6** (filed 2026-09-30 as knit-next #107 and #108, ADR 2026-09.n393): two Android group fixes. Android fixed
  both as `cb8bc4b5` and `f46770a9`, and both are in the pin. Done.
  - A forged `createdBy` naming the recipient counted the `created` row as theirs (`MessageDao.kt:294`), so a
    stranger's group skipped the request inbox (#107). This port never did.
  - The old photo hash rode at the new clock until the bytes landed (`InboundPipeline.kt:2334`), and an equal
    clock went to the incoming photo, so those frames switched members who showed the new photo back (#108).
  - Android's fix stores the decided hash at once, shows the new photo once its bytes land, and gives a tie to the
    incoming photo only when nothing is held (`photoWins`, knit-next ADR 2026-09.nxcq). This port already stored the
    hash at once, and its tie now follows `photoWins` (knit-ios#1).
- **A7** (planned; a paired change iOS leads, ADR 2026-10.nh55): shared blob vectors.
  - **Vectors:** `keyed-v1.json` gains an AVATAR's FILE_HEADER and a whole FILE trio, a `blobreq` frame, and a
    known answer for a sealed photo. An ATTACHMENT's header, with its size, came with knit-next ADR 2026-10.y9qh.
  - **The test:** `IosEmittedVectorTest` decodes an iOS header and opens an iOS-sealed photo.
  - **The bridge:** `state` could name each reachable peer's `avatarHash`, so `interop.py` can see a photo land.
  - **Additive only:** `0xF` stays.
- **A9** (planned; a paired change iOS leads, ADR 2026-10.5sk9): keyed ratchet vectors.
  - **Vectors:** a new `vectors/ratchet-v1.json`, written by a new `RatchetVectorTest`. It holds:
    - known answers for every derivation in `crypto.md`'s ratchet section;
    - ratchet profiles for Alice, Bob and Carol;
    - a scripted DM conversation with a state digest after each step;
    - group seeds and frames;
    - the negative cases.

    Key draws come from fixed seeds through `RatchetEngine(newKeyPair)` and `GroupRatchetEngine(newSeed)`.
  - **This side:** `scripts/sync-vectors.py` learns the file, and the pin moves to A9's merge.
  - **Additive only:** `keyed-v1.json` and `0xF` stay.
- **A10** (planned; a paired change iOS leads, ADR 2026-10.5sk9): the iPhone's ratchet frames.
  - **Vectors:** `ios-emitted-v1.json` gains Carol's ratchet profile and her v2, v3, ctl and group frames.
  - **The test:** `IosEmittedVectorTest` opens them as Bob.
  - **Decoupled first:** Carol's existing profile takes a literal `0xF`, so the iPhone's flip moves no Android test.
