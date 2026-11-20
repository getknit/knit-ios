---
id: "2026-11.3jry"
slug: custody-serves-a-peer-s
title: "custody serves a peer's mail first, in paced rounds, and evicts the most widely carried at the cap"
date: 2026-11-20
topics: [custody, convergence, mesh, security]
---

# ADR 2026-11.3jry — custody serves a peer's mail first, in paced rounds, and evicts the most widely carried at the cap

Status: Accepted (2026-11-20). A paired change with knit-next, `custody-carry-policy`, with Android leading, for
knit-next's issues #352, #349, #276 and #64. It mirrors knit-next's `feat/custody-carry-policy` at `711adae4e`, ahead
of the pin (see `.agents/context/knit-next.md`). Amends ADR 2026-09.p6nb, ADR 2026-10.9e7g and ADR 2026-10.f5zs.

**Context:** custody aimed for identical stores: the same held set gave the same kept set on every node (knit-next ADR
006, ADR 2026-09.p6nb). The maintainer decided that what counts is frames reaching their recipients, after knit-next's
mesh simulator walked two phones with full custody past each other at 1.3 m/s on a 9 KB/s link.

- **The link held about 11 s,** and each walker landed 4 of the 20 DMs meant for the other.
- **The peer's own mail waited.** A digest answer served profiles, then everything else newest received first, so the
  DMs addressed to the asking peer, about 6 KB and the only frames it could read, queued behind other people's.
- **Most of the answer died with the link.** Android handed the whole difference to the link at once, and over 80% of
  it was lost when the link dropped. This port's capped round (ADR 2026-10.f5zs, 200 frames or 256 KiB) was still a
  quarter of a minute of air on Bluetooth.
- **Two full stores never matched.** A full store evicts one frame for every frame it admits, so a pass traded frames.
  The 60 s re-offer then re-served what the peer had just declined, at every exchange, for as long as the link lasted.

