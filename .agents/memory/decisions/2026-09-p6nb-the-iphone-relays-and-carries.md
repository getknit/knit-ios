---
id: "2026-09.p6nb"
slug: the-iphone-relays-and-carries
title: "the iPhone relays and carries custody under Android's quotas"
date: 2026-09-25
topics: [custody, mesh, interop]
---

# ADR 2026-09.p6nb — the iPhone relays and carries custody under Android's quotas

Status: Accepted (2026-09-25)

**Context:** Android serves custody only in answer to a `DIGEST`, and it serves every live frame the digest
omits (`ForwardSync.kt:97`). A node that sends no digest gets no back-fill. A node whose digest leaves out
frames Android carries gets those frames again at every 60-second exchange, for as long as they live. A leaf
iPhone that kept only its own frames would do exactly that: every Android neighbour would re-serve it up to a
thousand frames a minute. And MVP item 7 needs the iPhone in the middle of a line, carrying posts and DMs
both ways.

**Decision:** the iPhone runs the whole router and custody, with Android's numbers. It floods with 0–150 ms
of jitter, cancels a relay once two distinct neighbours have been heard, and hands a point-to-point DM-form
frame its last hop. Custody follows the entry rule (verified, custodial, and flooded or a profile) and counts
our own frames. It uses 24-hour TTLs, 6 hours for room posts, and the quotas in Android's order: 200 per
sender, 200 per group, 200 room posts and 1000 in all. Eviction is by `(sentAt, id)` with the id's bytes
compared, dead-on-arrival and future-dated frames are refused, and a recipient's receipt purges a DM and
tombstones it for 24 hours. A digest goes out at link-up and every 60 s. The rules live in one pure
`CustodyRules` in `KnitStore`, so the SQL store (P5) applies the same ones. Carrying only our own frames was
the alternative, and the digest arithmetic above rules it out.

**Consequences / limits:** an iPhone spends air and battery on other people's frames, as every Android phone
does. The custody limits are cross-platform law, and changing one here without knit-next breaks convergence
for the whole mesh. The iPhone refuses to show a cleartext DM, where Android would deliver it. No Android
build sends one, and one in the clear would pass for private. `CustodyStoreTests` runs every store
implementation against the ported `ForwardRepositoryTest` and `ForwardDaoTest` cases. `CustodySyncTests`,
`RouterTests` and the `MeshEngine*Tests` pin the rest.

**Amended 2026-10-15:** with the ratchet on (ADR 2026-10.5sk9), receipts take Android's sealed form toward a peer
that can read one, and two custody rules follow it (`InboundPipeline.kt:2819-2830` and `:2894-2957`, `AckSync.kt`,
at knit-next `ac491f4c`):

- **A sealed DM receipt purges nothing, anywhere.** It is a ratchet chat frame, flooded and custodied like any other.
  Carriers cannot read it, so the delivered DM leaves every custody, ours included, on its TTL.
- **A sealed tick is sealed once.** Its bytes are re-sent verbatim on a doubling backoff until a live link carries
  them (knit-next ADR 053), where the cleartext tick takes a fresh id at each attempt.

A cleartext receipt, still the form toward a peer without the ratchet, purges and self-vaccinates as before. Both
rules land with the ratchet's DM phase, in two steps. Receiving is P5a's: with the switch on, a sealed receipt or a
sealed tick batch opens here and purges nothing. Sending is P5c's: until then every receipt and tick this iPhone sends
stays cleartext, a ratchet DM's receipt included.
