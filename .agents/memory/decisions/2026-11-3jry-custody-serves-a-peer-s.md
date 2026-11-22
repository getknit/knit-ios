---
id: "2026-11.3jry"
slug: custody-serves-a-peer-s
title: "custody serves a peer's mail first, in rounds as the link drains, and evicts the most widely carried at the cap"
date: 2026-11-20
topics: [custody, convergence, mesh, security]
---

# ADR 2026-11.3jry — custody serves a peer's mail first, in rounds as the link drains, and evicts the most widely carried at the cap

Status: Accepted (2026-11-20). A paired change with knit-next, `custody-carry-policy`, with Android leading, for
knit-next's issues #352, #349, #276 and #64. It mirrors knit-next ADR 2026-11.bmks on knit-next's
`feat/custody-carry-policy` at `834ab80b7`, ahead of the pin (see `.agents/context/knit-next.md`), which amends
knit-next ADR 006, ADR 2026-10.7mqm, ADR 2026-10.hr9f, ADR 2026-10.a5yj and the wording of ADR 2026-09.tjfb on the
digest slot. Amends ADR 2026-09.p6nb, ADR 2026-10.9e7g and ADR 2026-10.f5zs.

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
2. **Rounds as the link drains** (`CustodyAnswers`, `MeshEngine+Digests.swift`). An answer goes out in rounds of 16,384
   bytes, the first pick always included. No clock paces it: the first round is cut when the digest arrives, and the
   next as soon as the link to that peer holds less than one round unwritten (`MeshEngine.linkTakesARound(to:)`, which
   reads `MeshTransport.queuedFrameBytes(to:)`). Each round is cut fresh from the store, so a DM that arrives mid-answer
   goes next. It leaves out what the peer's latest
   digest lists, what this answer already released, what arrived from the peer since its digest, and the memo's ids
   (rule 5). A newer digest replaces the kept one and restarts the answer's 120 s age, and cuts no round of its own. An
   answer ends when nothing is left, at link-down, or at its age, and at every look its endings are judged before the
   link is tested, so a link that never drains still ends its answer by age. The answer keeps only the digest ids we hold,
   and what it released, the keys it sent and what arrived since the digest are trimmed to the ids we still hold at
   every cut, since a peer that sends a digest a minute keeps one answer alive for hours. A release is remembered only
   until a digest can speak to it: a digest from the peer makes the answer forget every id it released at least
   20,000 ms before, and then the digest and the memo decide. Without that, an answer kept alive by digests would
   withhold a frame lost with the link still up for as long as the link lasted.

   **What "unwritten" counts.** What the link holds for that peer and has not written, frames, keys and digests alike,
   less the part of a streaming file's records still unwritten, so a photo never holds an answer off. Each FILE record
   handed to a radio that reports its writes is placed at where its last byte ends in the channel's order, and its
   bytes leave the count as they are written, not when the report comes back: counting a whole record until its
   report would hide a round of frames for a moment. Both production radios report FILE writes; only the demo radio
   and test radios don't, and they count nothing queued. knit-peer's BlueZ radio adds what its L2CAP socket holds below
   the outbox (`OutboxLevel.belowBytes`, `SO_SNDBUF` less `TIOCOUTQ`), read on the caller's thread under the lock the
   loop takes before a close, and failing safe to the outbox alone. A FILE record's bytes still in the socket after its
   report count as the file's until the socket has sent them. The stall close still reads the outbox alone, so a socket
   draining slowly is never closed as stalled. Two slivers are uncounted: a
   file's header, about 200 bytes, written with no report, counts as frames, and a waiting digest replaced by a
   smaller one ahead of a chunk undercounts by the difference.

   **The iPhone counts its outbox alone.** Both iOS radios count a byte as written when the stream or socket takes it,
   and CoreBluetooth's L2CAP stream says nothing of what it holds. A device trial on 2026-11-20 put what sits below the
   iPhone's outbox at about a round: 15.9 KB at worst on a 1M link, 10.7 KB typically, measured as the bytes the stream
   accepted less those the far end read while the iPhone's outbox held up to 137 KB waiting. That bound includes bytes
   in the air. So no estimate is built, and on the iPhone a cut can lose up to about three rounds, and a credit can run
   a round ahead.

   **knit-peer's line is cautious.** The same trials ran the BlueZ reading on a real socket: 20 relinks and two floods,
   over 8,000 reads, none on a closed descriptor and none failing, and the backlog fell back to 0 as the link drained.
   The reading charges about 7.6 times the payload at 247 bytes a segment, so the one-round line trips at about 2 KB of
   payload, and a link faster than about 21 KB/s would idle between looks. No 1M link is, and nothing scales the
   reading until one is seen to. The trials' logs are kept outside the repository.

   **How soon.** There is no drain event on either radio, so the engine looks every 100 ms
   (`CustodyAnswers.roundCheckMilliseconds`) while an answer is open or a hand-off waits for its credit, and not at all
   otherwise. At `FeedWindow.ceilingBytesPerSecond`, 65,536, a link writes about 6.5 KiB in 100 ms against a round of
   16,384 bytes, and about 12.8 KiB at twice that, so the look never limits the link. A link fast enough to write a
   round in under 100 ms would need the event.

   **A file comes first.** While the link carries a file to or from that peer, from its queueing to its end, a round
   carries only frames addressed to the peer, with their keys. Everything else waits for the file: on Android an
   answer sharing a link with a photo slowed it enough to trip the blob plane's second-copy deadline. Only a file that
   is moving comes first: once the blob plane counts a stream as stalled by its own rule, no progress for 15 s, the
   other tiers go again, and they wait again if it resumes, so a stream wedged on a live link can't hold them for good.
   Inbound this is `MeshTransport.isFileArrivingLive(from:)`, no chunk for `FeedMeter.stallMilliseconds`. Outbound it
   reads `MeshTransport.isFileFeedStalled`, `FeedMeter`'s stall alone, so a late file that still moves keeps coming
   first; the read leaves the meter's deadline untouched, where reading the feed's state would move it.

   **A cut loses what the link held:** under two rounds, plus a first pick that passed the budget. A link that doesn't
   drain gets nothing more.