**Decision:** custody carries for delivery. Below the row cap nothing changes: admission, the TTLs, the sender, group and
room trims and the digest fold stay functions of the frame and the held set, and two stores under 1,000 rows that hold
the same frames keep the same ones. At the cap only the global trim's choice of row reads local state. Nothing moves on
the wire. The numbers are shared law with Android (the contract in `knit-pair`'s order, and `vectors/custody-v1.json`).

1. **The serve order** (`CustodySync.round`, `CustodySync+Rounds.swift`). A round serves, in this order: profiles,
   newest received first; frames whose `recipientId` is the asking peer, oldest `(sentAt, id)` first; group frames whose
   own cleartext roster lists the peer, oldest first; then everything else, newest received first. Oldest first is
   frame-global, so every node agrees, a ratchet reads in sending order, and a group's seed DM lands before its posts.
   A tier only orders; nothing is withheld. A row's roster is read once, when custody stores it, and at most 8 member
   ids are remembered (`GroupInfo.maxMembers`); a larger roster, or a row not classified since a restart, orders last.
   No round loads a row it doesn't send. A sender's key goes ahead of their first frame a round serves, at most once
   per answer, as ADR 2026-09.g64k says.
2. **Paced rounds** (`CustodyAnswers`, `MeshEngine+Digests.swift`). An answer goes out in rounds of 16,384 bytes, the
   first pick always included, at least 2,000 ms apart and longer in proportion when a round passed its budget: 8 KiB/s.
   Each round is cut fresh from the store, so a DM that arrives mid-answer goes next. It leaves out what the peer's latest
   digest lists, what this answer already released, what arrived from the peer since its digest, and the memo's ids
   (rule 5). A newer digest replaces the kept one and restarts the answer's 120 s age, but never brings a round forward.
   An answer ends when nothing is left, at link-down, or at its age. The answer keeps only the digest ids we hold,
   and what it released, the keys it sent and what arrived since the digest are trimmed to the ids we still hold at
   every cut, since a peer that sends a digest a minute keeps one answer alive for hours.
   `HeldDigests.lineBytes`, 131,072 bytes unwritten, still delays a round and never enlarges one.
3. **The carry ledger** (`CarryLedger`). Per live frame, up to 8 peers believed to hold it (`CustodyLimits.spreadMax`):
   a digest that lists it, the peer it arrived from, and a release credited 2,000 ms later if its link stayed up. A
   digest is the peer's latest word, so a peer leaves the holders of what it no longer lists. Only a proven link feeds it
   (`hasProvenLink`, ADR 2026-11.hpmt): an unproven node id is only a claim. An entry dies with its row, by one feed at
   every custody write, and an id's entry is cleared before the id is written, so a frame that comes back never inherits.
   It lives in memory.
4. **The eviction order at the cap** (`CustodyRules.evictions`). While live rows exceed 1,000, one row goes at a time,
   the first by: its sender's live count, descending (unchanged); its holders, capped at 8, descending; `sentAt`
   ascending; id ascending by its bytes. The frame being written counts the peer it came from among its holders in its
   own write, since that peer holds it whether or not we keep it. Without that, two full stores linked to each other swap
   a frame per exchange for good: a re-served frame arrives held by nobody and outranks every shared row. With it, the
   re-served frame ties with the shared rows and evicts itself by `(sentAt, id)`, as under the old rule. With no holders
   recorded, the order is the old one exactly.
5. **The not-kept memo** (`CarryLedger`). On a proven link, an id released to a peer is pending, and not released again,
   until a digest at least 20,000 ms after the release judges it. Listed means kept. Lacking means not kept: the id isn't
   released to that peer for 600 s, and the peer leaves its holders. A frame addressed to the peer is never pending or
   marked, so a recipient's own mail is never withheld on a memo's word. The memo goes at link-down. At most 64 peers are
   kept, and a linked peer's is never the one evicted.
6. **The re-offer backs off** (`ReofferBackoff`, `MeshEngine+Passes.swift`). The periodic custody digest to a neighbour
   waits 60 s, doubling to 600 s while our offers draw nothing from it. A frame kept from that neighbour resets it to
   60 s at once. A neighbour is due when `now − last offer ≥ interval − 30 s`, so a tick a few milliseconds early still
   offers. The link-up digest is never held and counts as an offer. Only the digest waits: owed ticks, seeds, key asks and
   blob steps keep their own rules.
7. **Counters.** `custodyRoundsCut`, `custodyAnswersCutShort` (an answer that ended by a lost link or by age while a cut
   would still have released something), `custodyNotKept` and `custodyReoffersHeld`, in KnitControl's `status`, under
   Android's names.

What we chose against:

- **Keeping the frames this phone is likelier to deliver,** by its contacts or the nodes it has met. A digest lists what
  a store keeps, so whatever eviction reads, a peer can read back, and contacts and sightings must not be readable that
  way. The maintainer withdrew it. Custody reads no contact, sighting or meeting, and no key joins rule 4 without a
  security pass.
- **A bigger round, or a pace that follows the link.** A held Bluetooth link serves custody at 8 KiB/s at most. A drain
  signal from the link would serve faster, but it is a change to `FramedLink` on Android and is left for later.
- **Making the sender, group or room trims read the ledger.** They stay newest-N by `(sentAt, id)`: every shipped build
  trims them that way, and the flood bound rests on the sender trim (ADR 2026-10.9e7g).

**Consequences / limits:**

- **Stores at the cap differ for good,** and their digests never match. The memo and the back-off bound what that costs:
  a frame the peer declined crosses once per 600 s or per link, and an idle pair's digests reach one per 10 minutes.
- **A mixed fleet differs at the cap.** An Android build before this change still sends the whole difference and
  re-offers every 60 s. Our memo and pace bound what goes back.
- **Holders can be faked.** Digests are unsigned and proven identities are still free (#22), so a peer can raise a
  frame's holder count. The sender's count comes first, so this picks which row a largest bucket loses, never how many
  or from which smaller bucket. A full carrier can be made to drop a chosen frame of a largest bucket, its newest
  included, where the old rule always took the oldest. A fake holder needs a proven link, so it can't borrow an honest
  node's id.
- **What eviction reads, a peer can read back.** Holder counts show little: whether this phone saw another carrier of a
  frame, which is close to what holding the frame already shows.
- **A build without the link proof gets no memo and adds no holder.** It is answered at the pace, and `LinkCrossings`
  still keeps a frame from crossing one link twice in 10 minutes.
- **A frame released without its sender's key can arrive late.** When we hold no key to send ahead, the peer parks
  the frame outside custody, its next digest lacks it, and the memo marks it not kept for 10 minutes. If the key
  reaches the peer from elsewhere after its park lost the frame, we serve it only after the lapse. It is bounded and
  never lost, and a frame addressed to the peer is exempt.
- **A restart empties the ledger,** and eviction orders by `(sentAt, id)` until digests refill it. Rosters are read again
  at start.
- **A credit can run ahead of the write.** A release is credited by the clock while the link may still hold it unwritten,
  which overstates a holder count by a frame or a round, and only at the cap.
- **Two carriers serve one newcomer the same first rounds,** because the tiers order alike everywhere. The overlap is
  about a round per extra carrier, and the receiver drops the repeats.
- **A newcomer below the cap still converges,** now in 16 KiB rounds inside one answer, where it took a digest per
  slice: 1,000 frames of about 600 bytes take about 75 s. A convergence check by exact sets, such as `interop.py`'s
  `custody-converges` and the soak's parity check, holds only while the union of the two stores stays under the cap.
- **The trap:** reading a contact, a sighting or the block list into rule 4 to keep a friend's mail. See "What we chose
  against".
- **Kept true by:**
  - `CustodyVectorTests`, knit-next's 46 steps over both stores; the first 33 are unchanged from before;
  - `CustodySpreadTests` (both stores), for the order key by key, the trims that never read the ledger and the old order
    with no holders;
  - `CustodySyncTierTests` and `CustodySyncRoundTests`, for the tiers, the stop that never skips and the rows a round
    loads;
  - `MeshEngineCustodyAnswerTests`, for the pace, the endings, the memo, the proven-link gate, and an answer held
    open for hours whose sets stay within the cap;
  - `CustodyCarryConstantsTests`, for every constant, beside `CarryLedgerHolderTests`, `CarryLedgerMemoTests`,
    `CustodyAnswersTests` and `ReofferBackoffTests` (the contract's worked cases);
  - `LinkPipeCustodyCarryTests`, two engines, for the pace on the pipe, a cut mid-answer that credits nothing, two full
    stores that serve each other's mail first and then settle to the lapse bound with digests 600 s apart, and the
    back-off.
