# Roadmap

What is in flight, what is next, and what is deferred on purpose. **Don't start a deferred item without
explicit direction.** Update this file in the change that ships an item.

## In flight

- **The MVP** (`.agents/specs/mvp.md`). P0 is nearly done: the repo, the gates and CI are in place,
  spikes (a), (b), (c), (d) and (f) passed, and the GitLab project `knit/knit-ios` exists with its
  `knit-local` runner registered and online. Spike (e) passed against the Pixel 3: Android finds the BlueZ
  advert, dials the LE CoC listener and completes the two-way HELLO, and the advert comes back after each
  link (`.agents/context/linux-peer.md`). Still owed: the first push.
- **P1, the wire (`KnitWire`):** the CBOR codec, every MVP wire type, link records, HELLO, DIGEST, the advert
  and the id and text rules are in. All 57 knit-next golden vectors round-trip, and 33 typed fixtures
  encode to Kotlin's exact bytes. Line coverage is 98 %, and each of the three libFuzzer harnesses ran ten
  minutes clean on 2026-09-25. Done.
- **P2, crypto and identity (`KnitCrypto`):** bundles, node ids, identity keys and their store, signing,
  v1 DM seal and open, the safety number, aliases and the device tag are in, with the RFC vectors and every
  knit-next golden. Line coverage is 97 %. A2's keyed vectors pass, the safety number among them, and
  knit-next verifies and opens the frames this port emits. Done: A2 merged, and the vectors are pinned to
  knit-next `1f3befcd`.
- **P3, the mesh engine (`KnitMesh`, `KnitStore`):** done on 2026-09-25, pending the maintainer's review.
  - **Link layer:** the `LinkManager` behind a `Radio` protocol, with A1's admission rules (ADR 2026-09.6es2).
  - **Router and custody:** flooding and custody under Android's quotas, with the rules in one `CustodyRules`
    the SQL store will share (ADR 2026-09.p6nb).
  - **The rest of the engine:** profiles, room ticks and DM receipts, key recovery with parking, message
    requests, and the pending-key outbox.
  - **Engine and driver:** the engine is synchronous behind one `Mesh` actor (ADR 2026-09.gq84), and wire ids
    key every map by their bytes (ADR 2026-09.jc2x).
  - **Tests:** the MVP cases of knit-next's `MeshRouterTest`, `ForwardSyncTest`, `ForwardRepositoryTest`,
    `ForwardDaoTest`, `AckSyncTest`, `KeyExchangeTest` and `PendingInboundTest` are ported. Line coverage is
    100 % in both targets, and the suite is clean under TSan and ASan.
  - **Still owed:** the mesh lab, deferred below; P3's exit is these gates instead.
- **Companion change A1 in knit-next:** the responder accepts a dialer it never sighted. It is needed
  before MVP acceptance and should land during P3 or P4. Not started.
- **Companion change A2 in knit-next:** merged on 2026-09-25 as `0c0756f6` and `1f3befcd`. Done.

## Next, after the MVP

- **DM forward secrecy:** the v2/v3 epoch ratchet, with `CAP_RATCHET`, `CAP_CRYPTO_V3` and `CAP_INLINE_ACK`,
  and sealed receipts, reactions and profile updates. It comes before any public build. Keyed vectors come
  first (`.agents/context/crypto.md`).
- **Contacts:** QR verification in person, and contact links at a distance (`docs/CONTACT_CARD.md` in
  knit-next).
- **Companion change A3:** Android finds and dials iPhones.

## Deferred by design

- **The mesh lab:** multi-node scenarios over a lab transport and radio, `assertConverged`, seeded chaos runs
  and the mesh-lab-reviewer persona. The maintainer asked on 2026-09-25 to skip it for now, so P3 closed on
  unit tests, coverage and both sanitizers. Because the engine is synchronous, a later lab could run
  deterministically from a seed (ADR 2026-09.gq84).

- **Message features:** avatars, attachments, reactions, replies, mentions and typing indicators.
- **Groups,** with group keys and roster rules.
- **Search, drafts and backups.**
- **Moderation, block and report.** App Store rule 1.2 requires them before a store build.
- **App Store readiness:** the privacy manifest, the export-compliance answers and the review notes. The
  GPL exception is already in place.
- **Background discovery,** once P8 shows what iOS allows.
- **Never on iOS:** Wi-Fi Aware, the BLE side channel, spool relays and commons, LoRa, and Wi-Fi Direct.
  These are ADR-recorded scope decisions, not a backlog.
