---
id: "2026-11.prsp"
slug: the-iphone-airs-a-rotating
title: "The iPhone airs a rotating tag and sends its own presence keys"
date: 2026-11-11
topics: [ble, mesh, privacy, wire, crypto]
---

# ADR 2026-11.prsp — The iPhone airs a rotating tag and sends its own presence keys

Status: Proposed (2026-11-11). Mirrors the writer half of knit-next ADR 2026-11.xp6d (its steps 5b Part A, Part B1,
Part B2 and 6) at the pin `cad69c77b`: the rest of knit-ios #42. Companion change A11 in knit-next
(`.agents/memory/roadmap.md`). Once accepted it amends ADR 2026-11.sv5t (the iPhone sends keys), ADR 2026-09.xzpt (a
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
  on a link reads the HELLO's id, its `t` and `a`, and every `TAG_NEXT`.

**Decision:**

- **Two gates, as Android's two flags.**
  - `MeshConfiguration.sendsOwnPresenceKeys`, Android's `PRESENCE_KEYS`, is on in every build, release included. The
    maintainer chose this on 2026-11-11, reversing sv5t's receive-only choice, so that contacts already hold the iPhone's
    keys on the day its writer ships. With it off, nothing is minted, rotated or sealed, but leavers' stored keys are
    still deleted.
  - `LinkManager.Configuration.blindsAdvert`, Android's `BLIND_ADVERT`, is set only in a debug build (`#if DEBUG` in the
    app's factory). A release build passes false and has no switch. A debug build has a runtime switch: the `-blind
    on|off` launch flag, kept in UserDefaults, and the bridge's `advert` command. Its default is **off until A11 merges
    and its trial passes**, then on, by an amendment here. The two gates are independent. A debug iPhone with the
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
      whose link has proved the id. It is not a check followed by `send(to:)`: that picks the first live link for the
      id, and an unproven claimant's link can sit beside the proven one. A false answer forgets that peer's ledger
      entry, as Android's `onSendFailed` does.
  - **What each linked contact is owed** is kept in memory, per peer, under the root its last ctl 11 was sealed with
    (read in the seal's unit). The first pass of a session trims the ledger to the direct contacts. It is reconciled at
    link-up after the 2 to 20 s delay, at a key change, at heal, and when a peer gains a bit it needs. The heal runs our
    own key's pass whatever the feed's revision says. That catches the weekly, clock and mark advances, and also the
    resend after a root change, which this port has no hook for.
  - **A pass runs in this order:**
    1. One store unit settles: the direct contacts, `due` and its rows, the leavers' stored keys, and the departed set.
    2. After `.committed`, our own key and the departed set are published, guarded by the session's epoch, so a pass
       begun under an earlier session publishes nothing.
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
  - **A rotation adds before it removes.** The doorbell is a characteristic of the same `0xFE30` service, so a
    rotation never calls `removeAllServices`, which `stop()` alone keeps. It adds the new service, then removes the old
    one by reference once `didAdd` lands.
    - Every ring client marks a link "no doorbell" for its whole life when a lookup finds no service: KnitBLE's `.absent`,
      KnitBlueZ's `BlueZLoop+Doorbell.swift:73`, and Android's `BleDoorbell.lookUp`. A remove-then-add at every slot
      would let one lookup in the gap end every ring to a suspended iPhone on that link.
    - For the same reason, a lookup that finds no `0xFE30` service within a few seconds of a services change is a
      failure to retry, never `.absent`, in KnitBLE and KnitBlueZ, and in A11 for `BleDoorbell`.
  - **The L2CAP channel is never republished at a rotation.** A republish has flipped the PSM between 192 and 193 and
    failed Android's dials for minutes (`bf171e6`), and every reader's cached PSM would fail once per rotation. iPhones
    mostly hold 192, so the PSM names little; it is a residual.
  - The value stays static, so bluetoothd answers reads while Knit is suspended. A dynamic value would wake Knit on
    every read, and like the doorbell, anyone in range could spend that.
  - **A restoration relaunch** removes the services it restored only once the radio is powered on, as `dropRestored`
    does for connections. Until `serve()` runs, a restored service still holds the last process's value, which may be
    the clear id from before a switch flip.
- **Rotation** ports `TagSchedule` (the persisted high-water mark per generation, and a random prefixed tag when no
  key or mark serves), `TagChoice` and `AdvertRotation`.
  - Rotation is announced: the coming slot's tag is reserved and sent as `TAG_NEXT` 210 s before the edge, and the
    rotation lands at the first wake at or after the later of the edge and reserve + 30 s.
  - A late wake rotates at once, unannounced, and the form just aired then goes once to each link.
  - Each bring-up is a rotation. iOS brings Knit up more often than Android: restoration relaunches, Settings' Stop and
    Start, and Bluetooth toggles. Past four in one slot, `TagSchedule` airs random tags that no contact resolves until
    the edge. The trial counts bring-up rotations, and if relaunches turn out to be frequent, a restoration relaunch
    within the slot it left keeps its tag.
  - The turn runs on `Mesh`'s scheduler from the wall clock, and is recomputed on `NSSystemClockDidChange`, which
    Foundation posts on Linux too. `significantTimeChange` also fires at midnight, and only while Knit runs. A
    suspended iPhone rotates at its first wake past the edge, so its tag can be as old as the suspension, as an Android
    in Doze keeps its tag until its first wake.
- **The link.** While blinding, the HELLO carries `t`, the tag on the air. `TAG_NEXT` is a link record written beside
  the digest, so it never rings a doorbell. It goes only to a proven link whose HELLO carried `CAP_BLIND_ADVERT` and
  whose peer is neither blocked nor departed, at most once per link per two minutes (`TagNextSends`, `LinkFormNotes`).
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
    over that link instead. It applies only when the dialer is neither blocked nor departed. It skips a held link that
    is quiet (`heldQuiet`): no byte read for 90 s, counted only while the process runs, from the channel's read stamps.
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
  - A fourth rule: a blinded payload is forgotten at the first slot edge after it was read, with jitter, so each
    address costs at most one read per slot. Without it a reader in the foreground, where the address is never quiet,
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

**The Phase 3 probe settles what the design assumes of iOS** (dongle B's scan and btmon through `knit-hci`, a debug
iPhone with the switch on, a Pixel on API 31 or later and an older one if the lab has it):

- whether a service add-and-remove or a stop and start of advertising changes the address (probably not, a residual);
- whether the ATT handles stay put across a re-add, and whether Service Changed reaches Android, below API 31 and from
  it, and an iOS central;
- whether accepted channels survive a re-add;
- whether an incoming L2CAP open resumes a suspended Knit;
- what a restoration relaunch serves before `serve()` runs.

**Consequences / limits:**

- **Before A11, a blinding iPhone is a stranger to every Android**, contacts included, and only its own dials link
  it. That is why the debug default stays off until A11 merges.
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
  bridge does (xp6d, step 6). Debug builds are for development, not privacy.
- **One release log line already dates a block.** `MeshEngine+Blocks.swift:172` logs a block by device tag in every
  build, against xp6d's step-6 rule. It is outside this change and owed as a follow-up.
- **A new phone starts over.** The Keychain item does not migrate to a new device, and neither does the identity, so
  the new phone starts a new identity and generations restart with it.

**What keeps it true** (to be filled in as each phase lands): the policy and engine tests ported from
`PresenceKeyPolicyTest` and `PresenceKeyEngineTest`; the stores' and schema's tests; two-engine key exchanges (no ctl 11
before the session confirms; the peer resolves our tags; a resend under a peer's new root; a block's fresh pair that
the blocked peer never gets; a relaunch's one resend above `last`; a failed store unit that sends nothing; an unproven
link beside a proven one that gets nothing); a padded ctl 11 in `ios-emitted-v1.json` that Android's
`IosEmittedVectorTest` opens; ports of `TagScheduleTest`, `AdvertWriterTest`, `AdvertRotationTest`, `RotationTurnTest`,
`TagNextSendsTest` and the blinding rows of `BleAdmissionPolicyTest`; the LinkRig wiring with two blinding iPhones and
`BlindingPeer`; `check.sh release`'s marker for the debug gate; and the device trials A11 owes.
