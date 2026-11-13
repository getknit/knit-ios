---
id: "2026-11.prsp"
slug: the-iphone-airs-a-rotating
title: "The iPhone airs a rotating tag and sends its own presence keys"
date: 2026-11-11
topics: [ble, mesh, privacy, wire, crypto]
---

# ADR 2026-11.prsp — The iPhone airs a rotating tag and sends its own presence keys

Status: Accepted (2026-11-12), once companion change A11 merged to knit-next's `main` as `f018bc8ce` (the pin since;
`.agents/context/knit-next.md`) and its trial passed (run `70c5df`, `.agents/context/linux-peer.md`); proposed
2026-11-11. Mirrors the writer half of knit-next ADR 2026-11.xp6d (its steps 5b Part A, Part B1, Part B2 and 6) at the
pin `cad69c77b`: the rest of knit-ios #42. Companion change A11 in knit-next (`.agents/memory/roadmap.md`). It amends
ADR 2026-11.sv5t (the iPhone sends keys), ADR 2026-09.xzpt (a
blinded GATT payload is read as a form, and this port writes one), ADR 2026-09.6es2, ADR 2026-10.6eyf, ADR
2026-10.mueg and ADR 2026-11.hpmt (the dial rules once our own form is a tag), and ADR 2026-09.khjj (`TAG_NEXT` never
rings).

**Context:** since ADR 2026-11.sv5t the iPhone reads tags and stores its contacts' presence keys, but airs its own id.
The id goes on the air in one place, bytes 1–16 of the GATT payload (`LinkManager.advertiseNow`), plus the HELLO of
every link. Reading the characteristic needs no pairing, so any scanner that connects recognises the iPhone across
addresses, restarts and days, and iOS's own address rotation hides nothing while the payload names the node. Android's
release N ships its readers and keys, and N+1 turns its writer on. After N+1 the iPhone is the one Knit phone in a
crowd that a stock scanner can still follow.

sv5t left three things for this ADR: the sender of our own keys, the generation clock, and where that clock's last
value survives while `knit.sqlite` stays out of backups. Four facts shape what the iPhone can do:

- **Android cannot find a blinding iPhone today.** At `cad69c77b` and at knit-next's HEAD, `BleGattPayloadReader`
  answers a payload carrying `FLAG_BLINDED` with `stranger(PHASE_BLINDED)` (`BleGattPayloadReader.kt:86-88`). Android
  then sights nothing and looks no key up, so even a contact holding our key cannot recognise us. It never dials, and it
  reads the address again in 10 minutes, charging its read budget each time with no refund. Only the iPhone's own dials
  would link it.
- **iOS gives the app little control over the radio.** The advert carries only `0xFE30`, and in the background only
  in the overflow area, which Android and BlueZ cannot see. The system rotates the address on its own schedule, and
  iOS assigns the PSM (`BLERadio.swift:296`, whose comment says a republish hands back the same one).
- **A suspended Knit runs no timer.** It wakes only for a Bluetooth event: a doorbell ring, a disconnect, a read or
  write to its GATT server, or a seek's discovery (ADR 2026-09.khjj, ADR 2026-10.mueg). While Knit is suspended,
  bluetoothd answers a static characteristic value without waking it.
- **The links are clear.** This port has no `CAP_LINK_SEAL` (knit-next ADR 2026-11.8mhs, knit-ios #51), so a listener
  on a link reads the HELLO's id, its `t` and `a`, and every `TAG_NEXT`. (Amended 2026-11-12, as the seal merged: links
  between sealing builds are sealed (ADR 2026-11.6zhj), so all four ride inside the seal there. A listener still reads
  them on a plain link: with Android up to v2.11.0, or with a tag-reading build from before the seal.)

**Decision:**

