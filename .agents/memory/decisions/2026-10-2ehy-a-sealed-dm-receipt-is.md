---
id: "2026-10.2ehy"
slug: a-sealed-dm-receipt-is
title: "a sealed DM receipt is re-sealed only for a new era, a lost receipt, or past its re-arm floor"
date: 2026-10-29
topics: [receipts, ratchet, custody]
---

# ADR 2026-10.2ehy — a sealed DM receipt is re-sealed only for a new era, a lost receipt, or past its re-arm floor

Status: Accepted (2026-10-29). Mirrors knit-next ADR 2026-10.8hn6 (`afdd37204`, ahead of the pin `e63f15f4`;
knit-next #176), the second half of a paired change whose first half is ADR 2026-10.metv. Amends ADR 2026-10.5sk9's
P5d limits and its #171 entry, and ADR 2026-09.p6nb.

**Context:** the DM exists-gate (`receiveSealed`, `MeshEngine+Inbound.swift`) answers every re-delivered DM whose row
we hold, and toward an author who can read one, that answer was a new sealed `CTL_RECEIPT` under a fresh frame id:
flooded, carried by every custody for a day, a chain key spent. A sealed receipt purges nothing, so nothing stopped the
next copy, and the router lets one through per ten-minute window: up to about 144 receipts per delivered DM per day.
Two paths fed it. A carrier whose bucket kept a DM our quota evicted served it back at every exchange; ADR
2026-10.metv closed the biggest cause. And a back-fill fed by two holders needs no quota: a returning phone takes one
holder's copy, and its relay reaches the recipient past its window. `SealedReceiptLabTests` had pinned both since P5d,
at Kotlin's level. Each receipt also took a slot in our own sender bucket, widening the first path.

Knit-next deferred #176 on 2026-10-17 because one receipt per DM id for the DM's day broke two heals: LoRa's re-ack of
a re-offered DM, and ADR 2026-10.dmgw's re-seal after a reset, which needs a receipt under the new root.

**Decision:** the rule is Android's, normative for every port. When the exists-gate answers a re-delivered DM to us
from an author who can read a sealed receipt (`canSealTick`), it seals no new receipt while all of these hold, and seals
one exactly as before otherwise:

1. **Same era.** The receipt we last sealed for this DM's id was sealed under the session root we hold with the author
   now (`RatchetSessions.rootTag(of:)`). With no session held, or a store that cannot answer, it re-seals.
2. **Live in our custody.** That receipt is held and unexpired: `CustodyStore.frame(_:now:)` on the wall clock, never
   `contains`, which still counts an expired row the sweep has not reached.
3. **Inside the floor.** Less than the re-arm floor has passed since that receipt: 15 min, doubling with each re-seal in
   the same era, up to 4 h. A new era starts again at 15 min. An author custodies a frame before it opens it, so a
   receipt it holds is not always one it applied, and the floor re-arms the heal for that case.

The LoRa exemption is empty here: no plane on this port re-offers a DM without a digest, and every replay checks for a
row before it opens.

**The era comes out of the seal.** `RatchetSessions.Sealing.sealed` carries `rootTag`, `RatchetCrypto.rootTag` of the
root the committing seal used, read from `commitSeal`'s result in the same unit. On first contact, that is the session
the receipt's own prekey initiation created. `SealedControl` carries it, with the seal's wall-clock `now`, out of the
unit. Kotlin's `rootTag` is local storage, so the handle is this port's own; it is the tag our receive-state rows
already use. The memo never reads the session after the seal: a reset adopted between the two would file the receipt in
an era it was not sealed in.

**The memo** is `DmReAckLedger`, a value type the engine owns, in memory only. An entry is the DM's id (an `ExactKey`),
the receipt's frame id, the root tag, when it was sealed, and how many times it was re-sealed in that era. Only
`sendSealedReceipt` records, on a committed seal, for the DM's own id: never the room ticks riding it, never a
live-link tick or a batch, never a seal that joined a caller's unit or failed. A first delivery records as a
re-delivery does. At most 1,000 entries (`CustodyLimits.maxFrames`), the oldest receipt evicted first, and an entry
ages out 24 h after its receipt (`CustodyLimits.ttlMilliseconds`). A wall clock stepped back before an entry's stamp
reads as past the floor and drops it. A skip counts `receiptsReAckSkipped`, under Android's name, in the control
surface's `ratchet` reply.

Alternatives, as Android weighed them: one receipt per DM id for its day (breaks the reset re-seal, and loses a receipt
the author holds but never applied); keeping a delivered DM out of quota eviction (leaves the two-holder path open, and
makes the quota a per-node rule); once per process (the same holes, re-armed at every restart); and re-arming on
whether the author applied the receipt (only the author knows, and telling us is a wire change).

**Consequences / limits:**

- The worst case inside the bound is a copy landing just past each floor: ten receipts per DM per day instead of about
  144. `SealedReceiptLabTests`' quota pin now counts 1, 2, 2 over three router windows where it counted 2, 3, 4; the
  back-fill and two-hop pins count one receipt where they counted two.
- The bound holds while our receipts fit our own sender bucket of 200. Under our own quota pressure, old receipts leave
  our custody and each re-served DM re-seals as before.
- A restart forgets the memo and re-arms one receipt per held DM.
- Two copies of one DM at once can both pass the gate before either records, costing one extra receipt, as before.
- A reinstalled author that lost its session gets one `NO_SESSION` piece of reset evidence per floor from our re-acks,
  not one per copy, so its reset can trip later. Kotlin has the same bound.
- #171's second pass draws one receipt in all at a peer that already read the first copy: the reset's new era earns the
  first, and the second pass, eleven minutes on, finds it held.
- Not covered: a receipt the author holds but never applied, for a DM nobody re-delivers to us. With every digest
  agreeing, no copy comes, and the floor needs one to act.
- The trap: recording the riders, reading the era back after the seal, or testing custody with `contains`.

**Kept true by:**

- `DmReAckLedgerTests`: Kotlin's seven cases, the bounds taken from custody's, and ids compared by their bytes.
- `MeshEngineReAckTests`: inside the floor two copies draw one receipt; a receipt gone from custody, or expired and
  unswept, re-seals; past the floor it re-seals and the floor doubles; our re-root draws exactly one new-era receipt and
  a mark reset none; a first-contact v1 DM files the root its receipt's initiation created; a wall clock stepped back
  re-seals once; riders are not filed; a first delivery always seals; an author who cannot read one gets a cleartext
  receipt for every copy.
- `RatchetSessionsSealTests.aTaggedSealNamesTheRootItCommitted`.
- `ReAckLabTests`, mirroring `CustodyLabTest.aDeliveredDmBackFilledToItsRecipientPastItsSeenWindowDrawsNoSecondReceipt`
  and `SessionLabTest.anAuthorsResetDrawsOneFreshReceiptForADmACarrierBackFillsToTheRecipient`, with each link's
  crossings modelled.
- `CustodyNonMemberLabTests.aNonMemberMeetingPastTheSeenWindowDrawsNoSecondReceiptFromTheRecipient`: the #235 shape past
  the window, where the recipient stores the served DM, evicts it, and draws no second receipt, and no link carries the
  DM twice over two crossing windows. Under the old serve rule each link carried it three times and the recipient
  re-sealed once past its floor.
- `MeshEngineResetResealSecondPassTests.aSecondPassInsideTheFloorDrawsNoSecondReceiptFromAPeerThatHoldsTheDm`.

No vector, wire field or capability bit moves, so a mixed pair differs only in how many receipts the older side mints.
