---
id: "2026-10.metv"
slug: custody-serves-a-group-s
title: "custody serves a group's frames to any peer"
date: 2026-10-29
topics: [custody, convergence, groups]
---

# ADR 2026-10.metv — custody serves a group's frames to any peer

Status: Accepted (2026-10-29). Mirrors knit-next ADR 2026-10.hr9f (`9f53dc34f`, ahead of the pin `e63f15f4`;
knit-next #176 and #235), the first half of a paired change whose second half bounds the sealed re-ack. Amends ADR
2026-10.f5zs's fourth rule (a group frame no longer skips a peer outside its roster) and ADR 2026-09.p6nb.

**Context:** `CustodySync.missing` served a carried group frame only to a peer its roster named, as Android's
`ForwardSync.onDigest` did. A custody bucket keeps its newest frames by `(sentAt, id)`, so two nodes keep the same
frames of a sender only when they hold the same set of that sender's frames. A non-member that missed some of a
member's group posts live never had them back-filled. Its bucket for that member stayed smaller and kept older frames,
above all that member's DMs, which every member's quota had already evicted. At every digest exchange it served them
back, and each was evicted again in the write that stored it. A DM served back to its recipient past the router's
window drew a fresh sealed receipt, itself carried for a day (ADR 2026-10.5sk9's P5d limits). knit-next #235 caught
the loop on two Pixels on 2026-10-28, and #176 traced the receipt cost. On this port the round loaded each group
frame to read its roster, and a frame without the peer took no slot (ADR 2026-10.f5zs).

**Decision:** a digest reply serves every live frame the peer's digest lacks, whatever its form. A group's frame goes
to a non-member exactly as a room post does, and the roster load goes with the check. Nothing else in the round
moves: profiles first, the key ahead of a keyless backlog (knit-next ADR 2026-09.g64k), the crossings skip, no author
skip, and the budget of 200 frames or 256 KiB. What custody stores doesn't move either. `CustodyRules.carriesGroup`
already stores a group frame whatever our membership (ADR 2026-10.9e7g), so a back-fill hands a non-member only what
the live flood would have handed it. Convergence is shared law, so both ports hold this rule.

Alternatives, the ones Android's ADR weighed, which hold here too:

- **Keep the filter, and spare a member's DMs from the quota at a non-member.** That is a per-node rule in the trim,
  and the non-member's digest would never match.
- **Bound only the re-ack.** That ends the receipts, not the re-serves. It is the second half of this change, beside
  this one.
- **A per-link memo of frames the peer refused.** It stops the re-serve on one link and leaves the digests unequal.

The roster rides in the clear on every group frame, and the live flood already reaches every non-member in range. A
back-fill only extends that in time, to a non-member that was away. The body stays sealed.

**Consequences / limits:**

- **A back-fill once per frame:** at most the per-group quota of 200 for each group a non-member meets, under its
  sender buckets. After it the held sets are equal and the diff is empty.
- **The round no longer looks past a busy group.** A group frame without the peer used to be skipped ahead of the
  budget check, so it never filled a round. Now a non-member's first rounds may go on a group's frames, and an older
  DM it is owed follows at a later digest. Each 60 s digest answers the next slice, as for any newcomer.
- **A newcomer next to a full carrier fills its own cap.** The keys served ahead of a keyless backlog are custodied as
  profiles, so 1,000 frames and their keys overflow the newcomer's 1,000 rows, and the fair trim settles both sides
  (ADR 2026-10.9e7g). Android serves and stores keys the same way.
- **One relay per back-filled frame per link per seen window:** a served copy is a fresh wrapper with a full hop
  budget.
- **No picture pulls.** This port fetches no picture for a carried frame (ADR 2026-10.8hek), so a back-filled group
  frame only keeps blobs we already hold from the sweep for its day (`carriedBlobs`).
- **A mixed fleet:** a non-member that meets only older builds stays short of a group's frames until one of them
  updates. One current node serving it is enough.
- **Not covered:** a DM handed back to its recipient by a back-fill fed by two holders needs no quota. The second half
  of this change bounds the receipt it draws.

**Kept true by:**

- `CustodySyncTests.aNonMemberThatLacksAGroupFrameIsServedIt` and `theKeyGoesAheadOfAGroupBacklogToANonMember`,
  mirroring `ForwardSyncTest`.
- `CustodySyncRoundTests.aDMBehindFourHundredGroupFramesThePeerIsNotInFollowsThemOnceEach`: three rounds of 200, 200
  and 1, no id twice.
- `CustodyNonMemberLabTests.aNonMemberBackFilledAGroupDropsTheDmTheMembersEvicted`, three engines mirroring
  `CustodyQuotaLabTest`, meeting inside the routers' seen window since the lab keeps no link crossings. A non-member
  holds a member's DM that the members evicted. When the three meet, no link carries that DM twice, and the three
  custodies agree with the DM in none of them. With the roster check put back, the non-member wrote the DM twice
  toward each member at the meeting and five times past the window, and custody never agreed.
- `LinkPipeCustodyRoundTests.aNewcomerFacingAFullCustodyConvergesInCappedRounds` now counts every group frame as
  owed, under a roomier cap so it stays about the rounds. Its sibling
  `aNonMemberNewcomerFacingAFullCustodyConvergesUnderTheDefaultCap` meets a full carrier at the default cap: both
  custodies agree within 15 digests (13 seen), no frame crosses more than twice, and no served key is held on one
  side only.

No vector moves: `custody-v1.json` pins store-time rules, and this is a serve rule.