- **Two gates, as Android's two flags.**
  - `MeshConfiguration.sendsOwnPresenceKeys`, Android's `PRESENCE_KEYS`, is on in every build, release included. The
    maintainer chose this on 2026-11-11, reversing sv5t's receive-only choice, so that contacts already hold the iPhone's
    keys on the day its writer ships. With it off, nothing is minted, rotated or sealed, but leavers' stored keys are
    still deleted.
  - `LinkManager.Configuration.blindsAdvert`, Android's `BLIND_ADVERT`, is the build gate: true in every debug build
    (`#if DEBUG` in the app's factory), false in release, which has no switch, no launch flag and no defaults key. A
    debug build has a runtime switch on top of it: the `-blind on|off` launch flag, kept in UserDefaults under
    `debug.launch.blind`, and the bridge's `advert blind`. The stored switch (or its default) sets the writer's state at
    construction and feeds `BLERadio(expectsBlinding:)`; it never sets the gate, or a process launched with the switch
    off could never be turned on from the bridge. The switch's default was **off until A11 merged and its trial
    passed**, and is on since (amended 2026-11-12, Phase 7, below).
  - **A flip with the radio up closes every live link,** with its cause logged, so each peer relinks and looks the
    doorbell up again. A flip moves the doorbell between the combined service and D, so its handle changes, and a ring
    client that looked it up once would write to a dead handle for the rest of the link. The relink can be slow after a
    flip from a tag to the id: a reader keeps the blinded payload until the next slot edge, so a clear peer above the
    iPhone waits for the "blinded" iPhone to dial while the iPhone waits for it by id order, until the head start or
    seeking dials. The flip trial times both directions; past about a minute, the iPhone should dial whatever the
    order for one dwell after a flip, as seeking does. The two gates are independent. A debug iPhone with the
    switch off still sends keys, and one that blinds with keys off airs random tags no contact resolves.
- **Our own keys** port the send half of `PresenceKeyPolicy` and `PresenceKeyEngine` with Android's constants: a week
  between rotations, a day's window for a new contact to join the current key, an hour's clock slack, a year's clamp,
  and a delay of 2 to 20 s at link-up.
  - Three rows (previous, current, next) of 32 random bytes.
  - The generation is `max(last + 1, now)`, overflow-checked.
  - The audience is `DirectContacts`, as sv5t defines it. iOS has no commons and no Remove contact, so only a block
    shrinks the audience today, and any shrink mints a fresh current and next.
  - A ctl 11 is the named `MessageContent` padded whole to 128 bytes of plaintext (`PresenceKeyFrame`'s
    `PLAINTEXT_BYTES`), signed with `relay = false`, and sealed by the ratchet.
    - **Only under a confirmed session,** as Android seals it (`confirmedOnly`, `RatchetSessions.kt:379`).
      `RatchetSessions.sealDm` gains that argument and checks it inside its own unit. The ctl 11 path passes no prekey.
      So a ctl 11 never opens a session, and never rides our own unanswered init or reset. An unflagged copy of a reset
      init would put the peer in its hour-long incidental floor (knit-next ADR 2026-10.j67x).
    - **Only over the proven link.** A ctl 11 goes only to a linked direct contact whose capabilities (the HELLO's or
      the pinned profile's) carry `CAP_BLIND_ADVERT` and `CAP_LINK_PROOF`, and whose pinned profile carries
      `CAP_RATCHET`. It is never custodied, flooded or cast.
    - **One call to send.** The send is `MeshTransport.sendOverProvenLink(_:to:) -> Bool`, which writes only to a channel
      whose link has proved the id. `send(to:)` takes the first live link for the id, proven or not. A proof retires
      every unproven link for its id before the proven one registers, so the two never stand together, but the send
      does not rest on that. A false answer forgets that peer's ledger entry, as Android's `onSendFailed` does.
    - **A frame lost in a drop goes again.** True means the record is queued in `LinkOutbox`, not delivered. The ledger
      entry names the link it went out on. If that link ends within the write-stall bound of the queueing, the entry is
      dropped, so the next link-up sends again. Android keeps its `sent` map through a drop, and its contact then waits
      for a root change or a new generation. The receiver takes an equal generation as a no-op, so a duplicate costs one
      ratchet step. The window is measured from the queueing on the monotonic clock. A suspension resets the stall
      watch's baselines, so a frame can still sit in the outbox past 150 s while Knit sleeps and be lost with the link.
      That contact then holds our older keys until the next rotation, a root change or a block: at most about a day.
  - **What each linked contact is owed** is kept in memory, per peer, under the root its last ctl 11 was sealed with
    (read in the seal's unit). The first pass of a session trims the ledger to the direct contacts. It is reconciled at
    link-up after the 2 to 20 s delay, at a key change, at heal, and when a peer gains a bit it needs. It is also
    reconciled when an open, a reset's adoption or a race's resolution commits a root other than the ledger's, or
    confirms our session. That mirrors Android's `rootChanges` (`MeshManager.kt:1401`). The heal runs our own key's
    pass whatever the feed's revision says, which catches the weekly, clock and mark advances. While a failed
    settle sits out its 60 s, no pass opens a unit unless a listing is due.
  - **A pass runs in this order:**
    1. One store unit settles: the direct contacts, `due` and its rows, the leavers' stored keys, and the departed set.
    2. After `.committed`, our own key and the departed set are published. The pass and the session's start each run
       to completion on the `Mesh` actor, with no `await` between the unit and the publish, so no session begins
       between them. Kotlin's epoch guard exists because its pass can outlive `beginSession`; it has no Swift
       counterpart here. If `feedPresenceKeys` ever gains an `await`, the guard has to come back.
    3. Then one outermost `sealControl` runs per owed peer. On `.sealed` it settles the ratchet, records the ledger,
       then sends. On `.joined`, `.failed` or `.unsealable` it records nothing and sends nothing.
    4. Hooks, the profile write's capability gain among them, only bump the feed's revision. They never seal or
       publish inside the unit that called them.
  - The published own key goes back to nil at every session start and stays nil until the first `.committed` settle.
    So a block made while the mesh was stopped is a fresh pair before the radio sees any key. A settle that cannot
    reach "nothing due" publishes nil. A block withdraws the published key at once, and puts the id in the `TAG_NEXT`
    refusals at once, as `unlistBlocked` unlists its keys. That way a store that keeps failing never leaves a
    just-blocked person resolving our tag. `hearsTagNext` answers no until both its inputs are read.
  - A release build logs no dated key line. The per-decision trail is written only where the configuration asks for
    it (debug builds and knit-peer), and `status` counts the rest.
- **Where each piece is stored.**
  - Our keys and the advertiser's mark go in `own_presence_keys` in `knit.sqlite` (schema v24), out of backups like
    every table there.
  - The mark is written durably, as Android writes it.
    - The whole write is one `writeWithoutTransaction` closure on the pool's single writer connection. First it sets
      `PRAGMA synchronous=FULL`. Then a transaction reads that the pragma is 2 and runs the conditional update, which
      lands only while the generation is the newest activated one; no rows changed means refused. A `defer` sets
      `NORMAL` again.
    - It never goes through `KnitDatabase.write(or:)`, and it refuses at once inside a store unit. SQLite refuses the
      pragma inside a transaction, and that refusal would fail the caller's unit.
    - Applying a row's activation or audience updates those columns alone, never replacing the row. A replace would
      zero the mark, and the advertiser could air an earlier slot's tag again.
    - GRDB's pool otherwise runs WAL at `NORMAL`.
  - **No `link_owed_resets`.** Android's restore sends link-owed resets (knit-next `228520ea7`, `REMARK_OWN`). Nothing
    here produces one: a reinstall sends no resets (`MeshEngine+Profiles.swift:83-87`), and `RatchetResetPolicy` has no
    such cause. So v24 adds no table for them, and `REMARK_OWN` stays owed with the restore's reset.
  - **The last generation** goes in the Keychain identity item beside `PrekeyRing`, as ADR 2026-10.wcex keeps the
    answered prekeys.
    - It is written the way `PrekeyRing.Item` is written: read the item, check the identity byte for byte, replace this
      one entry, keep the prekeys and the answered inits byte for byte, write, then read back.
    - It is serialized with the ring's writes on the `Mesh` actor, and in knit-peer's `PeerNode`.
    - It is written before the row it guards, and a failed write fails the mint. A failed read is never taken as zero,
      and before the first unlock nothing is minted.
    - A value more than a year ahead is clamped only when a reinstall is detected (`syncPrekey`'s `reinstall`), never
      at every start. A clamp inside a living root would hand peers a lower generation under the same root.
    - The item survives a reinstall (ADR 2026-09.tkww) and a restore to the same phone, which brings back the identity
      without the database. So a generation number is never reused there, as Android's backed-up setting ensures.
    - UserDefaults was the alternative, but it does not survive a reinstall.
  - **The day's floor between two clock or mark advances** reads a clock that keeps running while the phone sleeps,
    as Android's `elapsedRealtime` does, not the monotonic uptime that stops. Each relaunch allows one advance, a
    bounded cost.
- **The aired form is the GATT payload.** While blinding, the payload carries `FLAG_BLINDED` with
  `FLAG_DIALS_GATT_PEERS`, bytes 1–16 hold the tag, and the cue is zero. The flag is mandatory: Android at the pin would
  read a tag without it as a node id and dial it into `WrongPeer`.
  - **While blinding, the doorbell and the payload live in two `0xFE30` services.** The doorbell service (D) holds the
    doorbell characteristic alone. It is added first at each bring-up, before the L2CAP channel is published, and
    removed only at `stop()`, at power-off or at a switch flip. The payload service (P) holds the payload characteristic
    alone and is the one a rotation replaces: the new P is added, and the old P removed by reference once `didAdd`
    lands. `removeAllServices` is kept for `stop()` and the first power-on after a restoration. A clear iPhone keeps
    today's one combined service, because a pinned Android reads a clear payload only from the first `0xFE30` service.
    - Why not one service rotated whole: every ring client looks the doorbell up once and then writes to that handle
      with no response (Android's `BleDoorbell.write`, `WRITE_TYPE_NO_RESPONSE`; KnitBlueZ's `writeDoorbell`, a write
      command). A rotation that moves the doorbell's handle loses every later ring on that link without a sign, so a
      suspended iPhone hears nothing until it comes to the front, once per slot. Android learns of a services change
      only from API 31 (`onServiceChanged`), and only if iOS indicates Service Changed to it. A doorbell service that
      never rotates keeps its handle.
    - Every reader searches every `0xFE30` service for the payload and for the doorbell: KnitBLE discovers the
      characteristics of each before it ends a read or a lookup (KnitBlueZ already does), and A11 has Android do the
      same. A pinned Android finds the doorbell in D at a stable handle, and reads the blinded payload as a stranger,
      as it does today.
    - A lookup that finds no doorbell within `doorbellSettleMilliseconds` (10 s on the monotonic clock) of the link's
      open, of a services change (`didModifyServices`) or of BlueZ's `ServicesResolved` is a failure the next ring
      retries, never `.absent`. Past the bound `.absent` stands, so an Android that serves no doorbell is not looked up
      at every ring. KnitBLE forgets a doorbell only when the invalidated services include its own. KnitBlueZ also drops
      a doorbell whose characteristic path BlueZ removes or whose write fails.
    - If the iPhone refuses two primaries with one UUID (the probe checks), the fallback is one combined service removed
      and re-added, and only if the probe shows the doorbell's handle comes back the same.
  - **The L2CAP channel is never republished at a rotation.** A republish has flipped the PSM between 192 and 193 and
    failed Android's dials for minutes (`bf171e6`), and every reader's cached PSM would fail once per rotation. iPhones
    mostly hold 192, so the PSM names little; it is a residual.
  - The value stays static, so bluetoothd answers reads while Knit is suspended. A dynamic value would wake Knit on
    every read, and like the doorbell, anyone in range could spend that.
  - **A restoration relaunch** removes the services it restored only once the radio is powered on, as `dropRestored`
    does for connections. Until then a restored service still holds the last process's value, which may be the clear id
    from before a switch flip. The order: note the restored services in `willRestoreState`; at the first power-on of
    the process, stop advertising and remove every service, once, keyed on a flag this process sets; when the radio
    expects to blind, add D and publish the listener after D's `didAdd`; then `serve()` adds P with the snapshot's
    value. A clear radio keeps today's order, publish then the combined service, since that service carries the PSM.
    The radio expects to blind when its factory says so (`BLERadio(expectsBlinding:)`, set from the same switch as
    `blindsAdvert`), when the layout it last served was split, or when a restoration returned two `0xFE30` services.
  - Advertising starts once, at the first served payload's `didAdd` (the first P, which follows D, or the combined
    service), never at every service's `didAdd`. Starting it at D's would let a reader connect while D stood alone,
    find no payload, and file us as a stranger for ten minutes.
  - **A reader may read the old P during a rotation's overlap.** For one `didAdd` round trip the server holds D, the
    old P and the new P, and a reader keeps whichever payload answers first. A contact still resolves the old tag, which
    sits inside its window of expected tags, and our responder honours a dial to our previous form (`dialedForm`). A
    stranger holds the old tag until the next edge's rule 4, or until a HELLO's `t` forgets it (rule 2). The overlap is
    milliseconds, so it is accepted.
  - A failed `didAdd` of a new P keeps the old one and retries at the next radio event, not at the next slot.
- **Rotation** ports `TagSchedule` (the persisted high-water mark per generation, and a random prefixed tag when no
  key or mark serves), `TagChoice` and `AdvertRotation`. A mark read that fails throws, as Kotlin's `MarkStore` does,
  and the tag is random: read as "no mark", it would restart the generation at the slot's first index and air again,
  from a new address, a tag already aired. The mark write moves only forward, a guard in both stores.
  - Rotation is announced: the coming slot's tag is reserved and sent as `TAG_NEXT` 210 s before the edge, and the
    rotation lands at the first wake at or after the later of the edge and reserve + 30 s.
  - A late wake rotates at once, unannounced, and the form just aired then goes once to each link.
  - Each bring-up is a rotation. iOS brings Knit up more often than Android: restoration relaunches, Settings' Stop and
    Start, and Bluetooth toggles. Past four in one slot, `TagSchedule` airs random tags that no contact resolves until
    the edge. The trial counts bring-up rotations, and if relaunches turn out to be frequent, a restoration relaunch
    within the slot it left keeps its tag.
  - The turn runs on `Mesh`'s scheduler from the wall clock, and is recomputed on `NSSystemClockDidChange`.
    `significantTimeChange` also fires at midnight, and only while Knit runs. Swift 6.4's Linux Foundation does not
    declare the name, so there `Mesh` observes the raw string and only the tests post it. A
    suspended iPhone rotates at its first wake past the edge, so its tag can be as old as the suspension, as an Android
    in Doze keeps its tag until its first wake.
- **The link.** While blinding, the HELLO carries `t`, the tag on the air. `TAG_NEXT` is a link record written beside
  the digest, so it never rings a doorbell. It goes only to a proven link whose HELLO carried `CAP_BLIND_ADVERT` and
  whose peer is neither blocked nor departed, at most once per link per two minutes (`TagNextSends`, `LinkFormNotes`),
  and only while our own key is held. A random tag aired with a key held (a failed mark, a fifth bring-up in a slot)
  is announced too, as Android announces it, so a linked peer attributes it by the link's claim instead of dialing it.
  It resolves to nobody else, and the peer already holds our id.
  `AdvertAliases` gets back the own-tag resolve step that sv5t left out. `AdvertOrder`'s `Mine` becomes the snapshot's
  current and previous forms. `TAG_NEXT` waits in `LinkOutbox` first in, first out, as Android's
  `FramedLink.sendTagNext` does, so a back-fill can carry the 210 s lead past the edge. That is parity, and it is
  counted.
- **Who dials** stays `AdvertOrder.iDial` on forms. A11 has Android read a GATT-sourced blinded form as it reads a
  blinded advert, with no rule of its own.
  - Toward a clear Android, the blinding iPhone always dials, as an iPhone whose id sorts above the Android's does
    today.
  - Between two blinding phones the larger tag dials, so the role turns every slot.
  - The iPhone's own overrides stand: ADR 2026-09.6es2's exception, ADR 2026-10.6eyf's head start and ADR
    2026-10.mueg's seeking.
  - A rule that had Android dial a GATT form whatever the order was weighed and declined. A backgrounded iPhone's UUID
    sits in the overflow area, so Android never hears it there and never reads its payload. Such a rule could act only
    while the iPhone is at the front, where it scans all the time and dials anyway, so it would only double the cross
    dials. In the background with no link, seeking dials whatever the order. With a link, nobody dials, as today.
    Against a blinding Android whose tag sorts higher, at the front, the head start covers both Android's dial and a
    reader's stale payload. It also covers an Android without A11, whose `FLAG_DIALS_GATT_PEERS` promises a read of a
    blinded payload that it cannot make.
  - sv5t's departure (a hint suppresses the iPhone's dials) and its safety net both stand. Android's held-link row
    stays inert toward a link whose HELLO carries `CAP_DOORBELL`, so a dial from the iPhone over a held link still
    meets Android's "already linked" refusal or its replace. The iPhone's new `RefuseHeld` heals the other direction:
    Android dialing our new tag after missing the announcement.
- **Admission.** While blinding, the iPhone takes Android's two blinding rows.
  - `RefuseLegacy` refuses a dialer whose HELLO lacks `CAP_BLIND_ADVERT` first, with no reply, and counts it.
    Android's `LegacyDialerBoost` is not ported. The iPhone scans all the time at the front and dials every clear
    advert, and seeking dials at the first sighting in the background. An old build reads a blinded payload as a
    stranger, so it can hardly find the iPhone to dial it.
  - `RefuseHeld` refuses a dialer whose proven link we already hold when its `a` names our tag, and resends our tag
    over that link instead. Every such dialer is refused. The resend goes only to a peer that may hear our tag, so a
    blocked or departed peer is refused with no resend, bounded by its own backoff until its held link ends, as xp6d
    has it. Without the refusal, an unsighted excluded peer's proven re-dial over a held link 30 s old would replace it,
    once per slot. The row skips a held link that is quiet (`heldQuiet`): no byte read for 90 s, counted only while the
    process runs, from the channel's read stamps, and stamped afresh at the front, at a ring and wherever the stall
    watch sees a late check (its own sign of a suspension).
    There is no probe and no keepalive: Android exempts a doorbell link from its own probe, and a probe would wake a
    suspended peer. A woken iPhone may judge the HELLO before it has read what queued while it slept, read a live link
    as quiet and replace it. That is one link swap, a bounded cost. Without `heldQuiet`, a held link dead on Android's
    side would refuse Android's dials until `WriteStallWatch` closed it, which is today's bound for "already linked".
- **Reading a blinded GATT payload.** `AdvertPayload(gattValue:)` reads one as a blinded form instead of a stranger,
  in KnitBLE and in KnitBlueZ, so two blinding iPhones and knit-peer's `ios --blind` find each other.
  - ADR 2026-09.xzpt's second forget rule then compares a HELLO's `t` with the payload's tag, or with a tag announced
    for that link, instead of the id. `Radio.heardHello(from:on:)` carries only the HELLO's id today, so `LinkManager`
    passes the `t` and the announced tag through it. The `ble forgetting the GATT payload of` line keeps its text,
    since harnesses read it.
  - A fourth rule: a blinded payload is forgotten after the first slot edge since it was read, 35 to 65 s past it
    (the 30 s minimum lead of an announced rotation plus 5 s, then up to 30 s of jitter), so each address costs at most
    one read per slot and no reader re-reads a writer's old tag in the 30 s it may still air it. Without it a reader in the foreground, where the address is never quiet,
    keeps the old tag until iOS rotates the address. A pair whose forms straddle the old and new tag then waits for the
    head start or for seeking. A11 mirrors the rule.
- **The bridge and the harness.** These exist only in a debug build:
  - `advert` reports the gates, whether the form is `clear` or a `tag` (never its bytes), the epoch, the next edge,
    any announcement or hold standing, the PSM, and each sighting's `iDial` and `linkedAs`.
  - `advert rotate` forces one rotation, guarded as Android's `ForcedRotation` is.
  - knit-peer gains `--blind`.
  - `interop.py` turns the iPhone's switch off for legacy runs and restores it afterwards.

Four alternatives were considered:

- **Staying receive-only (sv5t).** The iPhone would stay followable after N+1, and would ship keys only when it
  blinds, so a contact would recognise it only after one link following each fresh pair.
- **A dynamic characteristic.** This was declined above.
- **A local name or manufacturer data.** iOS drops both from a backgrounded advert, and a name shows in every scanner.
- **Waiting for the wire break.** knit-next's `NEXT_WIRE_BREAK.md` item 13 lists the iPhone's payload under the break
  but gives no reason it cannot be additive. It is additive: a shipped Android reads a flagged blinded payload as a
  stranger and never misdials it, and A11 teaches the new ones to read it.

**The Phase 3 probe settles what the design assumes of iOS.** Dongle B runs knit-peer's `ios` profile as a GATT client
of the iPhone, with btmon through `knit-hci`; a debug iPhone has the switch on; a Pixel on API 31 or later (and one below
it, if the lab has one) logs its HCI snoop. It checks:

- that the iPhone takes a second `0xFE30` primary (`didAdd` with no error, two primaries in dongle B's discovery);
- that D's doorbell handle stays the same across ten rotations, and P's handles before and after each;
- whether Service Changed is indicated to dongle B and to the Pixel at each rotation;
- that every Pixel `bt ring` after a rotation is matched by `ble rung by` on the backgrounded iPhone, with no `bt
  doorbell absent`;
- that accepted channels survive ten rotations;
- the iPhone's address before and after each re-serve (probably unchanged, a residual);
- whether an incoming L2CAP open resumes a suspended Knit;
- what a restoration relaunch serves before power-on, and how long D takes to come up;
- that no `ble matched an added service by order, not identity` line appears across the rotations, a Settings Stop and
  Start and a relaunch (if one does, the serials around it say whether iOS answers an add that a removal overtook);
- that a rotation landing mid-search logs `ble looks again at the services of`, and a ring still lands within the
  settle bound.

What one iPhone cannot probe: KnitBLE as the client of a blinding iPhone, the `didModifyServices` path between two
iPhones.

**Consequences / limits:**

- **Before A11, a blinding iPhone is a stranger to every Android**, contacts included, and only its own dials link
  it. That is why the debug default stayed off until A11 merged and its trial passed (Phase 7). An Android build from
  before `f018bc8ce` still meets a blinding iPhone that way.
- **A continuous observer can chain the iPhone's forms.** iOS rotates the address on its own schedule, which our slots
  do not follow, so an observer who never loses sight of the iPhone can link tag to address to tag. The PSM may stay
  across rotations too, until the probe says otherwise. What blinding removes is a stable name across gaps in
  observation: days, restarts and places.
- **A suspended iPhone's tag is stale** until its first wake past the edge. While it is stale it links the system's
  rotating addresses together. That is still better than today, where the id links them for good.
- **The links stay clear until #51.** A listener on a link reads the HELLO's id, its `t` and every `TAG_NEXT`. In
  release builds a ctl 11 at link-up also shows that listener the two phones are direct contacts, a cost the
  maintainer accepted, as Android's did.
- **A blinding stranger iPhone in the foreground can draw a dial burst** from an Android whose claim names an ended
  link, if A11 keeps `dialHeld` inert toward a doorbell link (the 2026-11-06 burst of 158 dials in 40 s). A11 keeps
  `dialHeld` for doorbell links. xp6d's worry that a held key outlives its link is bounded for an iPhone, which iOS
  moves to a new address about every 15 minutes even while Knit is suspended.
- **A debug build dates removals and blocks.** The bridge reports rotations and key generations, as Android's debug
  bridge does (xp6d, step 6). `status.presenceKeys.ownGeneration` is a wall-clock time, so it dates our latest mint,
  a block's fresh pair included. It reaches only the debug bridge and knit-peer. Debug builds are for development, not
  privacy.
- **A suspended iPhone's link-up delay** of 2 to 20 s does not run while Knit is suspended. A link that wakes it for
  about 10 s may end the wake before the first ctl 11, which then waits for the next wake. Phase 2 weighs drawing the
  delay from the low end in the background.
- **One release log line already dates a block.** `MeshEngine+Blocks.swift:172` logs a block by device tag in every
  build, against xp6d's step-6 rule. It is outside this change and owed as a follow-up.
- **knit-peer's `android` profile under `--blind`** airs the writer's payload as service data with `FLAG_BLINDED`, a lab
  stand-in that no trial covers. A pinned Android reads it as a stranger and does not dial it.
- **A new phone starts over.** The Keychain item does not migrate to a new device, and neither does the identity, so
  the new phone starts a new identity and generations restart with it.

**What keeps it true** (to be filled in as each phase lands): the policy and engine tests ported from
`PresenceKeyPolicyTest` and `PresenceKeyEngineTest`; the stores' and schema's tests; two-engine key exchanges (no ctl 11
before the session confirms; the peer resolves our tags; a resend under a peer's new root; a block's fresh pair that
the blocked peer never gets; a relaunch's one resend above `last`; a failed store unit that sends nothing; an unproven
link beside a proven one that gets nothing); a padded ctl 11 in `ios-emitted-v1.json` that Android's
`IosEmittedVectorTest` opens; ports of `TagScheduleTest`, `AdvertWriterTest`, `AdvertRotationTest`, `RotationTurnTest`,
`TagNextSendsTest` and the blinding rows of `BleAdmissionPolicyTest`; the LinkRig wiring with two blinding iPhones and
`BlindingPeer`; `check.sh release`'s marker for the debug gate; and the device trials A11 owes. On 2026-11-11, at
`6795964`, the lab iPhone passed the clear-mode `interop.py iphone`, the presence-key and block trials, a manual probe
of the split layout with the Pixel 9 (iOS took the second `0xFE30` primary; rings woke the backgrounded iPhone before,
across three forced rotations and after the flip back, with no second doorbell lookup), a slot edge, both flips (relinks
within 19 s and 41 s) and the guard's SIGKILL restore (`.agents/context/linux-peer.md`, "What the blinded-advert writer
showed"). The same afternoon the dongle runs passed: `iphone-forgets`, `android-rings --link accepted` and
`iphone-rotate`, whose one failure was its ring count. btmon on dongle B showed the doorbell at handle `0x0067`
through ten forced rotations and a slot edge. It also showed iOS indicating Service Changed twice at each rotation, for
the new payload service's handles and then the old one's, never the doorbell's ("What the writer's dongle runs
showed"). The iPhone's link to the Linux peer dropped at each of its address changes, and a clear-mode control showed
the same, so blinding is not the cause. On 2026-11-12 a cold launch and a restoration relaunch with the switch on each
removed the two restored services at the first power-on and served the doorbell's within 0.6 s, and `iphone-wake`
passed 10 of 10 with the iPhone locked across a slot edge ("What the writer's relaunches and the locked wake showed").
Both relaunches were forced, and they used two of the slot's three restarts. How often iOS relaunches Knit unprompted
is still unmeasured, so a relaunch still rotates. The Pixel 9's HCI snoop that night showed that the Pixel is told
of no rotation. It never subscribes to the iPhone's Service Changed, and it finds the handles again at each new
connection. For rings, the doorbell's fixed handle makes that safe.

Phase 1, our own keys (draft, 2026-11-11): `PresenceKeyPolicyOwnTests`, `PrekeyRingPresenceGenerationTests`,
`OwnPresenceKeyStoreTests`, `SchemaTests` (v24), `PresenceKeyFrameTests`, `LinkManagerProvenSendTests`,
`MeshEngineOwnPresenceKeyTests`, `OwnPresenceKeyLabTests`, and `carolPresenceKeysToBob` in `ios-emitted-v1.json`. Choices
the phase made that the text above leaves open:

- A pass spends no chain key toward a link that has not proved its id: `MeshTransport.hasProvenLink(to:)` is read before
  the seal, and `sendOverProvenLink` stays the one call that writes. A proof retires every unproven link for its id, so
  the call guards the time only a claimant's link stands.
- A DM open, a reset's adoption or a race's resolution that commits marks our pass owed when the session is confirmed and
  its root is not the one the ledger records for a linked peer that reads our keys, the answer to our own init among them
  (Kotlin's `rootChanges` reconcile). The heal still runs the pass whatever the revision says.
- Every committed seal settles the ratchet before anything else is decided.
- The ledger records the link a ctl 11 was queued on and when. When that link ends within the write-stall bound
  (`WriteStallWatch`'s stall plus one check), the record goes, so the next link's pass sends again; a copy that did arrive
  is an equal generation, a no-op to the peer, for one ratchet step.
- After a unit that held the settle failed, the settle sits out a minute: an owed pass opens no unit then unless the
  listing is due, and the end of the sit-out is a deadline the mesh wakes for. A failing store so costs the Keychain no
  write at every settle.
- A mint numbers above the larger of the item's `last` and every row's generation, so a row a lost item left behind is
  never inserted over.
- `TAG_NEXT`'s blocked set is every blocked id, and every direct-contact candidate or linked peer whose pinned device tag
  is blocked, read in the pass's unit.
- The memory store refuses a mark inside an open unit as the SQL store does.
- knit-peer with `--no-ratchet` keeps no prekeys, so no item to number in, and mints nothing.
- The mark's `NORMAL` that fails to restore is reported to the database's failures, not counted in `status`.
- `status.presenceKeys.ownGeneration` is a wall-clock millisecond value that dates our latest mint; it reaches only the
  debug bridge and knit-peer.

Phase 2, the link-layer writer (draft, 2026-11-11): `TagScheduleTests`, `AdvertWriterTests` (with `TagChoice`),
`AdvertRotationTests`, `TagNextSendsTests`, `BlindAdmissionRowTests`, `AdvertAliasesOwnTagTests`, `GattPayloadsTests`' blinded
cases, `BlindWireTests`' `t` and flag cases, and on `LinkRig` `BlindWriterTests`, `BlindWriterTurnTests`,
`BlindWriterAdmissionTests` and `BlindWriterPairTests`; `MeshBlindWriterTests` through the actor; `BlueZGattBlindedTests`
replaces `BlueZGattRetryTests.aCharacteristicThatHoldsABlindedPayloadIsAStranger`, and `BlindWireTests`'
`aGATTValueReadsABlindedFormWithItsPrefixOnly` replaces `aGATTValueIsNeverBlinded`. Choices the phase made that the text
above leaves open, or where it departs from the Kotlin:

- The gate is `LinkManager.Configuration.blindsAdvert` (the build may blind) and `setBlinding(_:)` (the runtime switch, on
  until turned off). With either off, or no `PresenceKeySource` attached, the forms are clear and nothing here runs.
- The turn never holds: Android holds a due rotation for a Coded fast window, a hunt, a dial of its own or an ACL edge's
  settle, none of which an iPhone has. `RotationTurn`'s loop is a deadline the `Mesh` timer wakes for; with nothing
  blinded on the air there is none.
- Each `.listening` with nothing on the air is a bring-up. A `.listening` while the forms are up on another PSM re-points the
  snapshot under the same forms, with no rotation.
- A key change is held at once for the next tag and taken at the next advance, never inside `ownPresenceKeyChanged`, which
  may come inside a store unit where `writeMark` answers `insideUnit`.
- `TAG_NEXT` goes whenever a key is held, as Android's does (`BluetoothMeshTransport.kt:1626`): a random tag on the air (a
  mark that will not read or write, a slot out of restarts) is sent too, so a linked reader attributes it to the link
  rather than dial it. With no key held nothing is sent.
- `RefuseHeld` refuses every dialer that meets the held-link row; only the resend is withheld from one `hearsTagNext`
  excludes (xp6d, step 5b's B2), so an excluded peer's re-dials cannot replace a held link 30 s old at each rotation. Its
  quiet is 90 s with no byte read on the held link, re-stamped when Knit comes to the front, when its doorbell rings, and
  when `WriteStallWatch`'s check finds it fired late, its own sign of a suspension.
- A mark read that fails throws (`PresenceMarkReadFailure`), never reading as "none", as Kotlin's `MarkStore.read` throws:
  `TagSchedule` caches nothing for it and `TagChoice` airs a random tag (`markFailed`). Both stores write a mark only when
  it moves forward (a later slot, or a later restart in the slot), answering `refused` otherwise, so no write can move it
  back over pairs aired.
- A blinded advert no longer counts as service data (`isServiceData`): a blinding iPhone's GATT payload is blinded, and its
  link must keep the write-stall exemption while iOS holds it suspended. Every build that blinds proves its id, so no fork
  can claim `CAP_DOORBELL` under a blinding Android's id.
- `GattPayloads`' rule 4 forgets a blinded payload 35 to 65 s past the first slot edge after its read: a slack of
  `AdvertRotation.minLeadMilliseconds` and 5 s, since an announced rotation lands at the later of the edge and its
  announcement plus 30 s, and a reader sooner would keep the old tag a whole slot; the jitter is drawn per read from a seed
  each radio draws at random. A link or a read holding the address keeps it, as rule 3 does, so it goes at the first check after the
  link ends; a wall clock set below the read's forgets it. Rule 2 compares
  a blinded payload with the HELLO's `t` or the tag that node announced; a tag dial's reply reaches the radio only once its
  proof verified. A11 is to mirror both.
- `NSSystemClockDidChange` is observed in `Mesh` (`Mesh+Clock.swift`), as the radio's events are, and handed to the links as
  one more entry. Linux's Foundation does not declare the name, so there the observer listens for the raw name and nothing
  posts it. `LinkManager.Configuration.clockChangeName` lets a test name a notification of its own, so its post reaches no other
  mesh.
- `TAG_NEXT` is written from `LinkManager+TagNext.swift`, not beside `sendDigest`, to keep `LinkManager.swift` inside its
  length limit; it is a plain record behind whatever the link holds, counted when it waits.
- `LinkFormNotes` keeps each link's announced form and applies it at its edge (a deadline), checked against
  `AdvertAliases.stillAnnounced`; nothing reads the link's form yet but the debug bridge's `advert` (Phase 4).

Phase 3, the radios (draft, 2026-11-11): `GattServingTests` and `GattServingBlindedTests` (the server's layout as steps),
`GattSweepTests`, `DoorbellLookupTests`, `BlueZBlindLayoutTests`, and `PeerRatchetTests.blindingIsOffUnlessAsked`. KnitBLE's
wiring compiles only on the Mac and is proven only by the probe. Choices the phase made that the text above leaves open:

- The server's state is `GattServing`, a pure type in `KnitMesh/Link` whose steps `BLECore+Serving.swift` carries out; the
  services are kept by serial, and a `didAdd` is matched to its service by the object CoreBluetooth hands back, or else to the
  oldest add still owed an answer, after dropping every answer older than the oldest the server waits on (`oldestOwed`); the
  fallback logs `ble matched an added service by order, not identity`, which the probe expects never to see. One split add is
  in flight at a time. A clear form keeps the old code's steps exactly: stop
  advertising, remove every service, add the combined one, advertise at its `didAdd`.
- Advertising starts at the first P's `didAdd`, which follows D's, not at D's own: a reader that connected while D stood alone
  would find no payload and leave the iPhone alone for ten minutes as a stranger.
- The radio learns the form from the link manager's first advert, which follows `.listening`, so D comes before the publish
  only when the radio expects to blind: `BLERadio(expectsBlinding:)`, which Phase 4's factory sets from the same persisted
  switch as `blindsAdvert`; the layout this process last served (a stop and start, a power cycle); or a restoration that
  handed back two or more `0xFE30` services. A restoration only ever upgrades to the split layout: one restored service says
  only that the last process was clear, while the expectation reads the switch as it is now, and following the old process
  would reopen the gap the expectation closes. The advert still decides the layout
  served, so a clear advert under an expectation to blind rebuilds to the combined service. A radio that expected neither and
  blinds publishes first and serves D, then P, at the first advert; a peer that dials a cached PSM in between meets the settle
  bound. A restoration logs its services' count only when it was a blinding process's, so a clear restoration logs as before.
- The first power-on's clear is armed again at every stop and power-off, when nothing of ours is served, so a power cycle
  never adds beside services iOS kept.
- A flip to clear takes the clear path, whose removal of every service takes D and P. A flip to blinding stops advertising and
  removes the combined service by reference, after its `didAdd` if that is still owed.
- A failed split add is tried again at the first ring, accepted channel, connection or advert at least a second later, never
  in a loop at every advert.
- KnitBLE asks every `0xFE30` service for both characteristics in every search, so whichever search's discovery answers
  first holds what the other looks for (`GattSweep`). A lookup always lists the services itself, even beside a payload read.
  It forgets a doorbell found absent at any services change. A lookup or a read whose search waits on an invalidated service,
  or on the list, lists the services again (`GattSweep.waitsOnAny`), keeping the rings that wait: CoreBluetooth may never
  answer a discovery asked of a service that went, and the lookup would otherwise hang for the connection's life.
- KnitBlueZ's bound runs from `ServicesResolved`, from any GATT object BlueZ removes under the device and from any `0xFE30`
  service it adds there; either also forgets a doorbell found absent.
- knit-peer's `--blind` sets `blindsAdvert`, whose switch starts on (superseded in Phase 4: the gate is always open and
  `--blind` sets the switch). The `ios` profile answers each read with the advert of
  the moment, so a rotation moves the value under one characteristic and re-registers only the advert; no Linux run moves a
  handle. The `android` profile airs the tag as service data, with Android's flags.

Phase 4, the gate, the bridge and the harness (draft, 2026-11-11): `BlindWriterBridgeTests`, `GattServingReportTests`,
`MeshControlAdvertTests`, `PeerAdvertTests`, `LaunchBlindTests`, and `test_interop.py`'s `IPhoneAdvertTest`, `IPhoneRotateTest`
and `BlindingIPhoneTest`. The app's factory and bridge compile only on the Mac. Choices the phase made that the text above
leaves open:

- The switch at construction is `LinkManager.Configuration.blindSwitchOn`, apart from the gate. A debug build passes the gate
  open and the switch from `-blind on|off`, or the word `debug.launch.blind` keeps, or `LaunchOptions.blindDefault` (off), and
  the same value to `BLERadio(expectsBlinding:)`, from the one branch that logs `the blinded advert writer is on in this debug
  build`; `check_release_app` fails a store build holding that line or the key. knit-peer always opens the gate, and its
  `--blind` sets the switch, which Phase 3 had set the gate from.
- A flip with the radio up closes every channel past its dial, live or in its handshake, logging `link chN closed: the advert
  flipped to a tag|the id`, before it rotates, so the rotation's form goes to no link it is about to close. The downs reach
  the mesh at the next entry, as a proof's closes do. A dial still opening is left: its HELLO is written under the new form.
  Both harnesses' channel-ending tables read the line as the switch's, never a fault of either end.
- `advert` is `MeshControl`'s, so knit-peer answers it too; the host keeps the switch (`AdvertHost`: the app's defaults,
  knit-peer's memory) and reports its radio. The app's report is `GattServingReport`, read on the CoreBluetooth queue: the
  layout, the D, P, combined and pending serials, `advertising`, `retryAt`, `cleared`, `doorbellFailed`, whether the served
  payload carries the wanted advert, the listener's and the advert's PSMs, `expectsBlinding`, the restored `0xFE30` count, and
  the count of adds matched by order. Never a value. `advert blind on|off|clear` stores, flips, and waits up to about 6 s for
  `applied`: the form on the air is what the writer should air, and the radio serves it (P and D with no add in flight, or the
  combined service) and advertises; else `why` (`transport not running`, `radio down`, `no mark store`, `pending`,
  `timeout`, or `build` from a host whose gate is shut).
- `advert-rotate` refuses, in Android's order, `radio down`, `clear`, `announced`, `grace` (a payload add in flight on the
  radio, or an install under 5 s ago, `LinkManager.forcedRotationGraceMilliseconds`) and `throttled`. Android's `pending`,
  `settling` and `holding` have no iPhone counterpart (a tag is chosen and installed in one call), and the reply has no
  `holding`. The reply carries `restartsLeft`, read
  from the mark the schedule last read or wrote, and `bringUpsInSlot`.
- A sighting is shown by its node id or its handle (`~zzzz…<n>`, a per-process counter); a link's form by its kind
  (`blinded`, Android's name). The last install's cause, time and tag facts (source, resolvable, stale) are reported.
- `interop.py` holds the iPhone's switch off for every run that drives it and judges ids (`IPhoneAdvert`), unless
  `--keep-blind`; it leaves a switch already off alone, notes what it found in `~/.local/state/knit/interop-iphone-advert.json`
  before it moves one, restores from that note first at the next run, brings Knit to the front with devicectl before it
  restores, and prints the bridge line to run by hand when it cannot. `bridge`, `record-pull`, `iphone-reboot` and
  `iphone-rotate` are left out: the last holds the switch on itself. With `--keep-blind`, a blinding iPhone toward a clear
  phone must dial it, refuse nothing as legacy and be refused nothing, and `--edge-wait` judges an announced rotation the phone
  took across an edge. `iphone-rotate` is the probe's scripted part.

Phase 7, the debug default (2026-11-12): `LaunchOptions.blindDefault` is true, so a debug build with no `-blind` and no
kept choice starts with the switch on. It waited on A11, merged to knit-next's `main` as `f018bc8ce`, and on its trial,
run `70c5df` (`.agents/context/linux-peer.md`). Release builds stay clear: the `#else` factory
(`AppEnvironment.blindAdvert`) shuts the gate and passes the switch off whatever `LaunchOptions` reads, and
`check_release_app` fails a store build holding `debug.launch.blind` or the factory's debug line. knit-peer's `--blind`
still starts off, so a Linux run that judges ids gets them unasked. A lab iPhone with no kept choice now blinds after an
install, so a run that judges ids flips it to its id at the start and back at the end (`IPhoneAdvert`), and several
of those runs stop the mesh within a minute of the flip. A flip, then a mesh stop 25 s later, is where knit/knit-ios#53
was seen: the next start's PSM had no bluetoothd endpoint, and no run but `iphone-blind-reads` checks for that. So a
lab iPhone that runs those keeps `-blind off`, which spares the flips. A soak (`scripts/soak.py`) leaves a blinding
node out too. Guards: `LaunchBlindTests` and `scripts/check.sh release`.
