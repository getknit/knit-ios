---
id: "2026-10.7kxj"
slug: an-asker-s-echoes-are
title: "an asker's echoes are budgeted and unnamed blobs swept on the tick"
date: 2026-10-27
topics: [mesh, blobs, security]
---

# ADR 2026-10.7kxj — an asker's echoes are budgeted and unnamed blobs swept on the tick

Status: Accepted (2026-10-27)

**Context:** knit-next's malicious-fork review of 2026-10-26 (`eccabcd72`, finding H3 and H2's prefix item) found that
one neighbour, with no second device, can fill a phone's storage with bytes it chose. This port had the same path
(knit-ios #20, checked against `3555777`):

- **An echo had no byte cost.** A `blobreq` for a hash we lack makes a want on the asker's behalf, an echo (ADR
  2026-10.8hek). `echoRefusal` weighed the ask's hop budget and deadline only. So a fork could ask for 256 made-up
  hashes with `pull: 3`, answer HAVE at the next cycle, and serve up to 8 MiB + 64 KiB under each. The junk hashed
  correctly because the fork took the hashes from the junk. That is about 2 GiB per round.
- **What nothing names stayed until a start.** `sweepUnreferencedBlobs` ran only in `MeshEngine.start()`, once per
  process, and a backgrounded iPhone can go days without one. ADR 2026-10.ym9y said so outright: "a blob fetched on an
  asker's behalf therefore lives until the next start".
- **Echoes pushed out our own wants.** The want set dropped its oldest want at 256, whatever made it, so the fork's
  asks evicted the user's own photo fetches every cycle.
- **Echoes took every kept prefix.** A cut stream kept a prefix for any accepted attachment, eight files and 32 MiB at
  most (ADR 2026-10.w6rn). Eight echo streams cut past 16 KiB evicted every honest prefix.
- **A link's serve queue had no bound,** so one asker could queue a serve of every blob held. Android's is
  `Channel.UNLIMITED` (`FramedLink.kt:107`).

Android has fixed none of this at knit-next `4408e0fca`. The review's suggested fix, applying
`CARRIER_BLOB_BUDGET_BYTES` in `echoFor`, bounds nothing on its own. `carrierOnlyBlobBytes` (`BlobDao.kt:76-81`) counts
blobs a custody row names and no message row does. An echo-pulled blob has no row of any kind and counts 0.

The design passes caught three shapes that would have shipped broken:

- **A sweep read as a store answer.** Each read behind `referencedBlobs()` answers empty on a SQL error. A 600 s sweep
  reading outside a unit would read one error as "nothing named" and remove our own sent photos 144 times a day.
- **A reservation for every echo.** Reserving 8 MiB per echo want lets about 15 stand. An honest root pulling dead
  photos through the iPhone, ones nobody in reach holds, would then hold every slot for hours, and every other root's
  pull-through would be declined.
- **A hard cap per asker.** A root re-asks its whole backlog in the same order every cycle. A cap of 16 echoes per
  asker, declining past it, kept the first 16 standing for good and stranded a live photo past the 16th. Letting the
  asker's oldest echo give way, once it had stood a step and was 5 s old, still stranded everything past the 32nd: the
  window flipped between the first and second 16 each cycle. Any hard count per asker is a cache smaller than the
  asker's cycle. The design came back to the maintainer after these two review rounds (review-rounds §5).

**Decision:** five local rules, none of them on the wire, in custody or in the digest. Each side can adopt them alone,
and Android needs no change.

