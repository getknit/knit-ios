---
id: "2026-10.6n48"
slug: custody-refuses-a-frame-whose
title: "custody refuses a frame whose signed bytes exceed 60 KiB"
date: 2026-10-28
topics: [custody, convergence, security]
---

# ADR 2026-10.6n48 — custody refuses a frame whose signed bytes exceed 60 KiB

Status: Accepted (2026-10-28). Mirrors knit-next ADR 2026-10.mqzv (`ce56fec6e`, ahead of the pin `e63f15f4`;
knit-next #227), a paired change shipped in the same release (knit-ios #34). Amends ADR 2026-10.9e7g, whose "still
open" list named the per-frame byte cap, and ADR 2026-09.p6nb: one more admission refusal, and a sweep delete.

**Context:** custody counted frames and never bytes. Its 1,000 rows could hold about 500 MB of frames near the
512 KiB the radios accept, from a few pinned identities. Every replay that reads whole rows pulled that much out of
the store at once: on this port the start ratchet replay, the group replay and the seed replay
(`CustodyStore.liveFrames`). The digest round already reads only ids and lengths (`liveIndex`, ADR 2026-10.f5zs), so
it was never the cost. This was the C2 item of knit-next's malicious-fork review that ADR 2026-10.9e7g left open,
and the last open item of knit-ios #18. A cap on one platform alone would split digests, so it waited for a paired
change.

**Decision:** the rule is Android's, byte for byte.

1. **The cap.** `CustodyRules.admission(of:now:limits:)` takes the `CarriedFrame` and refuses it with
   `CustodyRefusal.oversize` when `signed.count` is greater than `CustodyLimits.maxSignedBytes`, 61,440 bytes
   (60 KiB, Android's `DEFAULT_MAX_SIGNED_BYTES`). A frame of exactly the cap is kept. Only `signed` counts, the
   frame-global bytes every node holds identically (knit-next ADR 005). `sig` does not: it is 64 bytes in production
   and empty in the vector rig, so counting it would make one vector step mean two things.
2. **First among the refusals,** before dead on arrival, the future window and the roster gate. Each refusal reads
   the frame alone, so the order only decides which reason is reported and counted: a frame both oversize and under a
   foreign roster counts as oversize, and `groupCustodyRefused` does not move. Both stores inherit it through
   `admission`, and it binds our own frames (`carryOwn`) as everyone's. The refusal comes before any write, never as
   a failed write inside a ratchet unit.
3. **It is counted and logged.** `CustodySync` counts it in `oversizeRefusedCount`, which `MeshEngine` and `Mesh`
   expose as `custodyOversizeRefused`, Android's metric name, as KnitControl's `stats` does too. It logs one `.debug`
   line with the id's first eight characters, the type and the byte count, never the payload. Android logs at
   warning. The roster line here is `.debug` for the reason ADR 2026-10.9e7g gives, and this one matches it.
4. **The sweep deletes old over-cap rows.** `sweepExpired` in both stores also deletes every row whose `signed` is
   longer than the cap: SQL by `length(signed)` on the `BLOB` column, without reading rows. It counts them in its
   return, so `MeshEngine.sweep` bumps the digest cue. Custody's TTL is 24 hours. Without the delete, a node
   upgraded with oversize rows would hold them for up to a day, and every upgraded peer would refuse them at each
   exchange. The rows it deletes are live, so this is the one exception to the sweep being digest-neutral (knit-next
   work item #8).
5. **A refusal is not a drop.** `CustodySync.carry` and `carryOwn` are custody's only callers, and `deliver` and
   `router.relay` never read their answer. The frame is still delivered and relayed, and our own still goes on the
   air.

**Why 60 KiB:** the largest honest frame this port builds is far under it. `CustodyHeadroomTests` measures `signed`
at iOS's own limits: a 2,000-unit body of three-byte characters, a 4 KiB photo, a quote with a 120-unit snippet, and
eight members with seven mentioned:

| Frame | `signed` bytes |
| --- | --- |
| v1 sealed DM | 7,283 |
| v2 DM carrying the session init | 7,085 |
| v2 group frame, 8 members | 8,258 |
| group seed DM | 742 |
| sealed tick batch, 64 acks | 1,392 |
| sealed profile | 772 |
| cleartext profile, with prekey | 949 |
| room post, widest body | 6,787 |
| room post, most mentions (666 chips, an upper bound) | 31,435 |

Android's own headroom test (`CustodyHeadroomLabTest`, knit-next `ce56fec6e`) measures more, because its limits are
looser: a DM of 13,709 bytes, a group frame of 15,335, a sealed profile of 1,547, and a room post of 56,144. That post
is 1,000 `@x` mentions with no spaces between them, the most a 2,000-unit body binds, since Android's room-post mentions
have no count clamp. It is the worst honest case on either platform, and still under the cap. The iPhone's 666-chip
figure assumes the picker's trailing space.

The cap also sits under the spool's 64 KiB `maxBlob`, so custody admits nothing the Internet plane couldn't carry.
The worst case falls from about 500 MB to 1,000 × 60 KiB, about 60 MiB.

**Alternatives not taken:**

- **The cap in the live queries,** so an old over-cap row stops counting the moment a node upgrades. Every quota,
  digest and replay query would need the filter, and any query that missed it would diverge for good.
- **Sweeping before the first own frame at start.** Android's startup sweep runs in a launched coroutine
  (`MeshManager.resumePendingFetches`), so reordering `start()` here would buy no parity.
- **A byte budget on the global cap, or evicting the largest sender by bytes** (knit-next #227 option 2). Revisit if
  60 MiB is still too much.

**Consequences / limits:** none of these touches a frame under the cap, and no honest frame is over it.

- An oversize frame is never back-filled by a digest re-serve to a late joiner.
- An oversize group frame that arrives before its seed is lost to that member, because the group replay reads only
  custody. So is an oversize sealed DM or seed that a failed unit or a closed switch left unread
  (`replayCustodiedRatchetMessages`, the seed replay): neither is opened again.
- An oversize frame of our own is never pushed to a spool, once this port has one.
- Until every node in reach has the cap, a node without it re-serves its oversize frames at each digest exchange,
  and an upgraded node refuses them each time. The roster gate (ADR 2026-10.9e7g) had the same upgrade window.
- Once per node, between the upgrade and its first sweep, an over-cap row taken before the upgrade still counts
  toward the quotas. `start()` carries our own profile and prekey before it sweeps, so a store in that window can
  evict one frame that an already-swept peer keeps. The peer re-serves it, and nothing is stranded.
- Still open: the replays read whole rows (paging them is knit-next #227 option 3, and so is `carriedBlobs()` and
  KnitControl's `custody` command), and a door cap on profile frames (knit-next #234, knit-ios #22), which will sit
  below this one.
- **The trap:** a composer check looks like the place for this. No honest frame reaches the cap, and the rule is
  custody's admission, which every node applies to the same bytes. A composer limit would bind only this port's
  frames.

**Kept true by** `CustodyVectorTests.everyStepIsReproduced`, which replays knit-next's `custody-v1.json` over both
stores, the cap-edge steps included, and checks each step's `signedBytes` before its verdict.
`CustodyRulesTests` pins the 61,440 default, the edge, `sig` left out and the refusal order. `CustodyByteCapTests`
runs the edge, a full store that evicts nothing, and the sweep over both stores. `CustodySyncTests` covers the
counters, and `MeshEngineCustodyCapTests` covers delivery and relay of a refused frame. It also has two engines that
agree after one of them sweeps a pre-cap row at start. `CustodyHeadroomTests` keeps the table above under the cap.
