---
id: "2026-11.adrq"
slug: text-dms-ride-spool-relays
title: "Text DMs ride spool relays, in debug builds until approved"
date: 2026-11-16
topics: [scope, transport, spool, interop]
---

# ADR 2026-11.adrq — Text DMs ride spool relays, in debug builds until approved

Status: Accepted (2026-11-16)

**Context:** Knit for Android has carried conversations across the Internet since 2.4.0 (knit-next ADR 064), through
spools: small relays that keep, per conversation, a bounded set of frames sealed under keys the members derive and the
relay never holds (`docs/SPOOL_PROTOCOL.md`). Every Android phone seeds the house relay
`wss://public-1.spool.getknit.app/spool/v1`. ADR 2026-09.zwdp left spools out with Android's other planes, and the
roadmap listed them under "Never on iOS". So an iPhone and an Android phone out of radio range exchange nothing, even
with both online. zwdp's reason for leaving Wi-Fi Aware out, a pairing ceremony per pair of phones, never applied to a
spool: a spool is a WebSocket to a URL.

**Decision:** the iPhone carries **text DMs** through spools, in debug builds until the maintainer approves the plane
for the store (the maintainer's call, 2026-11-16, with DMs first and group scopes a later phase). It speaks Android's
protocol byte for byte and needs no Android change.

- **What it speaks.** The record layer (§7.1–7.2: `hello`, `sub`, `digest`, `list`, `pull`, `blob`, `push`, `event`,
  `ok`, `err`), DM scopes (§3.1), the deterministic seal `0x01` (§4.3), the frame-set rule (§4.4), the heal loop with
  its invalid and accounted sets (§9.1–9.4, §9.6) and proof of work on demand (§8, knit-next ADR 2026-10.rn9j). HELLO's
  advertised limits are claims, clamped as knit-next ADR 025 clamps them.
- **The DM frame-set rule is the Kotlin's.** A `chat` between exactly the scope's two members, sealed v2 **or v3** with
  the ratchet header, or a `profile` from either. The spec's C-4.4-7 says v2 alone; `ScopeFrames.eligibleForDm` takes
  both, and the Kotlin wins (`.agents/rules/interop.md`).
- **Scopes come from the session root, on demand.** `pairwiseRoot = HKDF(root, "knit/dm/v2/export/root")` from the
  `root` and `prevRoot` the session already stores, so no column and no migration. It is derived for confirmed sessions
  only, Kotlin's `exports` rule unchanged, since two phones meet only in a scope both derive (knit/knit-next#290 bears on
  that rule). A `prevRoot` inside its drain is a retiring scope, pulled but never refilled. The roots never leave
  `KnitMesh/Ratchet`: the plane gets a scope id, a seal key and a nonce key. `/export/epoch` and `sendEpochExport` stay
  out; they are reserved for a seal version 2 nobody sends.