3. **The carry ledger** (`CarryLedger`). Per live frame, up to 8 peers believed to hold it (`CustodyLimits.spreadMax`):
   a digest that lists it, the peer it arrived from, and a release credited at the first look after its round that finds
   the link under one round, if its link is still up; one still uncredited 120 s after its round was cut credits
   nothing. A
   digest is the peer's latest word, so a peer leaves the holders of what it no longer lists. Only a proven link feeds it
   (`hasProvenLink`, ADR 2026-11.hpmt): an unproven node id is only a claim. An entry dies with its row, by one feed at
   every custody write, and an id's entry is cleared before the id is written, so a frame that comes back never inherits.
   It lives in memory.
4. **The eviction order at the cap** (`CustodyRules.evictions`). While live rows exceed 1,000, one row goes at a time,
   the first by: its sender's live count, descending (unchanged); its holders, capped at 8, descending; `sentAt`
   ascending; id ascending by its bytes. The frame being written counts the peer it came from among its holders in its
   own write, since that peer holds it whether or not we keep it. Without that, two full stores linked to each other swap
   a frame per exchange for good: a re-served frame arrives held by nobody and outranks every shared row. With it, the
   re-served frame ties with the shared rows and evicts itself by `(sentAt, id)`, as under the old rule, the peer's memo
   marks it not kept, and an offer that draws nothing backs off. What is left is one crossing a frame a lapse, and a
   frame that crosses again at a lapse is sometimes kept. With no holders recorded, the order is the old one exactly.
5. **The not-kept memo** (`CarryLedger`). On a proven link, an id released to a peer is pending, and not released again,
   until a digest at least 20,000 ms after the release judges it. Listed means kept. Lacking means not kept: the id isn't
   released to that peer for 600 s, and the peer leaves its holders. A frame addressed to the peer is never pending or
   marked, so a recipient's own mail is never withheld on a memo's word: it goes whenever the peer's digest lacks it and
   the answer remembers no release of it. The memo goes at link-down. At most 64 peers are
   kept, and a linked peer's is never the one evicted.

   **A release is timed when its round is credited** (contract revisions 21 to 23). A release counts as made at the
   look that credits its round (rule 3), and the judging delay, the 600 s pending lapse and the answer's forgetting
   (rule 2) all run from then: a round cut behind a full link can take longer than 20 s to leave, and a digest that
   crossed it there would judge a frame not yet written. Until the credit the release is remembered for that peer, past
   the answer that cut it: a new answer starts with the peer's uncredited releases, so the frame isn't cut again, and no
   digest forgets it. Once credited or dropped, a release lives in the answer that holds it, and an answer that has
   ended forgets it, which accepts one extra copy on a link full for 120 s rather than keep more state. A credit dropped
   because its link ended leaves nothing pending: the frame is owed again at once. One dropped after 120 s on a live
   link times the release at the drop but makes nothing pending, as Android's `Verdict.Aged` does
   (`ForwardSync.settleHandoffs`): the first digest 20 s after the drop that still lacks the frame owes it again, though
   on the same link `LinkCrossings` still holds it until 10 minutes after its send, so a re-send at the drop plus 20 s
   comes only over a new link. A link that can't say what it holds, a radio whose outbox level answers 0, is credited at
   the next look, so its releases are timed within 100 ms of the cut.
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
- **A fixed pace.** Earlier revisions of this change released a round every 2 s, 8 KiB/s whatever the link could
  carry, so a cut lost about one round. The maintainer ruled on 2026-11-20 that custody must not cap how much or how
  fast linked phones sync, and the pace went: rounds now go as the link drains, and the round's size, not a clock, is
  what bounds a cut.
