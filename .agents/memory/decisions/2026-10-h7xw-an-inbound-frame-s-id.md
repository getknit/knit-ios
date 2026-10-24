---
id: "2026-10.h7xw"
slug: an-inbound-frame-s-id
title: "an inbound frame's id has the shape its type is minted with"
date: 2026-10-23
topics: [wire, mesh, custody, interop, security]
---

# ADR 2026-10.h7xw — an inbound frame's id has the shape its type is minted with

Status: Accepted (2026-10-23)

**Context:** knit-next's database binds every id as UTF-16, and SQLite drops one leading U+FEFF there (and byte-swaps
the rest after a leading U+FFFE). On Android a signed frame under `"\u{FEFF}" + X` passed the in-memory dedup and then
took `X`'s custody and message rows. knit-next now refuses, at every inbound door, a frame whose envelope id is not the
shape its type is minted with (`FrameId.admits`, knit-next `a81f2050`, its ADR 2026-10.9qr4, #178). It refuses before
the ingress meter, the dedup, verify, custody and relay, and never marks the frame seen.

This port keeps every byte of an id (ADR 2026-09.jc2x), so it never had the collision. It did admit such a frame,
though, and custodied it and named it in its digest. Android refuses it unseen, so an iPhone served it again to each
Android neighbour at every 60 s exchange for the frame's custody life, and the pair's digests never agreed on it
(knit-ios #4).

**Decision:** `Router.admit` refuses any frame whose id fails `FrameId.admits`, before the seen check and the meter.
The check mirrors `FrameId.kt` at `a81f2050`:

| `type` | `id` |
| --- | --- |
| `profile` | exactly `FrameId.profileId`, `"profile-" + senderId + "-" + sentAt` in decimal, `senderId` a canonical node id |
| `talk` | exactly 11 base64url characters (`FrameId.talkLength`), the prefix of a fresh id an Android walkie chunk carries |
| any other type, an unknown one included | what `FrameId.generate` mints: 22 base64url characters that round-trip through 16 bytes (`FrameId.bytes(of:)`) |

The check measures and compares UTF-8 bytes, never Swift's `String` equality or `count` (ADR 2026-09.jc2x). Every
admitted shape is ASCII. A refusal returns `Admission.nonCanonical`, counts `Router.Counters.nonCanonical` (the
`status` reply's `router.nonCanonical`), logs one debug line in `drop()`'s form, and is never marked seen, metered or
relayed. It is a router count, not a `DropReason`, as Android's `INGRESS_REFUSED` is `router.refused` here: a
`DropReason` frame is still relayed, and this one is not.

The `talk` row is there although this port neither sends nor opens a `talk` frame. Android floods an unsigned one with
ttl 3, and an iPhone between two Android phones relays it after dropping it as `unsigned`. Without the row the gate
would stop that relay.

The alternative, leaving admission alone and setting such ids aside in a soak, kept the re-serve for every crafted id.

**Not changed, on purpose:**

- The decoder. `wire-v1.json`'s decode-only `relayEnvelope` (id `"m1"`) still decodes.
- The paths past the router: parked frames released on a key pin, the ratchet's failed-open replays, the custody
  replays at start and every hour, and held group seeds. Each replays a frame admitted earlier, or a row stored before
  this gate.
- Ids inside payloads (a receipt's `ackId`, a reaction's `messageId`, a reply's `messageId`) and the ids a neighbour's
  digest lists. A digest id that matches no row asks for nothing.
- No migration and no purge, chosen with the maintainer. Custody rows stored before this build under such an id are
  digested and served, to neighbours that refuse them, and count toward their quotas until they expire: 24 h at most,
  6 h for a room post. knit-next accepted the same tail.
- The spool door (`ScopeFrames.open`, spec C-4.4-14) is Android's alone. Spool relays and commons are never on iOS.

**Consequences / limits:** an id is no longer opaque on the way in. A new id shape, or a change to `FrameId`'s format,
is a wire break: every build before it drops the new frames (knit-next `docs/WIRE_COMPAT.md` rule 7). A new frame type
mints a `FrameId`. The table is cross-platform law, like `isCustodial`.

It does not stop a frame filed under another frame's exact id, which still wins first-write wherever it lands first.
Closing that means binding an id to its author, knit-next's `docs/NEXT_WIRE_BREAK.md` §10. A HELLO's node id is
checked at `admit` already (knit-next #199, `99fbcad1`).

Every test fixture that hands the engine a frame expects `FrameId.admits` of it, and a frame with a bad id goes through
`deliverRefused`, so a label id the tests forgot cannot turn a refusal test into one that passes unseen.
`FrameIdAdmitsTests` holds the table row by row, `RouterTests` and `SeenSetTests` hold the door and the byte keys,
`MeshEngineCanonicalIdTests` holds three engines converging past a marked twin, an unpinned sender's twin and Android's
`talk` relay, and the vector guard holds every vector frame but `"m1"` to the table.
