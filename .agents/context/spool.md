# Internet relays (the spool)

What this port carries through Knit's Internet relays, read from where, and what each phase owes. The decision is ADR
2026-11.adrq: text DMs, in debug builds until the maintainer approves the plane for the store. Routed from
[`AGENTS.md`](../../AGENTS.md).

A spool is a small relay that keeps, per conversation **scope**, a bounded set of **blobs**: custody frames sealed
under keys both members derive from their session, which the relay never holds. Members push what the spool lacks,
pull what they lack, and converge by digest. The relay sees scope ids, sizes, timings and IP addresses, never node ids
or content. Spools never talk to each other, and a phone that dials several syncs each one.

## Sources and pins

| What | Where | Read at |
| --- | --- | --- |
| The protocol | knit-next `docs/SPOOL_PROTOCOL.md` (§3.1, §4.1–4.4, §7.1–7.2, §8, §9.1–9.4, §9.6, §12, §13) | `0832b8462` |
| Invite links | knit-next `docs/RELAY_INVITE.md` (§2, §5) | `0832b8462` |
| The client | knit-next `app/src/main/java/app/getknit/knit/mesh/spool/`, `mesh/crypto/scope/` | `0832b8462` |
| The reference daemon | `~/source/knit-spool` (`protocol/`, `daemon/`, `conformance/`) | `a682524` |

The port's pin stays `f018bc8ce` (`knit-next.md`). Two spool commits sit past it, and §13 is byte-identical at both:

- `2c32655bf` re-anchors a scope only over the digest its listing ran against (knit-next #322). This port follows it.
- `809cc9643` carries DM scope anchors through a restore (knit-next ADR 2026-11.dgj2). This port has no backups and
  leaves it out.

`Tests/Vectors/spool-v1.json` is read out of §13 and `RELAY_INVITE.md` §5 by `scripts/sync-vectors.py` (`--only
spool-v1.json` to refresh it alone). It keeps the inputs, the DM and pair derivations, the seal, the digest, proof of
work, the core records, every HELLO variant (for the fields a client ignores) and the three invite links. The
commons, attachments, TURN, tickets, casts and signals stay out.

## What this port speaks

- **Encoding** (§2): CBOR, definite lengths, unknown keys ignored, a field equal to its default omitted, every byte
  array a byte string, ids raw 32 bytes, digests 8 big-endian bytes. Kotlin writes keys in declaration order with `t`
  first, and the vectors pin that order.
- **The connection** (§7.1): `wss://host[:port]/spool/v1[?k=token]`, one record per binary WebSocket message. The
  spool's `hello` comes first; the client checks that 1 is in `[min, v]` and answers `{t:"hello",v:1}` (bytes
  `a261746568656c6c6f617601`), nothing else. "Connected" means that exchange finished. A late `hello` is ignored.
  Close codes: 4000 malformed before hello, 4001 auth, 4002 version, 4003 abuse, 1001 going away. A full spool refuses
  the upgrade with HTTP 503 and `Retry-After`, which floors the next wait.
- **Records** (§7.2): `sub`, `digest`, `list`, `pull`, `blob`, `push`, `event`, `ok`, `err`. The client's `q` rises per
  connection; `digest`, `blob` and `event` carry none. Every scope operation needs a `sub` on the same connection, so a
  reconnect re-subscribes everything. Error codes: `version`, `pow`, `tombstoned`, `quota`, `too_large`, `bad_id`,
  `rate`, `not_subscribed`, `malformed`, `internal`, `conflict`, `ticket`; an unknown one is a generic failure.
- **DM scopes** (§3.1): `pairwiseRoot = HKDF(root, "knit/dm/v2/export/root", 32)`; with `ctx = idLow|idHigh|`,
  `scopeId = HKDF(pairwiseRoot, "knit/scope/v1/dm/id" ‖ ctx, 32)` and `HKDF(pairwiseRoot, "knit/scope/v1/seal" ‖ ctx,
  64)` split into the seal key and the nonce key. Every HKDF here is SHA-256 with a salt of 32 zero bytes. Confirmed
  sessions only; a live `prevRoot` is a retiring scope. C-3.1-4's exception for our own unanswered reset (knit-next ADR
  2026-10.j67x) is deferred with the slot and race rules it needs (ADR 2026-11.adrq). The vector for the export is
  `ratchet-v1.json`'s `exportRoot`.
- **The seal** (§4.3): `pt = sig(64) ‖ signed`; `nonce = HKDF(nonceKey, "knit/scope/v1/nonce" ‖ SHA-256(pt), 12)`;
  `blob = 0x01 ‖ nonce ‖ AES-256-GCM(sealKey, nonce, pt, aad = "knit/scope/v1" ‖ scopeId)`; `blobId = SHA-256(blob)`.
  Deterministic, so two members pushing one frame push one blob. The `WireEnvelope` (ttl, hops, relay) is never sealed.