- **Making the sender, group or room trims read the ledger.** They stay newest-N by `(sentAt, id)`: every shipped build
  trims them that way, and the flood bound rests on the sender trim (ADR 2026-10.9e7g).

**Consequences / limits:**

- **Stores at the cap differ for good,** and their digests never match. The memo and the back-off bound what that costs:
  a frame the peer declined crosses once per 600 s or per link, and an idle pair's digests reach one per 10 minutes.
- **A mixed fleet differs at the cap.** An Android build before this change still sends the whole difference and
  re-offers every 60 s. Our memo and rounds bound what goes back.
- **Holders can be faked.** Digests are unsigned and proven identities are still free (#22), so a peer can raise a
  frame's holder count. The sender's count comes first, so this picks which row a largest bucket loses, never how many
  or from which smaller bucket. A full carrier can be made to drop a chosen frame of a largest bucket, its newest
  included, where the old rule always took the oldest. A fake holder needs a proven link, so it can't borrow an honest
  node's id.
- **What eviction reads, a peer can read back.** Holder counts show little: whether this phone saw another carrier of a
  frame, which is close to what holding the frame already shows.
- **A build without the link proof gets no memo and adds no holder.** It is answered in rounds, and `LinkCrossings`
  still keeps a frame from crossing one link twice in 10 minutes while it remembers the frame.
- **That duplicate skip is a bounded memory, and a busy link outruns it.** It remembers 1,024 writes a link, which a
  link writing 8 KiB/s makes in about 80 s. A frame the skip has forgotten can cross again at the next digest that
  still lacks it. The judging delay and the rounds are the bound that always holds. Here a round asks the skip when it is cut, so a frame the
  skip remembers is never released, pending or marked; Android's link drops such a frame after the round released it,
  so there it is pending and then marked. The contract leaves each skip where it is.
- **A frame addressed to the peer that its digest keeps lacking is released again at each digest,** once the judging
  delay has passed since its last release. No memo holds it. The judging delay bounds it, and on Bluetooth the link's own
  duplicate skip holds it to one crossing in 10 minutes while that skip still remembers it.
- **A full pair's offers often don't reach the longest gap.** After an exchange a node's offers to its peer come 60,
  180, 420 and 900 s later. The peer's marks from that exchange lapse inside the 480 s gap, so its answer to the offer
  at 900 s carries those frames once more, and the node's cap keeps some or none as its store then stands. A kept frame
  returns the interval to 60 s, and it climbs again. Both labs saw that in many of their schedules, about every 15
  minutes, with a handful of frames kept each time and no frame crossing twice inside a lapse. This port's
  `LinkPipeCustodyFullStoresTests`, two stores at a 60-row cap over 100 DMs on an 8 KiB/s pipe with rounds on drain, saw
  it in all 6 seeds, with keeps at 959 s and every 960 s or so after, and 1 to 8 frames kept at each lapse; under the
  earlier 2 s pace it was 3 seeds of 6. An offer that draws a kept frame was worth making,
  so the back-off doesn't change. The cost is a few more digests than a settled pair sends, and never more than the one
  a minute every pair sent before.
- **One keep at a lapse can bring another at the next offer.** The keep evicts a row the two shared, the next digest
  lacks that row, and the peer serves it for the first time, so no memo holds it. It is kept in turn when a credit has
  meanwhile raised an older row's spread (above). This port's lab saw it in 2 seeds of 6, with a 60-row cap: one lapse
  held the interval at 60 s for an offer or two. The memo still holds each row to one crossing a lapse.
- **An answer to one peer shares the radio with a file to another.** "A file comes first" is per peer. An answer to P
  runs at P's link rate while a photo streams to Q on the same radio, and may slow it enough to trip Q's second-copy
  deadline. That is as it was before this change, when the whole difference went at once, and it is unmeasured. A rule
  for the whole radio would pause custody whenever anyone nearby sends a photo, so none is made; a device trial is owed.
- **A peer's own mail can still slow its file.** Tier 2 goes while a file streams, and the link writes it between the
  file's chunks. If an answer opens after the file's first ETA was measured and holds a great deal of mail for that
  peer (about 100 KB on a Coded link, a few times that on 1M), the file can overrun the blob plane's deadline, and the
  holder then serves a parked ask a second copy. The maintainer chose that the recipient's own mail keeps going, so
  this stands. It is constructed, not measured; a device trial is owed.
- **A frame released without its sender's key can arrive late.** When we hold no key to send ahead, the peer parks
  the frame outside custody, its next digest lacks it, and the memo marks it not kept for 10 minutes. If the key
  reaches the peer from elsewhere after its park lost the frame, we serve it only after the lapse. It is bounded and
  never lost, and a frame addressed to the peer is exempt.
- **A restart empties the ledger,** and eviction orders by `(sentAt, id)` until digests refill it. Rosters are read again
  at start.
- **A credit can run ahead of the write.** A release is credited by the clock while the link may still hold it unwritten,
  which overstates a holder count by a frame or a round, and only at the cap.
- **A credit counts a frame the peer didn't keep.** A full peer can evict a frame by its own write as it arrives. The
  hand-off is credited all the same, and the peer stays among the frame's holders until a digest from it that can
  judge the frame lacks it, on this link or a later one. Here a link-down drops the peer's memo and keeps its holder
  entries, so the first digest over a later proven link that lacks the frame removes it. Until then the frame ties on
  spread with rows the two really share, and a write at the cap can evict it though no one else holds it. Hand-offs
  are meant to count, and the peer's own order had ranked the frame last, so the rule stands. Crediting a hand-off to a
  full peer only once its digest lists the frame is left for later.
- **Two carriers serve one newcomer the same first rounds,** because the tiers order alike everywhere. The overlap is
  about a round per extra carrier, and the receiver drops the repeats.
- **A newcomer below the cap still converges,** now in 16 KiB rounds inside one answer, where it took a digest per
  slice: 1,000 frames of about 600 bytes take as long as the link takes to write 600 KB. A convergence check by exact
  sets, such as `interop.py`'s `custody-converges` and the soak's parity check, holds only while the union of the two
  stores stays under the cap.
- **A paced file feed never stalls while the radio holds its record unreported** (knit/knit-ios#57, which predates
  this change). While that gap stands, a paced feed to a reader that has stopped never counts as stalled, so "a file
  comes first" keeps holding the other tiers for that peer until the link goes. Android ends the same wait on its own
  clock (`FramedLink.pauseFor`).
- **Trials that flood wait for an allow-only switch** (knit/knit-ios#58). knit-peer can't yet refuse every link but its
  target, and a phone in range can dial it, so no trial floods, or sends frames a stranger's phone would have to drop,
  until knit-peer has one. A trial that only links knit-peer and a named lab device may refuse the known phones one by
  one and check its links first.
- **The trap:** reading a contact, a sighting or the block list into rule 4 to keep a friend's mail. See "What we chose
  against".
- **Kept true by:**
  - `CustodyVectorTests`, knit-next's 46 steps over both stores; the first 33 are unchanged from before;
  - `CustodySpreadTests` (both stores), for the order key by key, the trims that never read the ledger and the old order
    with no holders;
  - `CustodySyncTierTests` and `CustodySyncRoundTests`, for the tiers, the stop that never skips and the rows a round
    loads;
  - `MeshEngineCustodyAnswerTests`, for rounds on drain, the endings, the memo, the proven-link gate, and an answer held
    open for hours whose sets stay within the cap;
  - `CustodyCarryConstantsTests`, for every constant, beside `CarryLedgerHolderTests`, `CarryLedgerMemoTests`,
    `CustodyAnswersTests` and `ReofferBackoffTests` (the contract's worked cases);
  - `MeshEngineCustodyFileFirstTests`, for a file first and endings first;
  - `LinkQueuedFrameBytesTests`, `UnwrittenFileRecordsTests` and `SocketBacklogTests`, for what "unwritten" counts;
  - `LinkPipeCustodyCarryTests`, two engines, for rounds as the pipe drains, never stacking past two rounds, a cut mid-answer that credits nothing, two full
    stores that serve each other's mail first and then stop swapping, and the back-off;
  - `LinkPipeCustodyFullStoresTests`, two full stores linked for 50 minutes over several schedules: no frame crosses
    twice inside a lapse, no later lapse marks more than the first, and the re-offer follows the back-off's ladder,
    back to 60 s only after a kept frame;
  - `EngineLabCustodyCrossingsTests`, a lost DM for the peer that every digest lacks crosses once in 10 minutes.