- **Our own unanswered reset exports nothing yet** (P2's design pass, 2026-11-16). Android keeps the replaced root's
  scope for it and refills that scope with the reset alone (knit-next ADR 2026-10.j67x), and that exception needs two
  ratchet rules this port has not taken: the slot a second re-root keeps, and the race an old era's own init must not
  start. Without them a relay-only pair could go dark or split onto two roots, so the exception lands with both rules
  as one unit, a crypto phase of its own. Until then a reset this iPhone sends reaches a relay-only peer over the
  radios alone.
- **The spool mirrors custody, both ways.** Each live custody frame a scope's rule admits is sealed and pushed when the
  spool lacks it: our own text, the sealed ✓✓ receipt (ctl 5, already carried) and the republished profile, which is
  how a relay-only contact learns a rotated prekey. A pulled frame that opens, verifies against the pinned key and
  passes the rule enters as a re-served copy (ttl reset, hops 0). The SeenSet dedupes it, it never counts as a radio
  overhear, and it is relayed onto the radios, so one online iPhone bridges the phones around it (§9.4).
- **Relays.** `public-1` is seeded; the person adds others by invite link (`https://getknit.app/r#…` or `knit://r/…`,
  `docs/RELAY_INVITE.md`), applied only after a consent sheet, with the commons fields `c`/`n` and Knit Anywhere's
  `i`/`k` ignored. A master switch, off until the person consents, runs the plane; a per-relay park keeps a relay
  without using it (knit-next ADR 063). The list lives in `AppPreferences`, but a private relay's `?k=` URL, token and
  all, lives in a Keychain item, `AfterFirstUnlockThisDeviceOnly` (ADR 2026-09.tkww): `UserDefaults` is backed up and
  sits outside the database's protection. Android keeps the token in the clear (knit-next ADR 2026-09.66cw); the
  security review of P1 moved it here (2026-11-16). A URL is redacted wherever it is shown. Release refuses `ws://` at
  entry and again at dial (C-7.1-2).
- **An invite's relay URL is plain.** Its bytes are printable ASCII and its authority names a host alone, with no `@`
  and no `\`, so the host a person is shown is the host the socket dials (P1's security review).
- **One gate.** `spoolEnabled` is `DEBUG` and the switch. The plane, the settings row and invite handling read it, and
  `check.sh release` fails a store build that carries the plane, as it does link cards (ADR 2026-11.hcvg).
- **No scope config is sent.** The iPhone never sends ctl 7, so Android counts it undeclared and keeps the pair on
  `public-1` (knit-next ADR 2026-10.8kfx), where every Android home is while the directory read is off. A received
  ctl 7 still advances the chain and applies nothing, as older Android builds do.
- **Nothing else moves on the wire.** No capability bit, no frame type, no schema change in the DM phases.
- **Where it lives.** The codecs in `KnitWire/Spool` (the security reviewer's); scope crypto and proof of work in
  `KnitCrypto/Scope`, and `RatchetSessions+Scopes` (the crypto plane's); the pure plane in `KnitMesh/Spool` (the
  blobs plane's, since it is custody's anti-entropy, and the security reviewer's, since a spool is a hostile server);
  the WebSocket in a new `KnitSpoolNet` target, which builds on Linux so a test can drive a real daemon. No new plane
  or persona: this port has no spool fix history to write a reviewer from (`.agents/rules/owners.md`).
- **Not in this decision:** group scopes (the group root and its gossip), pair scopes for card-only contacts, the
  typing signal lane, attachments, the commons, homes and the directory, restore anchors, and all of Knit Anywhere
  (tickets, TURN and STUN, calls, casts, badges, device proofs).
- **The alternatives, and why not:**
  - **The spool as one more radio under `LinkManager`,** the shape a reader reaches for first. A spool is no node: it
    has no identity, holds sealed blobs per scope rather than frames, and converges by digest against custody. Under
    `LinkManager` it would take a link's admission, ingress budget and overhear rules, all built for a neighbour.
    Android keeps it outside its transports too (`TransportKind.Other`, source `"spool:<url>"`).
  - **A queue of our own sends.** The spool's digest folds the scope's whole set, so a member that pushes only its own
    frames never matches it, lists every round, and bridges nobody.
  - **All of Android's plane at once.** Group scopes need the group root's mint, adoption, re-mint and gossip, a crypto
    phase of its own, and the rest is not text.

**Consequences / limits:**

- **Foreground only.** The sockets open while a scene is active and close when Knit goes to the background, and the
  spool has no push. A relay DM to an iPhone arrives the next time Knit is open, with no notification before then.
  Background refresh is a later phase, and copy must name the boundary (`.agents/rules/copy.md`).
- **Confirmed sessions only.** A contact whose session never confirmed, first contact included, cannot be reached by
  relay until pair scopes land, and neither can one whose reset this iPhone sent and the peer has not answered. Groups
  stay on Bluetooth.
- **Two roots stay two roots over the relay.** A pair split by a race and a restore, which Kotlin reclaims through its
  abandoned init and this port does not (ADR 2026-10.5sk9, knit-next ADR 2026-10.4mjm), derives disjoint scopes, so it
  stays split until the radios meet and a reset heals it.
- **What a spool sees** (spec §10): scope ids, blob sizes, timings and the phone's IP address, never node ids or
  content. `public-1` is run by the Knit project.
- **Proof of work** costs about a million SHA-256 rounds per new scope per day at the spool's usual 20 bits, mined off
  the `Mesh` actor and refused above 24 bits.
- **The pin.** The spec and the Kotlin were read at knit-next `0832b8462`; the port's pin stays `f018bc8ce`. Two spool
  commits sit between them: `2c32655bf` (the re-anchor only over the digest the listing ran against, knit-next #322),
  which this port follows, and `809cc9643` (restore anchors), which it leaves out. §13's vectors are identical at both.
- **What keeps it true:** `Tests/Vectors/spool-v1.json`, which `sync-vectors.py` reads out of §13 and
  `RELAY_INVITE.md` §5 and `--check` compares; the vector suites that pin scope ids, the seal, the digest, proof of
  work and every record; two-engine `EngineLab` tests over a fake spool; `check.sh spool` against the reference daemon
  (`knit-spool`); the release gate; and `PersonaTests` for the reviewers' paths. `.agents/context/spool.md` holds the
  constants, the file map and the trials.

**Amended 2026-11-16 (P3's design passes, before any of P3 was written):**

- **The plane spends only on people the person accepted.** A DM scope is subscribed, pulled, pushed into and mined for
  only while its peer is accepted (an accepted or authored conversation, or a verified contact, as the stores persist
  them) and not blocked. A store that cannot answer keeps the table as it stands. This port subscribes only accepted
  peers. The pair still meets: the peer's pushes wait at the spool,
  inside its 48 h retention, until the person accepts. The gate decides per scope, never per frame, so a scope's fold
  stays the spool's. Blocking a peer drops its scopes.
- **At most 128 peers have live scopes,** live scopes ranked before retiring ones, then by this phone's own record of
  recent activity, never a peer's `sentAt`. A spool's `maxScopes` can only lower the cap.
- **A late frame is delivered here and never bridged.** A pulled frame past `sentAt + 48 h`, or more than five minutes
  ahead of this phone's clock, is accounted and never relayed onto the radios: a spool can serve a frame long after the
  router's memory of it is gone.
- **A held frame that is never pushed leaves the local fold.** A retiring scope's frames, our own flagged reset, and a
  frame the spool tombstoned or refused are kept per scope (at most 512) and left out of the fold until a listing names
  the id again, so a converged scope stops listing. Kotlin keeps them in the fold (knit/knit-next#188).
- **Our own flagged reset is never pushed,** into a live scope or a retiring one: `mayRefill` with no reset exception.
- **A cold launch re-pulls once.** The accounted set lives in memory, as C-9.6-4 allows, so a cold launch re-pulls what
  custody no longer holds, at most a scope's 400 per relay, and delivers it again. Neighbours' custody refuses the late
  ones, so the cost is airtime.
- **P3 lands in two parts:** P3a, the connection, backoff and the fake spool's record layer; P3b, the frame rules, the
  heal loop, the scope table and the convergence tests.

**Amended 2026-11-16 (P3a, the connection; a draft until the maintainer accepts it):**

- **A connection reads only what answers it.** `SpoolSession` drops every record before the spool's `hello`, and a
  `digest`, `event`, `blob` or uncorrelated scoped `err` for a scope not subscribed on that connection, before anything
  reads it. An `err` whose `scope`
  names another scope than the request its `q` names answers nothing and refuses nothing, and neither does an `err`
  whose `q` this connection issued but whose request is over: a late answer moves no subscription. `ok.missing` is held
  to the ids the pull named and was not served. None of it changes what either side sends: a conforming spool never
  trips them.
- **A `sub` cannot strand its scopes.** A `sub` answered by an `err` with its `q` and no scope (the daemon's `internal`,
  or `malformed` past its own `maxScopes`), or not answered within 30 s, forgets each scope it named that has no anchor
  yet, so the heal loop subscribes it again on its next round.
- **A pull streams.** Each named blob reaches the heal loop as it lands, so a pull holds at most one blob and its ids,
  never 256 × 64 KiB; one that times out has delivered what came. A named blob
  past the declared `maxBlob` comes back as an id the heal loop quarantines in its invalid set (§9.3), as Kotlin's
  `PullOutcome.oversize` does.

**Amended 2026-11-17 (P3b, the frame rules and the heal loop; a draft until the maintainer accepts it):**

- **What a relay will never take leaves the local fold.** The unpushable set takes a held frame the listing leaves out
  when it is tombstoned there, refused by `mayRefill` (a retiring scope, our own flagged reset), past the tighter
  `maxBlob`, dead on arrival in a 48 h scope, refused per blob, or too large for a `push` the session can send. A listing
  that names the id puts it back. An id that went in for a listing reason leaves as soon as a listing shows the reason
  lapsed (a tombstone let go, a scope shed), and is pushed again; a push the relay refused as `too_large` or `bad_id`, or
  one past its `maxRecord`, stays refused. A pushable frame never goes in.
- **Accounting at the listing.** A listed blob this connection delivered that custody no longer holds is accounted when
  the listing names it, and so is one the round's custody read predates but custody now holds, which the fold never
  counts twice (held ids are never folded from the accounted set). A blob this connection never took is re-pulled once,
  and accounted when custody refuses it.
- **A dirty scope heals at most once per 5 s,** whatever marked it; the 60 s tick heals every scope.
- **A relay's pulls are budgeted to 16 MiB an hour.** A pull goes only while its worst case (every id at our own
  `maxBlob`, the bound the session enforces on a pulled blob) fits what the hour has left, and is charged that when it
  goes; an arrival past it is charged at once, the unused part comes back when the pull ends, and a blob served past our
  `maxBlob` is charged in full. Nothing starts the hour over but the hour.
- **The `unopenable` fault.** A blob that does not hash to its id, or one served past our `maxBlob`, counts against the
  relay: 32 in an hour, more than blobs that hashed true, end the session as `unopenable`, a fault word of this port's
  own, which counts as an unreached session for the backoff. A blob that hashes true and then fails to open, decode, fit
  the rule, verify or pass the carry gate is not counted against the relay: a pulled one is quarantined, a live one
  released.
- **Parks and stamps.** A `sub` refusal under `quota` or `pow` parks the scope for the session's clamped
  `parkMilliseconds`, and a refused stamp on a push parks it the same way; any other refused push parks nothing. At most
  two stamps are mined per scope per UTC day, counting only searches that found one; past them the scope parks until the
  day rolls. A search that found none parks the scope for the shortest park.
- **A live event already accounted or quarantined is dropped** before it is claimed.
- **The gate reads `DirectContacts.candidates`**, the facts the presence keys already read (accepted and authored DM
  threads, verified peers), less every blocked id; never `Conversations.isAccepted`, whose group branch counts a group's
  senders. A spool's `maxScopes` is each session's own cap, never the table's.
- None of it changes what a spool or a peer receives beyond fewer `list`, `pull` and stamped records: no record, field or
  capability moves.

**Amended 2026-11-17 (P4a, the engine's spool door; a draft until the maintainer accepts it):**

- **One door.** A frame a spool served enters the engine through `MeshEngine.receiveFromSpool` alone, in one synchronous
  turn: the oversize profile check, the signature against the key the engine already picks for the frame, whether custody
  held it before, the router's seen set, custody's carry, delivery with no link, and whether custody holds it after. The
  read of the key and each custody read is a store unit of its own. `InboundFrame` stays the radio's. A candidate with no
  key or a bad signature marks nothing seen, asks for no key and parks nothing. A pulled copy that custody does not hold
  is carried and delivered even when the router has already seen its id, and is never bridged.
- **Settlement.** Every custody outcome, refusals included, settles as delivered with whether custody holds the frame
  live. A failed store unit settles as not taken: the router's mark this turn made for that frame is taken back whatever
  the window, and the scope owes a listing, so the frame comes again once the store recovers.
- **The bridge.** A pulled frame goes onto the radios only when this delivery newly carried it (custody did not hold it
  before, the carry changed custody, custody holds it after) and it is not late, as a flood heard from no neighbour, and
  under one budget per engine, shared by every relay, of 32 frames in a burst and one more every two seconds; a token is
  spent only on a frame the router schedules. A frame over the budget is kept, and custody's digest exchange carries it.
- **Spool frames feed no reset evidence.** A failure of a frame a spool served never counts toward the reset heuristic,
  resets nothing at once and lets nothing past the router, until the deferred reset unit. The frame's source rides with
  it into the ratchet's replay and a seed's wait.
- **A relay's copy of a DM this phone already holds is never acknowledged again.** A first delivery over the relay is
  acknowledged as any is. The accepted limit: a peer's re-sealed copy of a DM this phone already holds, reaching it only by
  a relay, earns no new ✓✓ until a radio copy arrives; it belongs to the deferred reset unit.
- **A reset's re-sealed tail never crosses the relay.** Custody keeps the first bytes stored under an id, and the heal
  pushes only what custody holds, so a re-seal of an id reaches a peer over the radios alone.
- **The table.** Its inputs (the confirmed sessions' scopes, the accepted peers, the blocked peers and this phone's own
  activity) are each read in a store unit of their own, and any that fails keeps the table. It is read again after every
  commit that may move a session row's scopes, after a block, an unblock, an acceptance, a deleted thread or a
  verification, when a retiring scope's drain ends, and every 60 s; a scope that leaves cancels its stamp search in the
  same turn. A block drops the peer's scopes in its own turn whatever the stores answer, and a later read of the blocked
  set that succeeds decides. Our own reset takes the pair's scopes out before the next heal input.
- None of it changes what a spool or a peer receives beyond fewer bridged frames on the radios: no record, field or
  capability moves.
