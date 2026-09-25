# Roadmap

What is in flight, what is next, and what is deferred on purpose. **Don't start a deferred item without
explicit direction.** Update this file in the change that ships an item.

## In flight

- **The MVP** (`.agents/specs/mvp.md`). P0 is nearly done: the repo, the gates and CI are in place, and
  spikes (b), (c), (d) and (f) passed. Still owed: spike (a), GRDB on Linux, which waits for
  `libsqlite3-dev`; spike (e), BlueZ on `hci1`, which waits for the adapter; the GitLab remote; and the
  `knit-local` runner.
- **P1, the wire (`KnitWire`):** the CBOR codec, every MVP wire type, link records, HELLO, DIGEST, the advert
  and the id and text rules are in. All 57 knit-next golden vectors round-trip, and 33 typed fixtures
  encode to Kotlin's exact bytes. Line coverage is 98 %, and each of the three libFuzzer harnesses ran ten
  minutes clean on 2026-09-25. Done.
- **P2, crypto and identity (`KnitCrypto`):** bundles, node ids, identity keys and their store, signing,
  v1 DM seal and open, the safety number, aliases and the device tag are in, with the RFC vectors and every
  knit-next golden. Line coverage is 97 %. A2's keyed vectors pass, the safety number among them, and
  knit-next verifies and opens the frames this port emits. The phase closes when A2 merges.
- **P3, the mesh engine (`KnitMesh`):** started. In so far: the seen set, the room-post ingress budget, link
  crossings, the presence tracker, and the promotion and connect-backoff policies, each with its knit-next
  tests ported. Next: the custody store, the router, the `LinkManager` behind a `Radio` protocol, sync,
  profiles, receipts and key recovery, then the lab.
- **Companion change A1 in knit-next:** the responder accepts a dialer it never sighted. It is needed
  before MVP acceptance and should land during P3 or P4. Not started.
- **Companion change A2 in knit-next:** done on branch `test/ios-golden-vectors`, in the worktree
  `~/source/knit-next-ios-vectors`, and not committed: `vectors/` with `wire-v1.json`, `keyed-v1.json` and
  `ios-emitted-v1.json`, `KeyedVectorTest`, `IosEmittedVectorTest`, ADR 2026-09.fzh7 there, and corrected
  `IOS_PORT_REVIEW.md` and `ARCHITECTURE.md`. It waits for the maintainer's review. Once it merges, move the
  pin and run `scripts/sync-vectors.py` against knit-next `main`.

## Next, after the MVP

- **DM forward secrecy:** the v2/v3 epoch ratchet, with `CAP_RATCHET`, `CAP_CRYPTO_V3` and `CAP_INLINE_ACK`,
  and sealed receipts, reactions and profile updates. It comes before any public build. Keyed vectors come
  first (`.agents/context/crypto.md`).
- **Contacts:** QR verification in person, and contact links at a distance (`docs/CONTACT_CARD.md` in
  knit-next).
- **Companion change A3:** Android finds and dials iPhones.

## Deferred by design

- **Message features:** avatars, attachments, reactions, replies, mentions and typing indicators.
- **Groups,** with group keys and roster rules.
- **Search, drafts and backups.**
- **Moderation, block and report.** App Store rule 1.2 requires them before a store build.
- **App Store readiness:** the privacy manifest, the export-compliance answers and the review notes. The
  GPL exception is already in place.
- **Background discovery,** once P8 shows what iOS allows.
- **Never on iOS:** Wi-Fi Aware, the BLE side channel, spool relays and commons, LoRa, and Wi-Fi Direct.
  These are ADR-recorded scope decisions, not a backlog.
