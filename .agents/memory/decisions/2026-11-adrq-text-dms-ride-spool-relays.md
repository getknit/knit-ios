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
  only. A `prevRoot` inside its drain is a retiring scope, pulled but never refilled. While our own reset is unanswered,
  the replaced root's scope stays retiring and takes that one flagged reset, and the new root's scope is derived too
  (knit-next ADR 2026-10.j67x). The roots never leave `KnitMesh/Ratchet`: the plane gets a scope id, a seal key and a
  nonce key. `/export/epoch` and `sendEpochExport` stay out; they are reserved for a seal version 2 nobody sends.
- **The spool mirrors custody, both ways.** Each live custody frame a scope's rule admits is sealed and pushed when the
  spool lacks it: our own text, the sealed ✓✓ receipt (ctl 5, already carried) and the republished profile, which is
  how a relay-only contact learns a rotated prekey. A pulled frame that opens, verifies against the pinned key and
  passes the rule enters as a re-served copy (ttl reset, hops 0). The SeenSet dedupes it, it never counts as a radio
  overhear, and it is relayed onto the radios, so one online iPhone bridges the phones around it (§9.4).
- **Relays.** `public-1` is seeded; the person adds others by invite link (`https://getknit.app/r#…` or `knit://r/…`,
  `docs/RELAY_INVITE.md`), applied only after a consent sheet, with the commons fields `c`/`n` and Knit Anywhere's
  `i`/`k` ignored. A master switch, off until the person consents, runs the plane; a per-relay park keeps a relay
  without using it (knit-next ADR 063). The list lives in `AppPreferences`, each private relay's token inside its
  `?k=` URL and redacted wherever a URL is shown, as Android keeps it (knit-next ADR 2026-09.66cw). The security
  reviewer's design pass decides whether the tokens move into the Keychain item instead (ADR 2026-09.tkww). Release
  refuses `ws://` at entry and again at dial (C-7.1-2).
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
  relay until pair scopes land. Groups stay on Bluetooth.
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