- **The frame-set rule** (§4.4, `ScopeFrames.eligibleForDm`), on push and on pull: the envelope names no group, and it
  is either a `chat` between exactly the scope's two members, sealed v2 or v3 with the ratchet header `r`, or a
  `profile` from either. The id has its minted shape (C-4.4-14). On a pull, in order: the blob's hash, the AEAD, the
  envelope's decode, the id, the rule, then the signature against the pinned key. The spec's C-4.4-7 says v2 alone;
  the Kotlin takes v3 as well, and the Kotlin wins (knit/knit-next#339).
- **The heal loop** (§9): the digest is the XOR of FNV-1a-64 over the raw blob ids, 0 for none. On a mismatch with the
  spool's latest `digest`: `list`, pull what custody lacks (at most `maxPull` ids a request), push what the spool lacks,
  then re-anchor over the digest the listing ran against. A listing past 512 live ids, or past `max(2 × maxFrames,
  1024)` tombstones, is refused whole. Never push a frame past `sentAt + ttlMs` (C-9.2-1), nor into a retiring scope
  except our flagged reset (C-3.1-5).
- **The sets**, all in memory: per connection, the ids already handled (512 a scope, so a pull and an `event` never
  deliver one blob twice); per spool and scope, the invalid set (512, pulled blobs that failed, never an `event`) and
  the accounted set (512, delivered ids custody did not keep, which outlives a connection).
- **The bridge** (§9.4): a pulled frame that passes enters as a re-served copy (ttl reset, hops 0), through the
  engine's one spool door. The SeenSet dedupes it; it never counts as a radio overhear; it is relayed onto the radios
  when this delivery newly carried it and it is not late, under one budget per engine (this port's own, P4a).
- **Proof of work** (§8): `SHA-256("knit/spool/v1/pow" ‖ scopeId ‖ u64be(day) ‖ u64be(n))` with at least `powBits`
  leading zero bits, `day` the UTC day number, accepted for yesterday to tomorrow. Mined only after `err pow` on a
  request that carried no stamp, then sent at once. Refused above 24 bits; at most 2^26 tries a search; a stamp is
  reused until an hour before its window closes, and in this port only while the bits it meets reach the spool's
  `powBits` (P4b2); a refused stamp parks the scope.
- **Invites** (`RELAY_INVITE.md`): `https://getknit.app/r#<base64url>` or `knit://r/<base64url>`; the body is CBOR
  `{v:1, u, c?, n?, i?, k?}`, at most 512 bytes, `u` at most 256 characters. This port reads `u` alone: `c` and `n`
  are a commons room, `i` and `k` Knit Anywhere's issuer and key. Applied only after a consent sheet.
- **What this port never sends:** ctl 7 (scope config), so Android counts the iPhone undeclared and keeps the pair on
  `public-1`; attachments (`ahave`, `aget`, `aput`), even to a spool whose HELLO offers them; `sig`, `cast`, `turnreq`
  and `ent`.

## Constants

| Constant | Value | Source |
| --- | --- | --- |
| House relay | `wss://public-1.spool.getknit.app/spool/v1` (formerly `lax.spool.getknit.app`, folded on read) | `res/values/spools.xml`, `SpoolUrl.kt:53` |
| Record-layer version | 1 | §12.1 |
| Frame seal version | `0x01` | §12.1 |
| Declared bounds at `sub` | `maxFrames` 400, `ttlMs` 48 h, `maxBlob` 64 KiB | `ScopeRegistry.kt:292-301` |
| Largest record taken | 128 KiB | `SpoolRecords.kt:111` |
| HELLO clamps | `maxBlob`, `maxRecord` ≤ 128 KiB; `maxPull` 1..256; `powBits` ≤ 24 | knit-next ADR 025, `SpoolConnection.kt:1053` |
| Handshake timeout | 20 s | `ScopeSync.kt:3381` |
| Request timeout, silent requests | 30 s, 3 in a row drop the connection | `SpoolConnection.kt:1017-1020` |
| Redial backoff | 1 s doubling to 60 s for 10 failures, then doubling to 15 min; jitter ≤ 750 ms; `Retry-After` a floor, capped at 60 s | `SpoolBackoffPolicy.kt:18-28`, `OkHttpSpoolDialer.kt:252-264` |
| Offline recheck | 60 s | `ScopeSync.kt:3385` |
| Heal tick, scope-table reconcile | 60 s, 60 s | `ScopeSync.kt:3373-3374` |
| `push` refused with `rate` | waited out for at most 5 s | `ScopeSync.kt:2236-2251` |
| Refused scope (`quota`, `pow`) parked | 5 min floor, 1 h cap, `retryMs` a hint inside | §12.2, C-9.1-5 |
| Retiring scope's drain | 48 h | `PREV_ROOT_TTL_MS` |
| Profile republish | 12 h | `PROFILE_REPUBLISH_MS` (this port's `republishMilliseconds`) |
| Invite body, invite URL | ≤ 512 B, ≤ 256 characters | `RELAY_INVITE.md` §2 |

## Where it goes

| Kotlin | This port | Plane |
| --- | --- | --- |
| `SpoolRecords.kt`, `SpoolUrl.kt`, `RelayInvite.kt` | `Sources/KnitWire/Spool/` | security |
| `ScopeCrypto.kt` (DM half), `SpoolPow.kt`, `RatchetCrypto.kt:204` | `Sources/KnitCrypto/Scope/`, `RatchetCrypto.exportRoot` | crypto, security |
| `RatchetSessions.kt:977-1042` (`exportedRoots`) | `Sources/KnitMesh/Ratchet/RatchetSessions+Scopes.swift` | crypto |
| `SpoolConnection.kt` | `Sources/KnitMesh/Spool/SpoolSession.swift` (with `+Inbound`, `+Anchors` and `SpoolSessionEvent.swift`) | blobs, security |
| `SpoolBackoffPolicy.kt`, the wait in `ScopeSync.Worker.runLoop` | `Sources/KnitMesh/Spool/SpoolBackoff.swift` | blobs, security |
| `ScopeFrames.kt` (DM half), `ScopeRegistry.kt` (DM half), `ScopeSync.kt` | `Sources/KnitMesh/Spool/` (P3b, P4) | blobs, security |
| `MeshManager.kt:1185` (`handleInbound(…, "spool:<url>")`) | `MeshEngine.receiveFromSpool` (`Spool/MeshEngine+Spool.swift`), a `.spool` source on `RatchetInbound.Route`; `InboundFrame` stays link-only | blobs, crypto, security |
| `ScopeSync.kt` `stampFor` (`:3300`), `POW_BUDGET` | `Sources/KnitMesh/Spool/SpoolMiner.swift` (with `SpoolMinerCache`, `SpoolMinerBudget`, `SpoolStampRunner`), this port's own engine-wide miner (P4b2) | blobs, security |
| `OkHttpSpoolDialer.kt` | `Sources/KnitSpoolNet/` (`URLSessionWebSocketTask` on Apple platforms; Linux builds it and opens nothing) | security |
| `InternetRelayScreen.kt`, `RelayInviteApplier.kt`, `SettingsStore` keys | `Sources/KnitAppCore/Relays/` (`InternetRelays`, `RelayBook`, `RelayIntake`, `SpoolLifecycle`, `MeshPhases`), `Sources/Knit/` (`InternetRelaySection`, `KeychainRelayStore`, `AppEnvironment+Relays`), `AppPreferences` | security |
| `FakeSpool.kt`, `LabInternet.kt` | `Tests/KnitMeshTests/FakeSpool.swift` (the text subset), `LabInternet` in P4 | — |

The Kotlin suites to port, each with a doc naming the cases left to groups or Knit Anywhere: `ScopeVectorTest`,
`ScopeCryptoTest`, `SpoolPowTest`, `SpoolRecordsTest`, `RelayInviteTest`, `SpoolUrlTest`, `SpoolBackoffPolicyTest`,
`SpoolConnectionTest`, `ScopeFramesTest`, `ScopeRegistryTest`, `ScopeSyncTest`, the DM half of
`RatchetSessionsExportTest`, and the DM scenarios of `InternetPlaneLabTest` and `ResetOverRelayLabTest`.

## Open knit-next issues that bear on it

- knit/knit-next#290 bears on which sessions get a scope. P2 took Kotlin's `exports` rule as it is, confirmed sessions
  alone, with no gate of its own.
- knit/knit-next#188: a superseded reset of ours stays in the scope's local fold though it is never pushed, so the
  scope lists every round for up to 24 h. P3's heal loop must not copy it.
- knit/knit-next#339: C-4.4-7's v2-only wording, filed for this port on 2026-11-16.

## Phases

| Phase | What | State |
| --- | --- | --- |
| P0 | ADR 2026-11.adrq, this file, `spool-v1.json`, the routing | done 2026-11-16 |
| P1 | the codecs, `SpoolURL`, invites, fuzz targets (`SpoolRecord`, `SpoolURL`, `RelayInvite`, `FuzzSpool`) | done 2026-11-16 |
| P2 | the export (`RatchetCrypto.exportRoot`), scope crypto and proof of work (`KnitCrypto/Scope`: `ScopeKeys`, `ScopeCrypto`, `SpoolPow`), `RatchetSessions.dmScopes(now:)` in `RatchetSessions+Scopes`; `FuzzSpool` opens blobs | done 2026-11-16 |
| P3a | the connection (`SpoolSession`), `SpoolBackoff`, the fake spool's record layer, hostile-input tests | done 2026-11-16 |
| P3b | the DM frame rules (`ScopeFrames`, `mayRefill`), the heal loop (`ScopeHeal`), the gated scope table (`ScopeTable`), the seal cache, the pull budget (`SpoolIntake`), convergence tests | done 2026-11-17 |
| P4a | the engine's spool door, settlement, the bridge and its budget, reset evidence, the table's inputs and re-reads, `SpoolPlane`, two-engine tests over `FakeSpool` | done 2026-11-17 |
| P4b1 | the dialled address (`AcceptedSpoolURL`), the socket contract (`SpoolSocket`), the session's life in the plane (`SpoolLink`, tokens), inbound and outbound bounds, the upload budget and memo, `Retry-After`, backoff, relays, pause and resume, the spool's own seen set, counts, logs, `status`'s `spool` key, `FuzzSpoolSession` | done 2026-11-17 |
| P4b2 | the stamp miner (`SpoolMiner`): serials, one search per value, the runner off the actor, the engine cache, the budget and its shares, pause, counts | done 2026-11-17 |
| P5 | `KnitSpoolNet` (the address check, the URLSession adapter), the stub server and the test socket, `check.sh spool` against the daemon | done 2026-11-17 |
| P6 | the app: the live mesh's factory and start paused, the scene's phases through one stream, the relay list, its Keychain items, the switch and consent, invites, the debug-only settings, the release markers | done 2026-11-17 |
| P7 | device trials | |

### The connection as P3a left it (2026-11-16)

`SpoolSession` is one connection's record layer as a value. The caller feeds it `receive(bytes)`, `tick(now:)` at
`nextDeadline`, and `socketClosed()`, asks for `subscribe`, `list`, `pull` and `push` (each answers its `q`, or `nil`
when nothing was sent), and takes `drain()`: records to send, a close code, and `SpoolSessionEvent`s. It holds no URL, no
clock, no log and nothing that outlives the connection. What P3b and P4 build on:

- **What it drops.** Every record before the spool's `hello`; a `digest`, `event`, `blob` or uncorrelated scoped `err`
  for a scope not subscribed on this connection; a listing that answers anything but a `list` about its scope; an `err` whose `scope` names another scope than the request its
  `q` names; and an `err` whose `q` this connection issued for a request or `sub` that is over, so a late `err rate`
  moves no subscription. `ok.missing` is held to the ids the pull named and was not served. A hello
  kotlinx cannot read closes 4002 at once, as `onHello` does.
- **A `sub` cannot strand its scopes** (`SpoolSession+Subscriptions`). An `err` with a waiting `sub`'s `q` and no scope
  (the daemon's `internal`, or `malformed` past its own `maxScopes`) forgets each scope of the batch with no anchor yet
  and reports it `.scopeRefused` under that code; 30 s without an answer does the same and reports
  `.subscriptionLapsed`. Either way the next round subscribes it again. A `sub` strikes nothing.
- **Pulled blobs stream.** Each named blob is a `.pulled(request:)` event as it lands, once per named id, and the
  pull's `ok` ends it with `missing` and `oversize`. A pull that times out has delivered what came.
  The heal loop quarantines `oversize` in its invalid set (§9.3), as Kotlin does `PullOutcome.oversize`, with the ids
  it then fails to open.
- **Every spool number is read through a clamp.** `SpoolRefusal` carries a `rate` wait held to 0…5 s and a park held to
  5 min…1 h, never the raw `retryMs`; `SpoolText` cuts every spool string to 32 UTF-16 units without controls, format
  characters or line separators; `SpoolID` is a 32-byte id whose description is 8 hex characters.
- **The books die with the connection or the subscription:** the anchors (`anchor`, `foldPushed`, `reanchor` over the
  digest the listing ran against), the claims, the pulls and `sub`s in flight. Claims follow `ScopeSync.accepted`
  (`:3186-3209`): `claim` never evicts, so garbage claimed and released costs nothing, and `settle` after a delivery
  trims a scope's set to 512, oldest first; `release` gives one back. P3b uses these, not a processed set of its own.
  The accounted, invalid and unpushable sets, parks and stamps are `ScopeHeal`'s.
- **What P3b reads from a refusal.** `SpoolRefusal.parkMilliseconds` is set for every code; park only on `quota` and
  `pow`, as `handleScopeError` does, never on `rate`, `internal` or any other. A `rate` refusal of a request waits
  `rateWaitMilliseconds`.
- **Outputs print nothing whole.** `SpoolID`, `SpoolArrival` and `SpoolSessionOutput` describe themselves by id
  prefixes and sizes, and their mirrors have no children, so interpolation, `String(reflecting:)` and `dump` never carry
  a whole id or a blob's bytes.
- **Faults** are `SpoolFault`'s words: `unresponsive`, `no_hello`, `too_large` (a `sub` past `maxRecord`) and `version`.
  A session we end is no reached session; `SpoolBackoff.delay` takes the failures, the `Retry-After` floor and a
  `RandomNumberGenerator`.

### The heal loop as P3b left it (2026-11-17)

Everything per scope and across connections is pure and keyed by `ScopeKeys.id` alone (`SpoolID`), with no peer id in
any set. What P4 wires:

- **`ScopeTable.updated(dmScopes:accepted:blocked:recent:relays:)`** answers `.table` or `.unchanged`. `nil` for
  `dmScopes`, `accepted` or `blocked` keeps the table. `accepted` is `DirectContacts.candidates` (the facts `Acquaintances`
  reads: accepted and authored DM threads, verified peers); `blocked` is every blocked node id with the device-tag blocks
  resolved, as `directContacts()` builds it. `recent` is this phone's own last activity per peer. At most 128 peers, live
  scopes before retiring. A spool's `maxScopes` is not read here: each session holds its `sub`s to its own spool's cap,
  in the table's order, so one spool's cap costs no other relay a scope or its heal state.
- **`ScopeHeal`**, one per relay (`SpoolRelayHandle`, never a URL), outlives every `SpoolSession`. P4 calls `adopt` with
  the table's scopes, feeds every event the session drains to `handle(_:session:now:)`, calls `tick(session:now:)` at
  `nextDeadline(sessionReady:)`, and when `wantsRound(sessionReady:now:)` reads `CustodyStore.liveFrames` once, inside a
  store unit, and calls `roundStarted(.frames(…) | .unreadable, …)`. `custodyChanged()` after every custody write.
- **Its outputs** (`drain()`): `.candidate(ScopeCandidate)`, settled with `settle(_:_:session:now:)` **before the heal's
  next input**, and `.mine` / `.cancelMining` for stamps, which the engine's miner answers with
  `stampMined(_:_:session:now:)` (P4b2; the plane cancels every request in `mining` when it drops the relay).
- **Times.** `SpoolNow` carries the monotonic clock (floors, parks, `rate` waits, the 60 s tick, the hour's budget) and
  the wall clock (`sentAt` rules, custody's reads, a stamp's UTC day).
- **What it keeps.** The accounted, invalid and unpushable sets (512 each, oldest dropped), a park after a `sub` refused
  `quota` or `pow` or a refused stamp on a push, a stamp and the day's stamp count (two a scope), the hour's intake
  (`SpoolIntake`), and `Counts` for `status`. A dirty scope heals at most once per 5 s; the 60 s tick heals all.
  `ScopeHeal`, its round and step, `ScopeCandidate` and `ScopeFrame` print counts and id prefixes alone, and mirror nothing.
- **This port's own rules** (ADR 2026-11.adrq, amended 2026-11-17, a draft): the unpushable set and when an id leaves
  it; accounting at the listing; the 5 s heal floor; the hourly pull budget, priced at our own `maxBlob`, and the
  `unopenable` fault; a refused stamp on a push parks the scope; at most two stamps obtained (mined or from the engine's
  cache, P4b2) per scope per UTC day, an answer with no stamp not counted; a live event already accounted or quarantined
  is dropped before it is claimed; the `sub` batch halving.
- **`FakeSpool`** gained `subBatchLimit`, `shed`, and the test modes `freshIdsPerListing`, `freshJunkPerListing`,
  `oversizeServes`, `garblesServes` and `refusesEveryPushPow`, with `servedBytes`. The tests' `HealMember` and `HealLab` drive members over
  it with a real `MemoryCustodyStore` each; `HealBench` drives one heal record by record.

### What P4 owes from P3b (2026-11-17)

- A stamp search outlives the connection that asked for it: a dropped connection stops nothing, so `mining` stays set and
  the next connection starts no new search. Since P4b2 a stopped search is never answered at all (the miner resumes or
  drops it), and only a whole search that found none answers exhausted, which parks the scope until the next UTC day.
- **Verify through the engine, never a second key picker.** Each candidate's `verified(by:)` takes the engine's own
  `verifierBundle(for:)` (ours for our own frame, the payload's own key for a profile, the pinned key otherwise), or the
  `ScopeFrame` passes through the engine's `verify` path; a candidate with no key settles `.unopenable`.
- **Settle every candidate in the turn that delivers it,** with a two-engine test:
  - `.delivered(keptLive: custody.frame(id, now:) != nil)`, read in the same turn, when the engine took the frame. A
    copy whose id the router already saw is carried and delivered when custody does not hold it, and settles
    `.delivered(keptLive: true)` with nothing else done when custody does. A second relay's pull of a frame the first
    relay delivered is the second case: it is accounted, never quarantined.
  - `.unopenable` for a signature that fails or a sender with no key; `.refusedByCarry` only for a refusal about the
    frame's own bytes (both quarantine a pulled blob).
  - `.notTaken` when a store unit failed: the claim is released and nothing else (no quarantine, no intake count).
- **Bridge only what custody did not already hold,** checked before the delivery, and never a late frame
  (`ScopeFrame.bridges`).
- **Read the gate inside a store unit** whose failure becomes `nil`, never `[]`: SQL stores answer a failed read as empty
  (ADR 2026-09.nyya), and an empty `blocked` would let a blocked peer's scope back in. A two-engine test where the block
  read fails and the blocked peer's scope stays out.
- **An `unopenable` end counts as an unreached session** for `SpoolBackoff`.
- **One seal cache per engine,** sized for the table and shared by the relays (today each `ScopeHeal` holds its own
  `ScopeSealCache`, 2,048 entries); `held`, the unpushable set and the intake stay per relay.
- A log line per kind per interval for `Counts` (overlong listings, quarantines, faults, parks, budget deferrals, capped
  stamps, replays), in Kotlin's words where it has one, naming at most a scope id's prefix, never beside a node id.
- `custodyChanged()` from every path that writes or sweeps custody, and `adopt` after every table change.

### The engine entry as P4a left it (2026-11-17)

- **Where the plane lives.** `SpoolPlane` (`Spool/SpoolPlane.swift`) is a struct `Mesh` owns beside `links`: the
  `ScopeTable`, one `ScopeHeal` and `SpoolSession` per relay, and one `ScopeSealCache` lent to each heal for the input it
  runs. Every input (`add`, `remove`, `connected`, `receive`, `socketClosed`, `stampMined`, `tick`) runs to completion in
  one turn, and each candidate a heal raises is settled through the engine before the heal's next input. The driver
  takes `takeOutgoing(relay)` (records and a close) and `takeMining()` (`.mine`, `.cancel`). It carries no relay until
  P4b adds one, so it keeps no timer and reads no table. `SpoolLab` (`Tests/KnitMeshTests/SpoolLab.swift`) is the
  synchronous driver the two-engine tests use.
- **The door** is `MeshEngine.receiveFromSpool(_:relay:)` (`Spool/MeshEngine+Spool.swift`), in this order: the oversize
  profile check (`.delivered(keptLive: false)`, nothing marked seen); the signature against `verifierBundle(for:)`'s key,
  read in a unit of its own (`.notTaken` when it did not commit), never `verify(_:)`, so no key request and no
  `PendingInbound` hold (`.unopenable`); "custody held it before" in a unit of its own (`.notTaken` on failure); the carry
  gate and `Router.admitPulled` (no ingress budget, no overhear). A copy the router already saw is carried and delivered
  when custody does not hold it, never bridged, and settles kept with nothing else done when custody does
  (`MeshEngine.pulledAdmission`). Then custody's carry through `CustodySync.carrying`, which surfaces `.writeFailed`
  (`.notTaken`); delivery with no link (a chat's route is `.spool`, its hop `nil`; a profile as any is); `keptLive` in a
  unit of its own (`.notTaken` on failure). Every custody outcome, refusals included, is `.delivered`.
- **A failed unit takes back the mark this turn made** (`Router.reopenPulled`, `SeenSet.forget`), never `reopen`, which is
  once per window: a second failure must not leave an id seen and unheld. An id the router saw before the turn keeps its
  mark. And a `.notTaken` candidate owes its scope a listing (`ScopeState.listOwed`): a live `event` moves no anchor, so
  the fold would otherwise match the spool's stale word and never list the blob again.
- **The bridge**: only a frame this delivery newly carried (not held before, custody changed, held after) that is not
  late, as a flood heard from nobody (`Router.relayPulled`), under one `SpoolBridgeBudget` per engine shared by every relay
  (32 in a burst, one back every two seconds), a token spent only on a frame the router schedules (`Router.relaysPulled`).
  Over it, the frame is kept and custody's digest exchange carries it. Counts: `spoolInbound.counts.bridged`,
  `.bridgeDeferred`, the router's `spoolAdmitted`, `spoolDeduplicated`, `spoolNonCanonical`, `spoolBridged`.
- **No reset evidence from a spool** (`.agents/context/crypto.md`, the reset heuristic). A relay's copy of a DM this phone
  already holds is never acknowledged again; a first delivery over the relay is. Accepted limit: a peer's re-sealed copy
  of a DM this phone already holds, reaching it only by a relay, earns no new ✓✓ until a radio copy arrives; it belongs to
  the deferred reset unit.
- **The table's inputs** (`Spool/MeshEngine+SpoolTable.swift`): `dmScopes`, `DirectContacts.candidates`, the blocked ids
  (the device-tag blocks resolved over every pinned peer) and our own activity (our send time, a peer's arrival here,
  from the thread heads) are each read in a unit of their own; any `nil` keeps the table and keeps it dirty. It is read
  again when `RatchetSessions.generation` moved, when `markTableDirty()` says so (`Mesh`'s unblock, accept, delete, verify
  and add-contact), at the earliest drain end, and every 60 s, and only between inputs, so after the outermost commit. A
  table change cancels the mining of a scope that left in the same turn. A block (`SpoolPlane.block`, from `Mesh.block`)
  drops the peer's scopes in its own turn whatever the stores answer; a later read of the blocked set that succeeds
  decides, and one that fails keeps the table without them.
- **Custody changed** is called once, where `Mesh.settle` notices a custody revision change, beside the digest cue.
- **Kotlin's cases left out of the lab**: `InternetPlaneLabTest`'s group, photo, file, ticket, commons and invite cases;
  all six of `ResetOverRelayLabTest`, which wait for the deferred reset unit (`SpoolResetLabTests` names them).

### What P4b owes from P4a (2026-11-17)

- Sockets and miners are tasks that post into `Mesh` methods wrapping the plane's inputs, then `settle()`; a cancelled
  search is never answered. `Mesh.fireDueTimers` already ticks the plane, and `schedule()` reads its deadline.
- `status` and a log line per kind per interval for `SpoolInbound.Counts`, the heal's `Counts` and `unreadableTables`.
- The drain end is on the wall clock and is read at the next input or the 60 s reconcile at the latest.
- A `Mesh.block`-level test with a live relay: no `sub`, `pull` or `.mine` for the peer's scope in the block's turn.
- Remove the `unused_declaration` disables on `SpoolPlane`'s inputs and outputs (`add`, `remove`, `connected`, `receive`,
  `socketClosed`, `takeOutgoing`, `takeMining`, `stampMined`) and on `SpoolBackoff` once their callers land.

### The connections as P4b1 left it (2026-11-17)

- **The address.** `AcceptedSpoolURL` (`KnitWire/Spool`) is the only form a socket factory takes: canonical, a scheme the
  build dials, plain, no fragment, at most 256 bytes; `ws://` only in a debug build that allows it, only to `localhost` or
  a loopback, private or link-local literal, never with `k=`. It prints its host; `socketURLText` is its one way out.
- **The socket** (`Spool/SpoolSocket.swift`): `SpoolSocketFactory.open` answers `SpoolDial`; `SpoolSocket` has a pulled
  `receive()`, a one-at-a-time `send`, and `close(code:)`. Faults are `SpoolSocketFault` words, a close is
  `SpoolSocketEnd` (code held to 1000…4999, no reason), a failed dial `SpoolDialFailure` (status held to 100…599,
  `SpoolRetryAfter` cut to 16 bytes). `Tests/KnitMeshTests/SpoolNet.swift` is the test adapter over `FakeSpool`.
- **The plane owns the session** (`SpoolPlane+Connections`, `SpoolLink`). It hands `Mesh` `SocketAction`s (dial, send,
  close, resume a reader) under a `SpoolConnectionToken` from one engine-wide counter, and takes the socket's posts
  (`opened`, `dialFailed`, `receive`, `socketClosed`, `sent`) under it; a post under an old token is dropped. A dial has
  20 s to open. Every session ends through `end` and `finish`, which clear the relay's queue and count it reached (30 s,
  or a round that compared a scope against an anchor) or not; a fault, an `unopenable` end, a write stall and a close
  coded 4000…4003 are never reached. A relay with no session reports only its dial in `nextDeadline`.
- **Dropped records.** A connection that drops more than `2 × (maxPullCeiling + 1)` = 514 records (two whole late pulls,
  each its blobs and its `ok`), or more than 4 MiB of them, unread inside a rolling minute (`SpoolDropWindow`) ends as
  `SpoolFault.dropped`, an unreached session, counted as `dropFaults`. A record of a type this build does not know is
  charged to the bytes alone, never to the count. This bounds P3a's rule that a dropped record leaves the connection
  standing: below the bound it still does.
- **Early ends.** A session that ends before 30 s floors the next dial at the rest of those 30 s, reached or not, so a
  relay is dialled at most once per 30 s while its sessions end early, and a pause and resume keeps that floor
  (`SpoolLink.earlyFloorAt`).
- **Bounds.** `SpoolInboundBudget` (64 records, 1 MiB, refilled over a second) parks the reader; 1 MiB queued holds the
  heal's pushes (`ScopeHeal.outboundFull`, `.held`, `outboundDrained`); 30 s of queued bytes with no send done ends the
  session; `SpoolUpload` holds pushes to 16 MiB an hour and keeps a blob the relay stored out of the next pushes for the
  hour within one session: a scope's first `digest` in each session, and any `digest` of no blob, forget its entries.
- **`Mesh+Spool`** (under `Spool/`): `addSpoolRelay(_:url:)` (at most eight; refused on a mesh with no socket factory),
  `removeSpoolRelay`, `pauseSpool`, `resumeSpool`, `spoolStatus`. One task a dial reads the socket; one task a send writes.
  `Mesh.stop` pauses the plane and `start` resumes it unless the app paused it. `.mine` requests waited in `spoolMiningQueue` until P4b2 replaced it
  with the plane's `SpoolMiner`; `spoolStampMined` is the runner's entry, and `SpoolPlane.stampMined` reaches the heal with
  no session.
- **The router** keeps a seen set of the spool's own (`spoolSeen`); both doors check both sets.
- **Logs and `status`.** `SpoolLogBook` writes at most a line per kind per relay per minute, at warning level, of counts
  and the spec's refusal codes. `status` has a `spool` key (`ControlLines+Spool`) of handles and counts.
- **Fuzz.** `FuzzSpoolSession` drives `SpoolSessionFuzz` (`@_spi(Fuzz)`, the `KnitMesh` product); `FuzzSpool` also runs
  the address factory.

### What P4b2, P5, P6 and P7 owe from P4b1 (2026-11-17)

- **P4b2** (met: "The miner as P4b2 left it"). A runner that takes `Mesh.spoolMiningQueue`, mines off the actor with
  `SpoolPow.mine`, answers `spoolStampMined` exactly once per search, and cancels on the plane's `.cancel`; never answers
  a cancelled search.
  Stamp identity moves from the request's value to a plane-assigned serial: a cancelled request's answer clears nothing,
  an identical request asked again is a new one, the stamp keeps its bits, and a stamp is reused only while
  `stamp.bits >= powBits`.
- **P5** (met: "The socket as P5 left it"). A `URLSessionWebSocketTask` adapter for `SpoolSocket`:
  - `maximumMessageSize` at 128 KiB before buffering, a text message reported by its size, a close's reason dropped,
    `Retry-After` cut to `SpoolRetryAfter.keptBytes`, the URL read only through `socketURLText`, an empty mirror;
  - no redirects; an ephemeral `URLSessionConfiguration` with no cookies and no cache;
  - `URLError` mapped to `SpoolSocketFault` at the adapter's own edge, so no Foundation error, its user info or the
    dialled URL reaches anything past it;
  - cancellation honoured in `open` and `receive`;
  - a stub-server suite: a 503 with each `Retry-After` variant (digits, an HTTP-date, `99999999999999999999`, negative,
    empty), a redirect to loopback, a 128 KiB message sent slowly, a server that never reads, an upgrade that never
    finishes and a socket whose `receive` never ends. Oracle: `spoolTasks.running` empties within the 20 s open deadline
    plus one tick, `dialTimeouts` counts it, and the next dial follows the curve.
- **P6** (met: "The app as P6 left it"). The scene phase calls `pauseSpool`/`resumeSpool`; the master switch off or
  consent withdrawn removes every relay; a private relay's address, token included, goes to the Keychain through
  `socketURLText` and comes back through the factory. P6 adds no bridge command: P7 adds its lab relay by opening the
  invite. The miner's persistence moved to before the release flip (P4b2's owed list, below).
- **P7.**
  - An `idevicesyslog` capture on a release build, and on a debug build with a private relay (a `k=` token and URL user
    info), grepped for `wss://`, `k=`, 64-hex runs, node ids and frame-id lines at warning level: none found. The debug
    capture includes a dial that fails, and no build sets `CFNETWORK_DIAGNOSTICS` (P5).
  - The backgrounding trial: iPhone and Pixel 9 apart over `public-1`, Knit in the background at least 10 minutes while
    the Pixel sends 5 DMs, then foregrounded: every DM lands, ✓✓ within 2 minutes, `failures` 0 and `dropFaults` 0 in
    `status` after the resume, the first redial within about 1 s.
- **Before P5** (met: `SpoolSeenSetsTests.aFrameFirstSeenFromASpoolAndThenByRadioCountsTowardNoReset`, 2026-11-17),
  the first phase a relay serves real frames, a two-engine test on the two seen sets (`SpoolMeshRig` with
  a radio `TestPeer`): a ratchet DM X reaches A first by the spool and fails to open; the same X then arrives by radio
  inside 10 minutes. Pass: no reset counted, no second open, `noteUndecryptable` never called for X; the peer's
  reset-evidence counters can stand in for a `noteUndecryptable` hook. Not written in P4b1: serving X sealed under a
  session A does not hold inside A's confirmed scope needs a second-session seal helper beyond a small one.
- **Before P7**, the reverse two-engine test: three radio failures seal A's reset; the retiring scope then serves X's old seal before B's re-seal
    arrives by radio. Pass: the re-seal is delivered within the second re-seal's ~11 minutes on the manual clock, and
    both sides confirm the same `rootHash` after.

### The miner as P4b2 left it (2026-11-17)

The rules are ADR 2026-11.adrq's P4b2 amendment; this is where each lives.

- **The value.** `SpoolMiner` (`Spool/SpoolMiner.swift`) is a value in `SpoolPlane`, beside the table: the requests by
  serial (`SpoolMiningRequest.serial`, drawn from `SpoolPlane.nextSerial` and lent to each heal for the input it runs), the
  values they wait on, the one run (`SpoolMinerJob`), `SpoolMinerCache` and `SpoolMinerBudget`. A value several relays ask
  for is charged to the least-spent of them whose share holds (`SpoolMiner.charged`), chosen among the relays asking when
  it is scheduled; a spent relay asking alone parks, then joins a running search or takes the cache. `SpoolPlane.serviceMiner`,
  which `Mesh.serviceSpool` calls after every input, takes the heals' asks, hands what the miner answers at once (the cache,
  the budget) back to the heals after their turn, and loops until no ask is left; then the runner's actions (`.start`,
  `.stop`, `.proceed`). `searchEnded` is the runner's result; `pause` and `resume` stop and restart the run.
- **The heal's side.** `ScopeHeal.stampMined(_:_:session:now:)` takes a `SpoolStampAnswer` (found with its bits, exhausted,
  over budget with its park), matched by serial. `usableStamp` is the one place a held stamp is judged (window and bits);
  `stampNeed` and `demandStamp` both call it. `ScopeState.stampBits` keeps the bits. `SpoolScope.retiringUntil` (from
  `DMScopes.retiringUntil`) lets `demandStamp` park a retiring scope about to leave (`Counts.stampsRetiring`).
- **The runner.** `SpoolStampRunner` (`Spool/SpoolStampRunner.swift`) is injected; `DispatchStampRunner` is the one a mesh
  makes on its first search: one serial `DispatchQueue(label:qos: .utility)`, `import Dispatch`. `SpoolStopFlag` is a KnitSync
  `Lock` the actor sets and clears and the search reads at each check. `Mesh` holds the runner (`spoolRunner`), the search in
  flight (`spoolSearch`), and posts results with a task that holds it weakly; `deinit` sets the flag and joins nothing;
  `shutdownSpoolMiner()` sets it and awaits the queue. `useSpoolRunner` is the tests' seam.
- **Status and logs.** `status`'s `spool` counts gain `minerRuns`, `minerFound`, `minerExhausted`, `minerStopped`,
  `minerResumed`, `minerOverBudget`, `minerOverRelayShare`, `minerOverPeerShare`, `minerFromCache`, `minerUnheldScopes` and
  `minerSpent`; each relay
  gains `stampsRetiring`. The log book writes a `spool miner` line per interval.
- **Tests.** `SpoolMinerTests` and `SpoolMinerBudgetTests` drive the value through `MinerBench`; `SpoolMinerPlaneTests` the
  plane through `SpoolLab` (`holdsRuns`, `endRun`); `ScopeHealStampTests` the heal's bits and retiring rules;
  `SpoolMinerMeshTests` two meshes with `FakeStampRunner` and the real runner; `FuzzSpoolSession` plays the runner with
  `SpoolMiner` behind the heal (`SpoolSessionFuzz`).

### What P5, P6 and P7 owe from P4b2 (2026-11-17)

- **P5** (met: `SpoolDaemonHeavyTests`, six scopes at 24 bits, 108 s on one core on 2026-11-17). `check.sh spool` at
  `SPOOL_POW_BITS=24` with many scopes. Oracle: the `status` counts show at most one search per (scope, day, bits) and
  `minerSpent` at most 2^29 in 24 h.
- **Before the release flip (G6)**, moved from P6 by its amendment: persist the budget's hourly buckets and the cache's
  found entries (scope, day, counter, bits) in the database, never `UserDefaults`; the plane does not ship in a store build
  before then. Until then the window's buckets and found stamps live in memory, so a cold launch starts them again. This
  replaces P4b1's "the daily stamp spend is persisted across launches".
- **P7.** An energy log over an hour against a lab spool at 24 bits, Knit in the background half the time. Pass: no hashing
  while paused, and no termination for CPU use.

### The socket as P5 left it (2026-11-17)

The rules are ADR 2026-11.adrq's P5 amendment; this is where each lives and what the stub settled.

- **The target.** `KnitSpoolNet` (`Sources/KnitSpoolNet/`) depends on `KnitSync`, `KnitMesh` and `KnitWire`, has no
  product, and every file opens with `#if DEBUG`. `SpoolDialCheck` is the address check, on every platform.
  `URLSessionSpoolSocketFactory` logs its marker as it is made and runs the check at each dial; a refusal fails as
  `unreachable` and logs `spool dial refused by the address check`, a constant line. `SpoolSessionDialer` holds
  the one session and its configuration, `SpoolTaskWatch` is the session's delegate and the mapping to fault words,
  `SpoolTaskState` decides each dial once and ends each socket once, and `URLSessionSpoolSocket` is the socket. The last
  four compile where `canImport(Darwin)`; elsewhere `open` fails as `unreachable`.
- **What the stub settled** on the Mac (Xcode 27.0, macOS 27; `URLSessionDialTests`, `URLSessionSocketTests`):
  - `task.response` carries a refused upgrade's status and `Retry-After`: a 503's status and each variant's first 16 bytes
    reach the plane, and a 302 fails as `http 302`;
  - the delegate's refusal holds: a redirect's target, a second listener, is asked nothing;
  - nothing is read ahead: a stub writing 64 MiB of 64 KiB messages to a socket nobody reads stalled after 1,507,023
    bytes, and sends to a stub that never reads stalled after 655,360 bytes;
  - the task offers `Sec-WebSocket-Extensions: permessage-deflate` on every upgrade. A relay that takes it may compress,
    and `maximumMessageSize` holds on the inflated size: 8 MiB of zeros compressed under the cap ends the socket, and
    128 KiB inflated arrives whole;
  - a server that reads the upgrade and never answers held a task past the configuration's 20 s request timeout for
    minutes, so the dial carries its own 20 s deadline (50 ms of leeway; the system's default was a second). A socket
    quiet for 25 s stays open;
  - a close's code reaches the plane, 4001 and 4003 included, and its reason does not;
  - the requests carry `Accept-Language: *`, `User-Agent: Knit`, and the task's own `Accept`, `Accept-Encoding` and
    `Cache-Control`, with no `Cookie` after a `Set-Cookie`, and no `Origin`, `Authorization` or `Sec-WebSocket-Protocol`.
- **The stub server** (`Tests/KnitSpoolNetTests/StubServer.swift`, with `+Wire`, `StubEvents` and `Loopback`) is BSD
  sockets on `127.0.0.1` at a kernel-picked port, with no `SO_REUSEPORT`. It plays one answer per connection and records
  each request head, what it wrote, whether its writes stalled, and when it saw the client's end. `StubServerTests`
  checks the stub itself on every platform. `SpoolNetPlaneTests` runs the plane's half with a `Mesh` on a step clock:
  the open deadline, the handshake with no `hello`, a `Retry-After` floor, 4001 and 4003, and a marker in the query that
  reaches no failure, end, `status` or log line.
- **The test socket** (`SpoolTestSockets`, `SpoolTestSocket`, `SpoolTestTCP`) lives in `KnitMeshTests` beside the daemon
  suite, which reuses the spool lab's greeted sessions, and never in a `.target`. It dials `127.0.0.1` and `localhost`
  alone, checks `Sec-WebSocket-Accept`, masks every frame, caps a message before reading past 128 KiB, answers pings and
  keeps a close's code. `SpoolDaemonLine` is one raw connection for what no member of the plane plays.
- **The daemon suite** (`SpoolDaemonTests`, 2026-11-17, against `a682524`): text and ✓✓ both ways at the daemon's 8 bits,
  with one search per value and both folds agreeing; a DM the daemon carries bridged onto a radio link to a third node; a
  peer's reset pushed into the old scope, as Android pushes it, adopted, with the old scope retiring and the answer under
  the new one; the Kotlin vectors' blob opened here and a Swift seal served back byte for byte; a private relay closing
  4001 without its token and saying `hello` with it; two daemons sharing one search, each relay within its share; and
  the opt-in 24-bit case. `SpoolDaemonAddressTests` holds the loopback rule on every run. On the Mac,
  `URLSessionDaemonTests` runs the shipping adapter against the daemon when `KNIT_SPOOL_URL` names one on the Mac's
  loopback: `hello` both ways, a stamped `sub`, a push pulled back byte for byte, and a socket quiet past the daemon's
  30 s ping (2026-11-17, skuld's daemon reached through `ssh -R` to the Mac's loopback).
- **The boundary** (as P5 left it; P6 links it into `Knit` under `#if DEBUG`, "The app as P6 left it").
  `SpoolNetIsolationTests` checked that the app's dependency closure had no `KnitSpoolNet`, that no product exports it,
  that every file is `#if DEBUG`, that the release gate greps for the factory's marker, and that nothing under `Sources/`
  names the test socket or the stub. `seam_url_loading` reads `URLSession…`, `URLRequest` and `webSocketTask`, and
  excludes link previews, `KnitSpoolNet` and its tests. The composition root's one use, link previews' transport, is
  disabled on its line.

### What P6 and P7 owe from P5 (2026-11-17)

- **P6.**
  - The composition root makes one `URLSessionSpoolSocketFactory` per mesh under `#if DEBUG`, with a
    `seam_url_loading` disable on that line as link previews' has. `SpoolNetIsolationTests.theAppLinksNoSpoolSocketYet`
    then gives way to a check that only a debug build reaches the factory, and the marker stays in `check_release_app`.
  - A private relay's address leaves the Keychain only as an `AcceptedSpoolURL`, which the dial checks again.
  - `RelayInvite.parse(_:allowCleartext:)` and `AcceptedSpoolURL` take `allowCleartext: false` for every invite and paste,
    in every build, never anything the invite carries: `ws://` stays a test socket's.

  All three met in P6 ("The app as P6 left it").
- **P7.**
  - The first TLS relay and the first token through the shipping adapter: `public-1`, and a lab spool behind TLS with
    `SPOOL_TOKEN`. The stub and the daemon are cleartext loopback, so neither has exercised the system's trust, a
    `CONNECT` proxy or a relay that negotiates `permessage-deflate`.
  - The capture in P4b1's P7 list runs with a dial that fails, and no build sets `CFNETWORK_DIAGNOSTICS`.
  - The PAC trial: the iPhone on a lab Wi-Fi set to Configure Proxy: Automatic, with a PAC script that logs the `url` it
    is handed, dials `wss://<lab relay>/spool/v1?k=<marker>`. Pass: the marker is in no line of the PAC log. If it is,
    an address carrying `k=` dials with `connectionProxyDictionary = [:]`, and the P5 amendment records it.

### The app as P6 left it (2026-11-17)

The rules are ADR 2026-11.adrq's P6 amendment; this is where each lives.

- **Composition.** A debug build's live launch alone makes the factory: `AppEnvironment.liveWithRelays` hands
  `Mesh(spoolSockets:)` one `URLSessionSpoolSocketFactory` from `AppEnvironment.spoolSockets(log:)`, on a line with a
  `seam_url_loading` disable, in `AppEnvironment+Relays.swift`, whose `import KnitSpoolNet` and helpers sit inside
  `#if DEBUG`. The demo and the sample chats get none. `Package.swift`'s `Knit` target now depends on `KnitSpoolNet`, which
  still has no product.
- **Start paused.** Every environment's mesh is made with `spoolStartsPaused: true`, which sets `Mesh.spoolWanted` to
  false, so `start()`, the bridge's `stop`/`start` and Settings' Stop and Start dial nothing until `resumeSpool()`. Relays
  read at launch are added before the mesh starts and dial nothing. A resume does nothing unless the plane is paused.
  Otherwise it resets each relay's failure count and dials it at the latest of now, its `Retry-After` floor and its 30 s
  early-end floor (`SpoolLink.earlyFloorAt`, with `lastDialToken`). The `Retry-After` floor lives in
  `SpoolPlane.askedFloors: [SpoolRelayHandle: Int64]`: kept by handle across a removal and an add, capped at the relay cap,
  pruned once it has passed, recorded too when the refusal lands after a pause while no later dial was issued, and cleared
  by a later refusal with no `Retry-After`. Two bounds are accepted: a pause and a resume that both land before a refused
  dial's answer can dial once before that refusal's floor, and the early-end floor is not kept across a removal and an add,
  so it holds once per toggle.
- **One stream.** `MeshPhases` (`KnitAppCore/Relays`) is the one serial stream into the mesh: the launch's own reading of
  the background (links alone), the scene's phases, the gate, and the relays added and removed, applied in order by one
  task. `SpoolLifecycle` decides: `wanted = gate && foreground`, `foreground` false at launch, true on `.active`, false on
  `.background`, kept on `.inactive`; a resume or pause only on an edge. `KnitApp`'s `onChange(of: scenePhase)` makes one
  call, `Launch.scene(_:)`; `AppEnvironment.scene(_:)` takes a `PauseTask` (`beginBackgroundTask`, its expiration handler
  holding it strongly) on `.background`, ended by the stream's `done` once the mesh has paused, or at once when the stream
  has ended (`MeshPhases.send` reads the `yield` result). `begin` resumes only by replaying the scene's own last phase into
  an environment built after it (protected data, Retry), never from the application's state.
- **The list.** `InternetRelays` reads `AppPreferences.relayBookData` through `RelayBook.read` (`StoredRelayBook`: absent,
  stored or unreadable) inside `AppEnvironment.live`, after the identity. The book holds handles, flags, the seeded marker,
  the switch, its consent with the nonce's copy, and the deletes owed.
  - Only an absent list sweeps every item under the relay service, then seeds `public-1` as handle 1, rebuilt from
    `SpoolURL.house`.
  - An unreadable one is left byte for byte: nothing is swept, seeded, saved or dialled, `isLoaded` stays false, the section
    says the list can't be read (`Copy.Relays.listUnreadable`), one log line names the kind alone, and `load()` runs again at
    each `.active`.
  - `RelayBook` and `RelayEntry` decode tolerantly: a missing `seeded` is `!entries.isEmpty || nextHandle > 1 ||
    !pendingDeletes.isEmpty`, `next_handle` is at least one past every handle listed or owed, a flag missing from an entry is
    off, a field this build doesn't know is ignored, and only an entry with no handle leaves the list unread.
  - Every other address is one Keychain item (`KeychainRelayStore`: service `app.getknit.knit.spool-relay`, the handle as
    the account, not synchronised, `AfterFirstUnlockThisDeviceOnly` on add and update), written as `socketURLText` and read
    back only through `AcceptedSpoolURL(_, allowCleartext: false)`. A failure logs its bare `OSStatus` alone.
  - A read that throws is "can't read", undialled, read again at each `.active`; no item is "add its invite again"; a text
    the factory refuses is kept, shown unusable, never dialled; an address another listed relay is ready under is a
    duplicate, shown, undialled, refused as an invite, removable, and ready again once the other goes. A delete that fails
    stays in `pendingDeletes`, retried at each `.active`. Handles only rise. At most eight relays, the mesh's cap.
  - The defaults key is `debug.spool.relays`, read and written in a debug build alone.
- **The gate.** `spoolEnabled` is the build flag the composition root passes (`true` only under `#if DEBUG`), the list
  read, and the switch on under `RelayBook.consentVersion`, bound by the install's consent nonce.
  - The nonce is 128 random bits (`RelayBook.freshNonce`), kept in the relay service's `consent` item and copied into the
    book; consent holds only while the two match. It binds the consent to this device's install and is no secret: nothing
    in the preferences derives from the node id.
  - A nonce that is gone or differs voids the consent at load. One that fails to read keeps the gate shut, voids nothing, and
    is read again at each `.active`.
  - The fresh-install sweep removes the item, so a reinstall or another device starts with no consent. Diagnostics' Replace
    identity, the app's one identity reset, first voids the consent in the kept list (`InternetRelays.forgetConsent`: switch
    off, nonce copy cleared, saved, every relay out of the mesh), then deletes the item, then replaces the identity, so a
    delete that fails leaves nothing to match.
  - Closed, every relay leaves the mesh and the list stays; open, every unparked relay whose address reads joins it.
- **Consent.** The switch's sheet (`RelaySheet.Kind.turnOn([RelayJoin])`) names every unparked relay that can join under it:
  its host, or "Relay 3" with "Joins once Knit can read its address" while it does not read. `confirm(_:)` compares what the
  sheet showed with the relays that would join now and presents a fresh sheet when they differ. An invite's sheet names its
  one address (`.add(AcceptedSpoolURL)`), and `confirm(_:)` applies the sheet it is handed. A new invite replaces a sheet that
  is up. An invite accepted with the switch off joins the list and dials nothing. What is shown is `RelayHost`:
  `AcceptedSpoolURL.description`, "Knit's relay" only for `SpoolURL.house` exactly, and the "Access key in link" mark from
  `AcceptedSpoolURL.carriesToken`, which says only that the address carries a `k` key. The words are `Copy.Relays` and
  `Copy.RelayConsent`.
- **Invites.** `Launch.open(url:)`, under `#if DEBUG`, takes an address that starts with `RelayInvite.urlPrefix` or
  `schemePrefix` (`RelayIntake.isInviteLink`), closes the sample chats and holds it in memory until the live `MainView`,
  after onboarding and the terms, hands it to `InternetRelays.offer(opened:)`. A tapped invite in a message goes the same
  way (`Launch.opensHere`). Settings' Paste is a `PasteButton`, searched anywhere (`offer(pasted:)`). Both read
  `allowCleartext: false`; a refusal is one line naming its reason, never the link. The share extension stages contact
  cards alone, so it never routes an invite.
- **Settings.** `InternetRelaySection`, in a debug build alone, after link previews: the switch, each relay's host, marks
  and status word (connected, connecting, waiting to try again, paused, not in use, off, listed twice, and the three address
  states), Stop using and Remove, and Paste, every control named by handle (`AccessibilityID+Relays`). The status comes from
  `Mesh.relayStatus()` each second while Settings is up. `-demoRelays` runs the same section over `DemoRelays`, which
  opens no socket, for the Simulator's walk.
- **The release gate.** `check_release_app` fails a store build that holds any of the factory's line, `internet relays are
  on in this debug build` (`startRelays`), `a relay invite opened in this debug build` (`Launch.open(url:)`),
  `debug.spool.relays` or `app.getknit.knit.spool-relay`. `SpoolNetIsolationTests` checks that only `Knit` and its own
  tests link `KnitSpoolNet`, that the import and the composition line, and every relay path in `Sources/Knit`, sit inside
  `#if DEBUG`, and that each marker lives in its one file. On the Mac each marker was in the Debug `Knit.debug.dylib` and
  none in the Release `Knit`.
- **AASA.** On 2026-11-17 getknit.app's association file, from the site and from Apple's CDN, listed `/c` alone, so a
  tapped `https://getknit.app/r#…` opens the website and `knit://r/…` opens Knit (`roadmap.md`).
- **Tests.** `MeshSpoolLifecycleTests` (start paused, a bridge-style stop and start, `Retry-After` kept), `SpoolLifecycleTests`
  and `MeshPhasesTests` (ordered phases into a real mesh and a counting factory), `InternetRelaysTests` with its `+Rows` and
  `+Kept` extensions (the list, the Keychain, the switch, park, a list that does not read, tolerant reads, the nonce, a relay
  listed twice, the stream's end), `RelayInviteSheetTests` and `RelaySheetMeshTests` (consent and invites, a stale switch
  sheet, a relay that joins once it reads), `SpoolNetIsolationTests`, `CopyCatalogTests+Relays`, and the Simulator's
  `KnitUITests.testTheRelaySwitchAndAPastedInviteGoThroughConsent`.

### What P7 owes from P6 (2026-11-17)

- A restoration relaunch dials nothing until Knit comes to the front; before the first unlock, no relay connection until
  Knit is at the front.
- The replay's positive case: a launch held before the first unlock, or one Retry built at the front, connects with no
  background-then-front in between.
- Background with a 24-bit search running and a Pixel's doorbell waking Knit: the miner's `stopped` count rises by one, the
  relay sees the close within 5 s, no connection opens during any wake, iOS ends nothing for CPU use, and at the front the
  search resumes.
- Control Center five times against a relay answering 503 with `Retry-After: 60`: nothing is dialled before 60 s, and a
  healthy relay keeps one connection. Ten flips in 5 s end in the state the last one says.
- A background and foreground flip within 60 s of a 503 with `Retry-After: 60` dials nothing before the 60 s are up.
- B6's trial: against a relay answering 503 with `Retry-After: 60`, Knit at the front for one refused dial, sent to the
  background within 10 s and brought back within 30 s. Exactly one dial before the refusal plus 60 s and one after it, while
  a healthy relay beside it reconnects within about 1 s of the return.
- A read-only container read after adding a private lab relay: no relay URL, no `getknit.app/r#`, no `knit://r/` and no
  invite text outside the Keychain, and `debug.spool.relays` holds handles, flags and the nonce's copy alone.
- The Keychain items' attributes: accessibility `ak` (`AfterFirstUnlockThisDeviceOnly`), not synchronised. This needs a
  debug-only diagnostic that returns attributes and never data, which P7 builds.
- After a reinstall, the relay service's items are swept before `public-1` is seeded, and the consent is void. An upgrade
  install keeps the relay, its row and the switch.
- A locked restoration relaunch: the kept list is byte for byte the same after it, and no sweep ran. Open question for this
  trial (crypto's): whether an empty read of the defaults before the first unlock can outlast the unlock. If the trial shows
  it can, a marker key that only a real write sets is the fix, and the list is read only once the marker reads.
- An `idevicesyslog` capture across a `devicectl --payload-url` open of the lab invite: no `getknit.app/r#`, `knit://r/`,
  the invite's compact text, a relay URL or `k=` in any line, iOS's own processes' included. The lab relay's invite and
  `SPOOL_TOKEN` stay in `.private/`.
- In the Simulator, `xcrun simctl openurl` with a `knit://r/…` invite while the switch is off opens nothing, and the switch's
  sheet names exactly the hosts the factory later opens; a second invite while a sheet is up applies the shown one.
- Replace identity with the switch on and the consent item's delete refused: after the relaunch `status` shows the spool
  off, no relay socket opens, and the switch reads off and asks for consent again.

### What later phases owe from P3a's reviews (2026-11-16)

- **P3b.** Its `pullAnswered` input becomes the streamed `.pulled` arrivals plus the closing
  `.answered(pulled(missing:oversize:))`. A `push` that answers `nil` while the session is ready and the scope
  subscribed did not fit the spool's `maxRecord`: that blob is unpushable on this relay.
- **P4.** The actor drains after every input. It counts `.dropped` by kind for `status`, and logs at most one line per
  kind per interval, never one per record.
- **P3b, claims and batches.** Every `claim` that answers `true` ends in `release` or `settle` on every outcome
  (delivered, a duplicate custody holds, quarantined, late, unopenable), with a test: a 10,000-`event` flood of blobs
  whose hash matches but which fail to open, and duplicates of held frames, keep a scope's claims at 512 plus those in
  flight after every record. After an unscoped `malformed` refusal of a `sub` batch, the next round sends smaller
  batches (halved, down to one scope a `sub`), with a test that every scope anchors within a bounded number of rounds.
- **Before P5 connects a real socket:** a stateful `FuzzSpoolSession` harness that feeds a session records, ticks at
  arbitrary `Int64` clocks and its own `subscribe`, `pull` and `push` calls, reaching it through a small public or
  `@_spi` seam.

### What P3 and P5 owe from P1's security review (2026-11-16)

`KnitWire` decodes as kotlinx does, refuses a record past `SpoolRecordLayer.maxInboundRecord` before decoding, and clamps HELLO's
limits in `SpoolLimits.clamped()`. The rest of Kotlin's bounds sit in the connection and the socket, as they do there:

- an id that is not 32 bytes (`SpoolConnection.isId`) refused wherever one is read;
- `SpoolErr.code` and `.message`, and an unknown `t`, cut to 32 UTF-16 units and cleaned before any log line, since
  `UnifiedLog` writes `privacy: .public`;
- `powBits` held to at most 24, and every spool `Int64` (`retryMs`, `ttlMs`, `maxTtlMs`, `count`) added or shifted
  only through clamping or `addingReportingOverflow`, since a trap ends Knit;
- a limit used as a count or a range bound only once `clamped()` has held it at 0 or above;
- the dialer calls `SpoolURL.isAcceptable` again on the canonical URL (met in P5: `SpoolDialCheck` runs the whole factory
  again);
- a hostile-input test for each: an oversize record, short and long ids, `retryMs = Int64.max`, `powBits` of -1 and 64,
  and a listing of 128K empty ids.

### What P3 owes from P2's reviews (2026-11-16)

- The plane subscribes, pulls, pushes and mines only for a scope whose peer the person has accepted (a contact or an
  accepted request), keyed on what is persisted, never on memory, with a cap on live scopes in total. A gate on this
  side splits nothing: the peer's pushes wait at the spool until the scope is subscribed. P3's design pass settles it.
- A blob a spool serves late is judged by its content (a profile's version, a frame's clamped clock), never by when it
  arrives: a spool can re-serve a frame long after the router's ten-minute memory has let it go.
- No log line puts a scope id beside a peer id.
- `dmScopes(now:)` is read again after every commit that moves a root and when a retiring window closes; `nil` keeps
  the scopes held. Every per-scope state is keyed by `ScopeKeys.id`.
- A search stops only when no request is left for it or the plane pauses (P3b, P4b2), and `SpoolPow.mine` looks at its
  stop every 65,536 counters.

P6 owes two more (met in P6: `RelayHost` is the accepted address's own description, and `Copy.RelayConsent.learns`):

- the consent sheet names the host the dialer will use, from the same parse, never `SpoolURL.host`;
- it says what an added relay learns: the scope ids it is given, timings and the phone's IP address.

Each phase that adds a target or a directory updates `architecture.md`, and the reviewers' paths in
`.claude/hooks/review-gate.conf` and `.agents/rules/owners.md`: `Sources/KnitMesh/Spool` for the blobs and security
reviewers, `Sources/KnitSpoolNet` for security. `PersonaTests` fails on a listed path that does not exist yet, so a
path joins the conf in the phase that creates it: `Sources/KnitSpoolNet` joined in P5, and
`PersonaTests.theSpoolPathsAreGatedForTheirReviewers` holds both.

## A daemon to test against

`check.sh spool` runs the daemon suite only when `KNIT_SPOOL_URL` names a daemon on this machine's loopback, and the suite
refuses any other address. On skuld, a shared machine, the daemons run in containers and stop after:

```sh
git -C ~/source/knit-spool worktree add --detach <scratch>/knit-spool-a682524 a682524
cd <scratch>/knit-spool-a682524 && nice -n 10 docker build --build-arg SPOOL_COMMIT="$(git rev-parse HEAD)" -t knit-spool:a682524 .
eval "$(scripts/spool-daemons.sh start)"      # in knit-ios; add --heavy for the 24-bit daemon
scripts/check.sh spool
scripts/spool-daemons.sh stop
```

- **The pin.** knit-spool `a682524`, the pin in "Sources and pins", built from a clean worktree with its own Dockerfile and
  tagged by commit. On 2026-11-17 the image was `sha256:e21ae5b6d1956b02950667652942e5cd40fc4a6c8b3246e981ec72cfeac826d9`,
  from `eclipse-temurin:21-jdk@sha256:db5cc6341a1d7bc40cdb51e1f0d9824f3bb2cc8107d29da421dc4df7d11f05f1` and
  `eclipse-temurin:21-jre@sha256:ca73b4d3961703d6d7830a4361f49ef0478f8f28b39defc07bb72f4cc7f834f6`. The image ID is what
  pins them: `scripts/spool-daemons.sh` keeps the tag and the ID side by side, refuses to start unless the local tag's ID
  is the pinned one, runs that ID with `--pull never`, and so never runs a rebuild whose base images moved. A new pin
  rebuilds the image and moves the tag and the ID in the script and here together.
- **Each container** (`scripts/spool-daemons.sh`) publishes 9470 on `127.0.0.1` at a port Docker picks, read back with
  `docker port` and checked with `/healthz`; drops every capability; runs read-only with no new privileges, its store on a
  tmpfs and `/tmp` on an executable tmpfs, where sqlite-jdbc loads its native library; and is removed when it stops. Each
  runs at `SPOOL_POW_BITS=8`, the heavy one at 24, with `SPOOL_RATE_NEW_SCOPES=600` for the suite's pace.
- **The variables `start` prints:** `KNIT_SPOOL_URL` and `KNIT_SPOOL_URL_2`, two public daemons; `KNIT_SPOOL_PRIVATE_URL`
  and `KNIT_SPOOL_TOKEN`, a private one whose `SPOOL_TOKEN` is minted at random per run and reaches the container through
  the environment; and with `--heavy`, `KNIT_SPOOL_HEAVY=1` and `KNIT_SPOOL_HEAVY_URL`. A case whose variable is unset is
  skipped and says so.
- **Outside Docker**, set `SPOOL_BIND=127.0.0.1`.

A debug build dials `ws://`; a release build refuses it at entry and at dial (C-7.1-2). The iPhone trials use `public-1`
or a lab spool behind TLS, so the app needs no App Transport Security exception, and neither does any test host: the Mac
dials its stub on its own loopback, and a daemon there only through Colima on loopback or `ssh -L` to skuld's.

## Trials

None yet. P7 records here: an iPhone and a Pixel 9 with Bluetooth apart, over `public-1`, text and ✓✓ both ways;
Knit backgrounded, then opened again; a reset over the relay; and a Pixel 8, linked to the iPhone, receiving a DM the
Pixel 9 sent through the relay.
