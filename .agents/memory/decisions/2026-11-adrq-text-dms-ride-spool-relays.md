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
  day rolls. A search that found none parks the scope for the shortest park (amended by P4b2 below: the allowance counts
  stamps obtained, mined or from the engine's cache, and a whole search that found none parks until the next UTC day).
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

**Amended 2026-11-17 (P4b1, the connections; a draft until the maintainer accepts it):**

- **A relay is dialled at an accepted address alone.** `AcceptedSpoolURL` is built only by its factory: the canonical
  form, a scheme this build dials, a plain address (printable ASCII, no `@` and no `\` in the authority), no fragment, at
  most 256 bytes. `ws://` is taken only in a debug build whose caller allows it, only to `localhost` or a loopback,
  private or link-local address literal, and never with a `k=` parameter; a release build refuses it. It prints its host
  alone and mirrors nothing; in a cleartext address, an IPv4 part of more than one digit never starts with `0`, and a
  query key `k` in either case, or any key holding `%`, counts as a token. Its
  text leaves through `socketURLText`, which the socket factory alone reads. Everywhere else a relay is its
  `SpoolRelayHandle`.
- **The socket contract.** Reads are pulled: the reader asks for the next message only once its last post into the mesh
  returned, so one record is in flight per connection. A text message is dropped and counted. One send is in flight; the
  rest wait in the plane. Failures are fault words and a close code held to 1000…4999; a close frame's reason is dropped,
  and `Retry-After` comes as its first 16 bytes.
- **The plane owns a session's life.** Each dial takes a token from one counter per engine. A dial has 20 s to open. Every
  session that began ends through one path, in the same turn as the pause, removal, timeout or close that ended it, and
  that end clears the relay's queued records. A post under a token that is over is dropped. A relay is dialled only when
  its last task has ended. While a relay has no session, the plane reports only its dial deadline.
- **Inbound and outbound bounds.** Per connection, 64 records and 1 MiB as a burst, refilling over a second, text
  included; past it the reader waits for the refill. Per relay, at most 1 MiB queued to send, past which the heal holds
  its pushes until the queue drains; bytes queued with no send done for 30 s end the session as unreached. Pushes cost at
  most 16 MiB an hour, charged at the encoded size when each goes. Within one session, a blob the relay stored from us is
  not pushed again inside the hour; a scope's first `digest` of each session, and a `digest` of no blob (the relay shed
  the scope), forget that scope's entries, so a listing that lacks the blob takes it back. The hourly budget bounds
  repeats across sessions.
- **Dropped records.** A connection that drops more than two whole late pulls' worth of records (`2 × (256 + 1)` = 514:
  each pull's blobs at the largest `maxPull` and its `ok`), or more than 4 MiB of them, unread inside a rolling minute
  ends as an unreached session under the fault word `dropped`. A record of a type this build does not know counts toward
  the bytes alone, so a newer record type never ends a session by its count. Below the bound a dropped record leaves the
  connection standing, as before.
- **Backoff.** `Retry-After` is delta-seconds alone (ASCII digits, spaces or tabs around them), held to 0…60 s; a sign, an
  HTTP-date or anything else is no floor, and digits past the 16-byte cut read as 60 s. It floors the curve. A session is
  reached once it lasted 30 s or ended a round that compared a scope against the spool's anchor; a fault of ours, an
  `unopenable` end, a write stall and a close coded 4000…4003 are never reached. A session that ends before 30 s, reached
  or not, floors the next dial at the rest of those 30 s: a relay is dialled at most once per 30 s while its sessions end
  early. A pause is no failure, and a resume dials every relay at once with its count reset (P6 below: no sooner than the
  relay's `Retry-After` floor or its early-end floor, and only out of a pause).
- **The table before a send's end.** The end of a send reads the table first, as every input does, so a scope that left
  takes its held pushes with it before they go on.
- **Relays and lifecycle.** At most eight relays. A pause ends every session and keeps every heal (its accounted, invalid
  and unpushable sets, stamps, searches and owed listings); only a process start or removing the relay makes a fresh
  heal. The mesh's stop pauses the plane and its start resumes it. Turning the plane off, or a consent withdrawn, removes
  every relay.
- **A stamp answer reaches the heal with no session.** It clears the search, keeps and counts the stamp and marks the
  scope wanted; only the `sub` waits for a session. An answer the heal no longer waits on changes and counts nothing. A
  request is matched by its plane-assigned serial (P4b2 below). Every request in `mining` is attached to exactly one search
  queued or running, and ends in exactly one answer or one cancel.
- **The spool's own seen set.** A pulled id goes into a seen set of the spool's own, of the radios' size and window, and
  both doors check both sets, so a spool backlog never evicts a radio id. A failed store unit forgets the id from the
  spool's set; a reopen reopens it in whichever set holds it, each set at most once per window.
- **Logging.** At most one line per kind per relay per minute, at warning level, carrying what moved: count names,
  numbers, a relay's handle and the spec's refusal codes (any other code reads `other`). No line carries an address, a
  token, a node id, a scope id or any part of one, or a spool's own text. No per-frame line is written at warning level;
  per-frame debug lines say `spool` and name neither the relay nor the scope. `status` gains a `spool` key of handles and counts.
- None of it changes what a spool or a peer receives beyond fewer pushes and bounded reads: no record, field or
  capability moves.

**Amended 2026-11-17 (P4b2, the stamp miner; a draft until the maintainer accepts it):**

- **One miner per engine.** The plane holds the miner's bookkeeping as a value (`SpoolMiner`): the requests by serial, the
  values they wait on, the one run, the cache and the budget. Only the runner is off the actor: one serial `DispatchQueue`
  per engine at `.utility` (Linux ignores the QoS), never the cooperative pool, a detached task or the `Mesh` actor. It
  hashes one search with a stop flag behind a KnitSync `Lock`, read every 65,536 counters, and posts the result through a
  task that holds the mesh weakly. A mesh that goes only sets the flag; a shutdown a test awaits waits for the queue
  without blocking a thread.
- **Identity by serial.** Each request takes a serial from one counter per engine, and an answer clears a scope's search
  only when its serial matches: an identical request asked again is a new request.
- **One search per value.** A value is (scope, day, bits). Every request for it attaches to it, across relays, and at most
  one search runs engine-wide. A cancel detaches its request; the search is told to stop only when none is left, and a
  request that attaches again clears the stop. Every request ends in exactly one answer (found, exhausted or over budget)
  or in its own cancel. A stopped search is never answered: it resumes from the counter it reached while requests remain,
  or is dropped.
- **The heal's answers.** Found: the stamp is kept with the bits it actually meets, and counts toward the day's two stamps
  whether a search or the engine's cache produced it, so the allowance is two stamps obtained (mined or from the engine's
  cache) per scope per UTC day. Exhausted, a whole search of 2^26 counters that found none: the scope parks until the UTC
  day after the request's day, which replaces P3b's shortest park. Over budget: the scope parks for the answer's park, at
  least 5 minutes and at most a day. Every answer reaches the heal with or without a session. The heal's daily count is
  not the CPU bound; the engine's charge per peer is, and it outlives a scope leaving the table.
- **The cache,** per (scope, day): the best stamp found with the bits it actually has, the fewest bits a whole search came
  up empty at, and per bits the counter a stopped search reached. An ask at a find's bits or fewer, or at an exhaustion's
  bits or more, is answered at once; a search resumes from the furthest counter reached at its bits or fewer. It is read when
  a request is asked and whenever the queue is looked at. An entry leaves when its day is past reuse on the wall clock,
  never because its scope left the table; past 512 entries (two days of two scopes for each of the table's 128 peers) the
  scopes not in the table go first, then the oldest day.
- **The budget.** Over a rolling 24 h on the monotonic clock, charged with each search's `tried`: the engine at most 2^29
  counters, one relay at most 2^28, one peer at most 2^27, kept in hourly buckets so a charge stays at least 24 h. A
  search starts only when the engine and both shares hold its whole remaining range (2^26 less where it resumes);
  otherwise its requests are answered over budget at once, with the park until that much frees, counted apart (over
  budget, over the relay's share, over the peer's share). A value several relays ask for is charged to the least-spent of
  those relays whose share holds, ties by handle; it is refused for want of a relay share only when none holds. The choice
  is made among the relays asking when the value is scheduled: a relay whose share is spent and asks alone is refused and
  parks, and after the park it joins a running search for the value or is answered from the cache.
- **Order.** A free runner takes the value whose charged relay has spent the fewest counters in the window, then whose
  peer has, then the scope's rank in the table (live before retiring, most recent activity first), then the oldest request.
- **Stamp bits.** A stamp is sent only while the bits it meets reach the session's `powBits`. Kotlin's stamp cache keys by
  scope alone; the bits rule, the shares and the engine cache are this port's own.
- **Retiring scopes.** A retiring scope whose drain ends within the table's 60 s reconcile asks for no search and parks
  until the drain ends, at least the shortest park, counted.
- **Pause.** No search starts while the plane is paused. A pause stops the running search with its requests attached, and
  the resume starts it again from the counter it reached, before any other value, in the resume's own turn.
- **Counts.** `status`'s `spool` key gains the miner's counts (searches started, found, exhausted, stopped, resumed;
  values refused over budget, over a relay's share, over a peer's share; requests answered from the cache, and asks not
  taken for a scope the miner's table no longer carried; counters spent in the window) and each relay's `stampsRetiring`,
  as counts alone.
- **Owed.** P6 persists the window's buckets and the cache's found entries (scope, day, counter, bits) in the database, not
  `UserDefaults`, and the plane does not ship in a store build before then. P5's `check.sh spool` runs at
  `SPOOL_POW_BITS=24` with many scopes (oracle: the `status` counts show at most one search per (scope, day, bits) and at
  most 2^29 counters spent in 24 h). P7 keeps an energy log over an hour against a lab spool at 24 bits with Knit in the
  background half the time (pass: no hashing while paused, no termination for CPU use).
- None of it changes what a spool or a peer receives beyond fewer stamped `sub`s: no record, field or capability moves.

**Amended 2026-11-17 (P5, the socket; a draft until the maintainer accepts it):**

- **Where the socket runs.** `URLSessionSpoolSocketFactory` in `KnitSpoolNet` opens a relay's WebSocket through
  `URLSessionWebSocketTask`, one ephemeral `URLSession` per factory, on Apple platforms alone. Linux builds the module and
  opens nothing: every dial fails as `unreachable`, since FoundationNetworking's WebSocket rides the system libcurl, and the
  libcurl 8.5.0 on the build machine and in the pinned CI image has no `ws` or `wss`. Linux tests the plane against the
  reference daemon through a test-only `ws://` socket over plain TCP (`check.sh spool`); the adapter's own rules run on the
  Mac against a stub WebSocket server, in `test:macos` on every run.
- **The dial reads the address once more.** Before any socket opens, the factory runs `AcceptedSpoolURL` again on
  `socketURLText` with the build's compile-time cleartext flag and needs the same address back. Foundation's `URLComponents`
  must then read the scheme `wss` (or `ws` where the build dials cleartext), no user info and no fragment, and a host and
  port that, written as `host[:port]`, are the bytes `SpoolURL.host` reads from the same text. The port must be 1…65535,
  and the URL Foundation builds must print as the text. `AcceptedSpoolURL` refuses a `%` in the authority, so no reading
  decodes a host into another one. An address the check refuses fails as `unreachable`, and the factory logs one constant
  line, `spool dial refused by the address check`, with no address, host or handle in it.
- **The session stores nothing.** It stores, sends and accepts no cookie, and has no cache, no credential storage and no
  wait for connectivity. It refuses every redirect and judges TLS by the system's default trust. It keeps the system's
  proxy settings, as OkHttp's default selector keeps Android's: a `wss` relay goes through a proxy as a `CONNECT` tunnel,
  so the proxy learns the host and port alone. Low Data Mode and cellular are allowed, since the plane carries the
  person's own messages, in the foreground, under its hourly budgets. The upgrade asks with `Accept-Language: *` and
  `User-Agent: Knit`, and with no cookie, origin, credential or subprotocol. The task itself offers `permessage-deflate`
  on every upgrade.
- **Reads.** `maximumMessageSize` is 128 KiB. It holds on a message split into frames and on a compressed message's
  inflated size, and a larger message ends the socket as `protocol`. A text message is reported by its UTF-8 size and
  the socket stays. Nothing is read ahead of the plane's pull: a relay writing to a socket nobody reads stalls at the
  kernel's buffers (1.4 MiB in the stub's case). A send waits for the task to take its bytes, so nothing queues in the
  adapter.
- **The handshake bounds itself.** The dial fails as `unreachable` 20 s after it starts on the adapter's own clock, beside
  the plane's 20 s open deadline, since a server that reads the upgrade and never answers it held a task past the
  configuration's request timeout on the Mac. A socket quiet for longer stays open. A cancelled dial or receive ends at
  once, and its connection with it.
- **A failed upgrade** reports its HTTP status, which `task.response` carries, and the first 16 bytes of `Retry-After`. A
  redirect fails as `http` with its status and is never followed. An upgrade that names a subprotocol, or an extension the
  task did not offer, fails as `protocol`.
- **Ends and failures.** A relay's close reaches the plane as its code held to 1000…4999 (4001 and 4003 among them), never
  its reason. A failure is a fault word read from the error's code alone, so no failure, end, `status` line or log line
  carries a Foundation error, its user info or the dialled address.
- **No token over `ws://`.** `AcceptedSpoolURL` and `SpoolURL` still refuse a `k=` on `ws://` in every build. The private
  relay's case dials the test socket raw, outside the factory, and the token's path through the shipping adapter waits
  for a TLS relay in P7.
- **The release boundary.** `KnitSpoolNet` has no product, no target the app links names it before P6, and every one of
  its files is a debug build's alone. The factory logs `spool sockets are on in this debug build` as it is made, and
  `check.sh release` fails a store build that holds the line.
- **The daemon.** `check.sh spool` runs against knit-spool `a682524`, built from a clean worktree with its own Dockerfile,
  in containers on `127.0.0.1` alone (`.agents/context/spool.md`). `scripts/spool-daemons.sh` runs the pinned image ID,
  never pulls, and refuses a local tag whose ID is another.
- None of it changes what a spool or a peer receives: no record, field or capability moves.

**Amended 2026-11-17 (P6, the app; a draft until the maintainer accepts it):**

- **Relays run only at the front.** The live mesh starts with its spool paused (`Mesh(spoolStartsPaused:)`), whatever
  starts it: a launch, iOS's relaunch for Bluetooth restoration, the bridge's `start`. One serial stream carries the scene's
  phases, the gate and the relays into the mesh in order. The spool runs while `gate && foreground`: `foreground` is false
  at launch, true on `.active`, false on `.background`, and kept on `.inactive`, so Control Center and an alert keep the
  sockets. Only the scene's own phase resumes the spool; an environment built after the scene moved (protected data
  arriving, or Retry, at the front) hears the scene's last phase replayed, never the application's state. Leaving the front
  takes a background task, ended once the pause has stopped the miner and issued every close, or at once if the stream has
  ended. A resume does nothing unless the plane is paused. Otherwise it resets each relay's failure count and dials it at
  the latest of now, the `Retry-After` floor its last refused dial named, and the 30 s early-end floor. The `Retry-After`
  floor is kept by handle across a removal and an add, at most one per relay the mesh can carry, dropped once it has passed,
  recorded too when the refusal lands after a pause while no later dial went, and cleared by a later refusal with none.
  Two bounds are accepted: a pause and a resume that both land before a refused dial's answer can dial once before that
  refusal's floor, and the early-end floor is not kept across a removal and an add, so it holds once per toggle.
- **One gate.** `spoolEnabled` is a debug build (the compile-time flag, never an argument or a defaults key), the list
  read, and the switch on under the current consent sheet, bound by this install's consent nonce. With the gate closed the
  mesh carries no relay, and the list stays.
- **The consent nonce** is 128 random bits, kept in a relay-service Keychain item (account `consent`, not synchronised,
  `AfterFirstUnlockThisDeviceOnly`), with a copy in the list. Consent holds only while the two match. It binds the consent
  to this device's install; it is no secret, and nothing in the preferences is derived from the node id. A nonce that is
  gone or differs (a backup restored onto another phone, a reinstall, a replaced identity) voids the consent. A read that
  fails gives no consent and dials nothing until a read succeeds, and voids nothing. Replacing the identity, Diagnostics'
  one way to, first voids the consent in the kept list, then deletes the item, then replaces the identity, so no consent
  outlives the identity it was given beside, whatever the delete does.
- **Where a relay is kept.** The preferences keep handles and flags alone: whether a relay is seeded, private or parked,
  the seeded marker, the switch, its consent with the nonce's copy, and the deletes owed. Every address but the seeded house
  relay's, which is rebuilt from `SpoolURL.house`, is one Keychain item under the same service, never synchronised, set
  `AfterFirstUnlockThisDeviceOnly` on add and update, and it leaves the item only as an `AcceptedSpoolURL`. That is
  stricter than "Relays" above, which kept a public relay's URL in the preferences.
  - Only a list never kept removes every item under the service before it seeds `public-1`, and removing `public-1` never
    brings it back.
  - A kept list that does not read is left as it is: nothing is swept, seeded, written or dialled, the settings say the
    list cannot be read, the case is logged by kind alone, and the list is read again at each return to the front. A field
    missing from a kept list or entry reads from the rest: the next handle is past every handle listed or owed a delete,
    and a list that lists or owes anything was seeded. Only an entry with no handle leaves the list unread.
  - A failed delete is retried at each return to the front, and handles are never reused. The list holds at most eight
    relays, the mesh's cap.
  - A read that fails leaves the relay listed and undialled until a read succeeds. A text the factory refuses is kept,
    shown as unusable and never dialled. An address another listed relay is already ready under is a duplicate: shown,
    undialled and removable, and ready again once that relay goes.
  - The list is read after the identity: preferences read before the first unlock can come back empty.
- **Consent names what is dialled.** The switch's sheet names every relay that can join under it: by host, or by number
  while its address cannot be read, which joins once it reads. A switch sheet whose list no longer matches what its tap
  would carry is shown again as it now stands instead of applied. An invite's sheet names the one address the invite came
  to, and its Add applies that address. A new invite replaces a sheet that is up, and one accepted with the switch off
  joins the list and dials nothing. What is shown is the accepted address's own `host[:port]`, and only `SpoolURL.house`
  exactly is called Knit's relay. The access-key mark says only that an address carries a `k` key, not that a relay without
  one holds no secret. The sheet says what a relay learns: a code for each conversation with the person's contacts, when
  messages move, when Knit is open, and the phone's IP address.
- **Invites.** An opened link is an invite only when it starts with `https://getknit.app/r#` or `knit://r/`, and pasted
  text is searched anywhere. Neither takes `ws://` in any build: `allowCleartext` is false for every invite and paste, and
  `ws://` stays a test socket's. A pending invite waits in memory until onboarding and the terms are done. A refusal names
  its reason and no part of the link. getknit.app's association file lists `/c` alone (checked 2026-11-17), so the `https`
  form opens the website and `knit://r/` opens Knit (`.agents/memory/roadmap.md`).
- **The release boundary.** `KnitSpoolNet` joins the `Knit` target and stays in no product. Its import, the composition
  line, the invite branch in `Launch.open(url:)` and the settings section compile into a debug build alone, and `check.sh
  release` fails a store build that holds any of their markers. A Keychain failure logs its bare status alone.
- **The miner's spend stays in memory.** The window's buckets and found stamps live in memory, so a cold launch starts
  them again. Persisting them in the database is owed before the release flip, and the plane does not ship in a store build
  before then. The DM phases keep the schema as it is.
- None of it changes what a spool or a peer receives: no record, field or capability moves.