1. **An echo is told apart from a want of ours** (`BlobExchange.Origin`).
   - **What makes a want ours:** a want with no asker. An echo becomes ours when we ask for it ourselves, including one
     whose bytes are already arriving (`promoteArriving`). A restart from byte 0 after a failed splice is ours too.
   - **Eviction:** a full set drops its oldest echo, and drops a want of ours only once no echo is left. A new echo that
     would cost a want of ours is declined.
   - **Fair share, no cap per asker:** while the set has room, every echo is admitted. A full set evicts from the asker
     holding the most echoes (keyed by the link's node id, the new echo counted), its oldest by when it was made,
     preferring one with nothing arriving or parked. A tie goes to the asker whose oldest echo is oldest. This is the
     shape of knit-next's fair custody eviction (its ADR 2026-10.7mqm, knit-ios #18), which takes from the largest
     sender. An honest root alone keeps every echo it asks for. A fork flooding a full set mostly churns its own, and a
     fork and a root contending settle near half the set each.
   - **Withdrawals:** every want dropped by an eviction withdraws the asks still standing on it with a
     `blobcancel` (knit-next ADR 2026-10.nsr7).
2. **What we hold for others has a byte budget** of 128 MiB (`echoBudgetBytes`). That is Android's
   `CARRIER_BLOB_BUDGET_BYTES` (`FrameFanout.kt:76`), which its KDoc calls a local knob.
   - **What counts:** the bytes held that no row names, read as `totalBytes(among: held − blobsTheRowsName())`. A blob a
     carried frame names is still kept (ADR 2026-10.5sk9, P7c), but it counts, so a fork's room post cannot exempt the
     bytes it asks for.
   - **What is reserved:** 8 MiB + 64 KiB for each echo with a fetch standing on a holder that answered, or with bytes
     arriving. A dead echo reserves nothing.
   - **Over the budget:**
     - a new echo is declined (`blob no-echo … (over budget)`);
     - an echo's next fetch is held back (`blob no-fetch … (over budget)`);
     - a file that lands for an echo alone is refused against its measured size (`… is past the echo budget`), and its
       hash is remembered until the next sweep (at most 64), so the next cycle does not pull it again.
   - **How it is measured:** the count is measured inside a store unit at start and on every 600 s sweep. A failed unit
     keeps the previous value, since `totalBytes` answers 0 on an error. Between measures, each echo-only file that
     lands adds its size. So the count only ever runs high, and when it reads spent it is measured again, at most every
     45 s, before anything is declined.
3. **What nothing names goes on the 600 s sweep.**
   - **One predicate:** the start sweep and the tick share `sweepUnnamedBlobs(storedBefore:)`. It reads the candidates
     and `referencedBlobs()` inside one store unit, and removes only once the unit commits.
   - **What it never removes:** a blob that is wanted, arriving, in flight to any neighbour or parked.
   - **The age cutoff:** on the tick a blob must also have been stored at least 30 minutes ago
     (`BlobExchange.wantMilliseconds`, an echo's own life), so an asker re-asking within its echo's life still finds it.
     The start sweep keeps its any-age rule. `BlobStore.hashes(storedBefore:)` reads the `storedAt` column that every
     insert already wrote.
   - **`releaseDeletedPhotos` is gone.** It read outside a unit, and the tick now covers a deleted message's photo once
     its frame leaves custody (ADR 2026-10.u7cq).
4. **Only a want of ours keeps a cut prefix.** `MeshTransport.acceptFiles(_:resumable:photoOnly:)` hands the links the wanted set
   and the subset that is ours. The engine sends it whenever either set changes, so a promotion reaches the link.
   `keepCutFile` keeps a prefix only for a key that is resumable at the moment of the cut. The header gate, the prefix
   read and the splice still read the wanted set, so an echo's re-ask that names an offset still splices onto any
   prefix held.
5. **A fresh ask is not queued behind 8 waiting files** on its asker's link (`maxWaitingServes`). That is about 64 MiB,
   minutes of work at Bluetooth's rates. Past it nothing is stamped, and the asker asks again at its floor. A parked ask
   whose turn came is queued whatever waits.
   - The issue proposed a per-link meter on `blobreq` instead. It would have counted the wrong thing. An honest asker
     can send three `blobreq`s for one hash to one holder in one cycle (the pull, the fetch on HAVE and a re-fetch on
     confirm), and a link-up fires up to 256 newcomer pulls at once, while the cost is the bytes served.
   - Android's asker, refused this way, waits the queue out (`streamWait`), confirms, re-asks once, and at worst holds
     to its 45 s floor before the next cycle.

The differences from Android are all deliberate. At `4408e0fca` Android keeps no origin, applies no budget to an echo,
evicts its oldest want whatever made it, keeps any cut prefix, collects orphans only at start and bounds no serve queue.
`blob no-echo`'s new reasons, `blob no-fetch` and `blob no-serve` are this port's words alone.

**Consequences / limits:**

- **An echo's cut stream restarts from byte 0** on the hop from its holder to the iPhone. The asker's own hop from us
  still resumes, since we serve from its offset. A large photo pulled through an edge link that keeps cutting can fail
  on that hop. A follow-up could give echoes a small allowance of prefixes of their own.
- **A blind echo reserves nothing.** One asked of a neighbour without `CAP_BLOB_HAVE` can stream in and then be refused
  on landing: wasted airtime, but bounded by the budget's re-check.
- **A slow asker can pay a re-pull.** A neighbour in a long backoff that asks back after 30 minutes finds the blob swept
  and pulls it again.
- **A deleted message's photo outlives its frame** by up to 30 minutes plus one sweep.
- **The echo-only check on landing reads rows outside a unit.** A failed read can refuse a file a row names once, while
  the budget is spent. The next 60 s re-offer wants it as ours, and the refused memo gates echoes only.
- **A fork that rotates node ids** splits its echoes across ids, so each holds a smaller share and is evicted later.
  The byte budget still bounds what all of them hold, and they can never evict a want of ours.
- **Echo fan-out is as before.** Each new echo queries our neighbours and asks them to pull, so a fork churning its own
  echoes in a full set costs that traffic per ask. Metering it belongs to knit-ios #24.
- **Under a flood, an honest root's backlog can still strand** past its share of the set: about 128 echoes against one
  fork.
- **Our own wants can still be minted** by strangers' advertised photos (knit-ios #22). Room posts and requests are
  bounded by ADR 2026-10.vzem.
- **The echo state is in memory.** A restart drops every echo and the refused memo, and measures the budget afresh. Our
  own wants come back from the stores' re-arm.
- **When knit-next fixes H3,** read its numbers against these and re-align any that differ for a reason Android found.
- **Oracles:** `status.blobs` gains `echoFetchesHeld`, `echoFilesRefused` and `servesRefused`. All three stay 0 in an
  honest run. `echoesDeclined` now also counts the new reasons, beside 8hek's "fetch only" and "past its deadline", so
  an honest run can still raise it.
- **Guards:** `BlobEchoBoundsTests` (origin, fair eviction, the pure budget), `MeshEngineEchoBudgetTests` (the
  fork, the root bridging dead photos, the fixed-order root past its cap, the landing re-check, eviction's
  withdrawal), `MeshEngineEchoSweepTests` (the tick, its keeps, a failing store, the serve cap),
  `LinkPipeEchoBoundsTests` (an own prefix surviving eight cut echo streams and resuming, an honest burst of 12 between
  two engines), `LinkFileCutTests`' `Resumable` cases, `LinkFileSpliceTests` and `BlobStoreTests` over both stores.
