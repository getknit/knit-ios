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
  sessions only; a live `prevRoot` is a retiring scope; our own unanswered reset keeps the replaced root's scope as
  retiring and derives the new one (C-3.1-4, knit-next ADR 2026-10.j67x). The vector for the export is
  `ratchet-v1.json`'s `exportRoot`.
- **The seal** (§4.3): `pt = sig(64) ‖ signed`; `nonce = HKDF(nonceKey, "knit/scope/v1/nonce" ‖ SHA-256(pt), 12)`;
  `blob = 0x01 ‖ nonce ‖ AES-256-GCM(sealKey, nonce, pt, aad = "knit/scope/v1" ‖ scopeId)`; `blobId = SHA-256(blob)`.
  Deterministic, so two members pushing one frame push one blob. The `WireEnvelope` (ttl, hops, relay) is never sealed.
- **The frame-set rule** (§4.4, `ScopeFrames.eligibleForDm`), on push and on pull: the envelope names no group, and it
  is either a `chat` between exactly the scope's two members, sealed v2 or v3 with the ratchet header `r`, or a
  `profile` from either. The id has its minted shape (C-4.4-14). On a pull, in order: the blob's hash, the AEAD, the
  envelope's decode, the id, the rule, then the signature against the pinned key. The spec's C-4.4-7 says v2 alone;
  the Kotlin takes v3 as well, and the Kotlin wins.
- **The heal loop** (§9): the digest is the XOR of FNV-1a-64 over the raw blob ids, 0 for none. On a mismatch with the
  spool's latest `digest`: `list`, pull what custody lacks (at most `maxPull` ids a request), push what the spool lacks,
  then re-anchor over the digest the listing ran against. A listing past 512 live ids, or past `max(2 × maxFrames,
  1024)` tombstones, is refused whole. Never push a frame past `sentAt + ttlMs` (C-9.2-1), nor into a retiring scope
  except our flagged reset (C-3.1-5).
- **The sets**, all in memory: per connection, the ids already handled (512 a scope, so a pull and an `event` never
  deliver one blob twice); per spool and scope, the invalid set (512, pulled blobs that failed, never an `event`) and
  the accounted set (512, delivered ids custody did not keep, which outlives a connection).
- **The bridge** (§9.4): a pulled frame that passes enters as a re-served copy (ttl reset, hops 0), through the
  ordinary inbound path. The SeenSet dedupes it; it never counts as a radio overhear; it is relayed onto the radios.
- **Proof of work** (§8): `SHA-256("knit/spool/v1/pow" ‖ scopeId ‖ u64be(day) ‖ u64be(n))` with at least `powBits`
  leading zero bits, `day` the UTC day number, accepted for yesterday to tomorrow. Mined only after `err pow` on a
  request that carried no stamp, then sent at once. Refused above 24 bits; at most 2^26 tries; a stamp is reused
  until an hour before its window closes; a refused stamp parks the scope.
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
| `SpoolConnection.kt`, `SpoolBackoffPolicy.kt`, `ScopeFrames.kt` (DM half), `ScopeRegistry.kt` (DM half), `ScopeSync.kt` | `Sources/KnitMesh/Spool/` | blobs, security |
| `MeshManager.kt:1185` (`handleInbound(…, "spool:<url>")`) | a `.spool` source on `InboundFrame`, `Mesh.receiveFromSpool` | blobs, crypto, security |
| `OkHttpSpoolDialer.kt` | `Sources/KnitSpoolNet/` (`URLSessionWebSocketTask`, FoundationNetworking on Linux) | security |
| `InternetRelayScreen.kt`, `RelayInviteApplier.kt`, `SettingsStore` keys | `Sources/KnitAppCore/` and `Sources/Knit/`, `AppPreferences` | security |
| `FakeSpool.kt`, `LabInternet.kt` | `Tests/KnitMeshTests/` (the text subset) | — |

The Kotlin suites to port, each with a doc naming the cases left to groups or Knit Anywhere: `ScopeVectorTest`,
`ScopeCryptoTest`, `SpoolPowTest`, `SpoolRecordsTest`, `RelayInviteTest`, `SpoolUrlTest`, `SpoolBackoffPolicyTest`,
`SpoolConnectionTest`, `ScopeFramesTest`, `ScopeRegistryTest`, `ScopeSyncTest`, the DM half of
`RatchetSessionsExportTest`, and the DM scenarios of `InternetPlaneLabTest` and `ResetOverRelayLabTest`.

## Phases

| Phase | What | State |
| --- | --- | --- |
| P0 | ADR 2026-11.adrq, this file, `spool-v1.json`, the routing | done 2026-11-16 |
| P1 | the codecs, `SpoolURL`, invites, fuzz targets | next |
| P2 | the export, scope crypto, proof of work, `RatchetSessions+Scopes` | |
| P3 | the pure plane and a fake spool | |
| P4 | the engine's wiring, the `.spool` source, the bridge, two-engine tests | |
| P5 | `KnitSpoolNet`, `check.sh spool` against the daemon | |
| P6 | the app: settings, consent, invites, the release gate | |
| P7 | device trials | |

Each phase that adds a target or a directory updates `architecture.md`, and the reviewers' paths in
`.claude/hooks/review-gate.conf` and `.agents/rules/owners.md`: `Sources/KnitMesh/Spool` for the blobs and security
reviewers, `Sources/KnitSpoolNet` for security. `PersonaTests` fails on a listed path that does not exist yet, so a
path joins the conf in the phase that creates it.

## A daemon to test against

`check.sh spool` runs the integration suite only when `KNIT_SPOOL_URL` is set. On skuld, a shared machine, run the
reference daemon in a container and stop it after:

```sh
docker run --rm --name knit-spool -p 127.0.0.1:9470:9470 -e SPOOL_POW_BITS=8 ghcr.io/getknit/knit-spool:0.8.0
KNIT_SPOOL_URL=ws://127.0.0.1:9470/spool/v1 scripts/check.sh spool
```

`SPOOL_TOKEN=<token>` makes it private (`?k=<token>`); without `SPOOL_POW_BITS` proof of work is off. A debug build
dials `ws://`; a release build refuses it at entry and at dial (C-7.1-2). The iPhone trials use `public-1` or a lab
spool behind TLS, so the app needs no App Transport Security exception.

## Trials

None yet. P7 records here: an iPhone and a Pixel 9 with Bluetooth apart, over `public-1`, text and ✓✓ both ways;
Knit backgrounded, then opened again; a reset over the relay; and a Pixel 8, linked to the iPhone, receiving a DM the
Pixel 9 sent through the relay.
