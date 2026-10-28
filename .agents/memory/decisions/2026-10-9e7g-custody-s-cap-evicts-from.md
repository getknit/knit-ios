---
id: "2026-10.9e7g"
slug: custody-s-cap-evicts-from
title: "custody's cap evicts from the largest sender, and a group frame is carried only under its own roster"
date: 2026-10-27
topics: [custody, convergence, security, groups]
---

# ADR 2026-10.9e7g — custody's cap evicts from the largest sender, and a group frame is carried only under its own roster

Status: Accepted (2026-10-27). Mirrors knit-next ADR 2026-10.7mqm (`e0cbb842a`, ahead of the pin `e63f15f4`).
Amends ADR 2026-09.p6nb: the global cap's eviction key, and a group gate when a frame is stored.

**Context:** knit-next's malicious-fork review of 2026-10-26 (`eccabcd72`, finding C2) found that every custody quota
evicted the globally oldest live frame by `(sentAt, id)`, the 1,000-frame cap included, with nothing fair between
senders. This port had the same rule (knit-ios #18, `CustodyRules.evictions`). Identities are free, so five of them
sending 200 frames each, stamped just inside the five-minute future window, held the newest 1,000 frames on every
node. Every honest frame was evicted, on every node at once, and for the next five minutes every honest frame was
evicted by the write that stored it. ADR 2026-09.p6nb's rule is convergent, and that made the flood win identically
everywhere. Custody also took a frame's group id as claimed, so anyone who had seen a group's id could fill that
group's 200 slots on every carrier. Android shipped the fix first, with `vectors/custody-v1.json` as the contract.

**Decision:** the rules are Android's, byte for byte.

1. **The global cap evicts from the largest sender bucket.** The sender, group and room trims run first, in that
   order, and still keep their newest N by `(sentAt, id)`. Then, while the live frames exceed 1,000, one frame goes:
   the oldest `(sentAt, id)` frame of the sender holding the most live frames. The sizes are recounted after each
   eviction. Senders and ids compare by their bytes (ADR 2026-09.jc2x), as SQLite's `BINARY` does in
   `ForwardDao.evictFairest`. The rule still reads the live held set alone, so two nodes holding the same frames keep
   the same ones. A flood now displaces the largest buckets, which are its own.
2. **The room and group trims stay newest-N on purpose.** Every shipped build trims them that way, and a busy room at
   its quota is the ordinary festival case. A fair room trim would split an old node from a new one for good: the
   knit-next design pass's simulation split 917 of 1,000 such cases.
3. **Custody carries a group frame only for its own roster.** `CustodyRules` refuses a frame that names a group
   unless `GroupId.derive(members + departed)` equals the group's id and the sender is one of `members`, by bytes
   (`ForwardRepository.carriesGroup`). It is checked after the dead-on-arrival and future-window refusals, for every
   origin, ours included. It refuses custody only: delivery and relay still go through `GroupRoster.vet`. Every
   group frame this port sends passes, because its roster comes from a `GroupRecord` whose `members + departed` is
   the vetted founding set, and every send waits on `!hasLeft`. `KnitStore` now depends on `KnitCrypto` for
   `GroupId.derive`. Injecting a derivation into the stores would let a store built without one carry ungated frames
   without a word.
4. **The store says whether it holds the frame.** `CustodyStore.store` answers whether the frame is held after its own
   write, which is Android's answer since `e0cbb842a`. It also says whether the write changed the live set, so the
   advert's digest cue still moves when a write evicts another frame and then the new one. `CustodySync.carry` and
   `carryOwn` return "custody changed", as the engine has always read them. A roster refusal is counted
   (`groupCustodyRefused` in KnitControl's `stats`, Android's name) and logged in Android's words at debug. Android
   logs it with `Log.w`, but a forged-roster flood would fill the iPhone's log at warning, and the counter is what a
   harness reads. The id and sender are cut to eight Characters, where Kotlin's `take(8)` counts UTF-16 units. That
   difference shows only in a log line.

**Why the future window stays at five minutes:** the review suggested seconds. Under the fair cap a future stamp only
orders a sender's own frames, so it buys a flood nothing. A tighter window would refuse a fast-clocked honest frame
after the router had marked it seen, and peers' digests would differ for a seen window per frame.

**Consequences / limits:**

- **Identities are still free.** The wipe now needs roughly 1,000 pinned identities, one frame each, instead of 5.
  Bounding how fast a link brings in identities is H5, link authentication.
- **Still open:** the room flood (200 posts from fresh identities, since `IngressBudget` keys on a claimed id, H5),
  a member flooding their own group's bucket, and a per-frame byte cap. The byte cap was its own paired change, because
  a cap on one platform alone would split digests. ADR 2026-10.6n48 closed it (amendment of 2026-10-28).
- **A mixed fleet** holds different sets while the global cap binds, until every node runs this rule. Honest traffic
  rarely reaches the cap, so this is a cost of the transition and not a standing split. Lab Pixels on the pin run the
  old rule.
- **Old Android builds.** 2.0.0 to 2.2.3 send the remaining roster without `departed` after a departure. Custody
  refuses those frames, while delivery still takes them through `vet`'s within-pin arm. Nothing here needs one from
  custody: the start-up replay has no use for a frame `vet` would refuse unpinned, and `isOutlived` falls back to the
  thread's rows.
- **The trap for the next reader:** "fair" is tempting to extend to the room and group trims. Don't, unless every
  build in the field and knit-next move together (a wire-break-class change, knit-next `docs/NEXT_WIRE_BREAK.md`).

**Kept true by** `CustodyVectorTests.everyStepIsReproduced`, which runs knit-next's `custody-v1.json` through both
stores, and its `theFileStatesTheSameFutureWindow`. The fair trim's tie-break, recount and byte-keyed counting, the
gate's cases and the refusal order are pinned in `CustodyRulesTests`. Android's new `ForwardRepositoryTest` cases are
mirrored in `CustodyFairnessTests`: the Sybil flood, the honest frame during it, the frame its own write evicted, the
room and group newest-N, two arrival orders, and the gate on our own frames. The same holds for
`CustodyStoreTests.theGlobalCapEvictsFromTheLargestSenderFirst`. `CustodyFairExchangeTests` converges two or three
stores through a real `SeenSet`, and two engines through `PipeLab`'s digest rounds and `LinkCrossings`, with and without
a Sybil flood. `MeshEngineGroupInboundTests.aTruncatedPreDepartedRosterWithinThePinIsDeliveredButNotCarried` keeps the
gate out of delivery.
