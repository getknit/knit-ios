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

**Amended 2026-10-15, phase P5c:** sending the sealed form moved to phase P5d. P5c ports the ledger that will send it,
`AckSync`, with seams that cannot seal yet (ADR 2026-10.5sk9's P5c amendment). Where the amendment above has a sealed
tick re-sent on a doubling backoff, this port re-sends nothing between links. Kotlin's best-effort re-sends ride the fast
plane, so here a sealed tick's bytes go once, over the live link that ends its entry. A group's batch still escalates
into custody as one sealed DM-form frame, carried for a day, which nothing purges.

**Amended 2026-10-16, phase P5d:** with the ratchet's switch on, our receipts and ticks take the sealed form toward an
author whose pinned profile carries `CAP_RATCHET` and a bundle (ADR 2026-10.5sk9's P5d amendment).

- **The sealed DM receipt purges nothing, ours included.** Our custody keeps the DM to its TTL as every carrier does,
  and while our custody holds it our digest lists it, so no neighbour's back-fill serves it to us. A copy still reaches
  us two ways, and each past the router's window is answered with one more sealed receipt, as Kotlin does
  (`InboundPipeline.kt:946-955`). Our quotas may evict it first, and then every holder next to us serves it. Or a node
  that lacks it and links to two holders (a returning phone's or a newcomer's back-fill, or a carrier whose quota
  evicted it) relays the first copy it gets to the other holder before that holder's own copy crosses: a served frame
  floods on (`ForwardSync.kt:14-15`), a serve stamps nothing in the server's seen set, and every node it reaches past
  its router window relays it on, holders included (`MeshEngine.swift:221-233`, `MeshRouter.kt:113-114`). So the
  recipient answers that copy wherever the re-flood finds it, though it still holds the DM. Purging our own copy behind
  a sealed receipt would have had every carrier re-serve it all day, and the exists-gate answer each copy with another
  sealed receipt.
- **The cleartext receipt,** toward an author who cannot read a sealed one and when the facade cannot seal, still purges
  and self-vaccinates. A store that fails sends neither and purges nothing, as Kotlin's throw does.
- **The quota cost:** a delivered DM now keeps its row on every node for its day, where the cleartext receipt took it
  out. Each sender's 200 holds its DMs and its sealed receipts alike, so a pair past about 100 DMs each way a day
  evicts by quota before the TTL, undelivered frames included, where cleartext receipts left room for about 200. Each
  re-ack above is one more row in the acker's 200. Each link's 60 s digest grows with it all, toward the cap of 1,000.

With the switch off nothing changes. `MeshEngineSealedReceiptTests` and `SealedReceiptLabTests` keep it, the lab with a
DM our quotas evicted re-acked once per router window until no custody holds it, and a back-fill fed by two holders
buying one more sealed receipt from a recipient that holds the DM, next to the returning node or two hops away.
Bounding the re-ack is knit-next #176's, for both platforms to take.
