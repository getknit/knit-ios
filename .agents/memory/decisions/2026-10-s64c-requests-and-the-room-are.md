---
id: "2026-10.s64c"
slug: requests-and-the-room-are
title: "requests and the room are trimmed as Android trims them, and a trim never comes back"
date: 2026-10-27
topics: [mesh, storage, security]
---

# ADR 2026-10.s64c — requests and the room are trimmed as Android trims them, and a trim never comes back

Status: Accepted (2026-10-27)

**Context:** knit-next's malicious-fork review of 2026-10-26 (`eccabcd72`, H7) found that a stranger's requests are kept
without bound. This port kept every message until the user deleted it: no request thread, room post or peer row was
ever trimmed (knit-ios #21, checked against `b2a495e`). ADR 2026-10.vzem stopped request photos from being fetched,
but every identity a fork mints could still leave rows behind for good. Android trims both. `sweepRetention`
(`MessageRepository.kt:354-414` at the pin `e63f15f4`, the same at `4408e0fca`) runs at start and every 10 minutes.

The design pass found two ways a port of it would go wrong:

- **A bare delete comes back.** Android deletes the rows and nothing else. A count trim can remove a row whose frame a
  carrier still holds, inside custody's 24 h. Every gate that should refuse that frame again reads
  `messages.contains`, which is true only for a row or a `deleted_messages` id. So once the SeenSet window has passed, a
  re-serve or a start's replay opens the frame again. It is stored as new and announced as a request, and the next sweep
  trims it again.
- **A full tombstone names the photo.** A `deleted_messages` row keeps its photo's hash, and `blobsTheRowsName()` names
  that photo while custody carries the frame (ADR 2026-10.u7cq). That would take a stranger's trimmed photo out of the
  echo budget (ADR 2026-10.7kxj), so a fork that keeps more than 100 threads would get fresh echo room at every sweep.

**Decision:** Android's rules, in Android's order, plus three of this port's own (`MessageRetention`,
`MeshEngine.sweepRetention`).

1. **The room** (`nearby` alone; this build has no Meshtastic or commons rooms), in this order:
   1. Posts older than 30 days go.
   2. Each stranger keeps their newest 200.
   3. Past 2,000 posts, strangers' oldest go first.
   4. Then the oldest overall, down to 2,000.

   A known sender is exempt from the per-stranger cap: us, a peer whose DM thread is accepted or written in, or a
   verified peer (`knownSenders`).
2. **Request threads.** These are threads that are neither accepted, verified, written in, nor a group a known peer
   posted in (`conversationsNamed`, blocks not subtracted, so retention never trims a thread the fetch treats as
   accepted). For each one:
   1. A thread quiet for 7 days goes whole.
   2. Otherwise it keeps its newest 50.
   3. Past 100 such threads, the least recently active go whole.

   Rows are ordered by `sentAt`, then id by its bytes.
3. **A trimmed row that could still come back is tombstoned, by id alone.**
   - **When:** while `sentAt` is within two of custody's TTLs (6 h for the room, 24 h otherwise) plus the 5 minutes of
     future skew. One TTL covers our own clock; the second covers a carrier whose clock lags ours by up to a TTL and still
     holds the frame after our custody dropped it. An older row gets no tombstone.
   - **How long:** until the later of `sentAt` plus two TTLs and now plus one, plus the skew. So it outlives a lagging
     carrier's copy whenever the trim runs, and a room tombstone lives about 12 h at most.
   - **What it holds:** the tombstone's photo hash is NULL, so it names no photo and counts against no budget.
   - **Status lines** get none.
   - **An existing delete's tombstone** keeps its photo, and an upsert keeps the later expiry.
4. **In a group, the count trims keep each sender's newest anchor row** (`.message`, `.groupRenamed` or
   `.memberRejoined`). Those rows are what `GroupRoster.actedAfter` and `outlives` read when a start replays a leave
   from custody. Without them, a replayed leave that lost its first verdict to a failed unit would depart a member who
   has since posted. The 7-day whole-thread delete may still remove them: every row in a thread that quiet is older than
   any leave custody still holds.
5. **Where it runs, and how.**
   - **When:** on the 600 s sweep, and through it at start, before the replays.
   - **Reads:** one store unit reads acquaintances, protection and rows, so a failed read trims nothing.
   - **Writes:** a separate write trims, and a failed write removes nothing.
   - **Afterwards:** wants for the trimmed photos are forgotten at once (`release`, `removingUnnamed: false`), and the
     bytes go to the tick sweep's 30-minute guard. The app hears `.trimmed(conversations:)` and recounts unread rows and
     the badge.
   - **Tombstones:** `pruneDeleted` now also runs on every pass, so a flood's tombstones expire without waiting for a
     start.

Custody, the carry gate, the digest and `PendingInbound` never read retention, so every node's digest stays what it
was. A trimmed frame is still carried and relayed.

**Consequences / limits:**

- **People lose messages they could see.** A request quiet for a week, a request's 51st message, and room posts past 30
  days or past the counts disappear without a prompt, as on Android. Accepted, verified and written-in threads, and
  groups a known peer posted in, are never trimmed.
- **A reinstall loses both rows and tombstones.** Custody re-serves what it holds, and those rows come back as
  requests until the next pass trims them again, as on Android. A contact's DM thread, a request again after the
  reinstall (ADR 2026-10.vzem), is trimmed to its newest 50 at the next pass, and an accept after that does not bring
  the rest back. A thread we wrote in is spared once our own frames come back.
- **A carrier lagging by more than a TTL** can still bring a trimmed row back, past its tombstone. It is announced once
  more and trimmed at the next pass.
- **Reactions on trimmed rows** are left to the orphan sweep in the same pass, as Android leaves them.
- **Not ported:** Kotlin's `peers.sweepCap`, the 2,000-peer cap. A fork can still mint peer rows (knit-ios #22).
- **A trimmed room photo's standing want is forgotten without a `blobcancel`,** as a user's delete does. The holder may
  stream one copy that is then dropped.
- **Cost:** a pass reads about 7,000 light rows at the caps (2,000 room rows plus 100 × 50 request rows), and a pass at
  steady state writes nothing.
- **When knit-next changes its retention,** read its numbers against these.
- **Guards:** `MessageRetentionTests` (each rule, its order, the anchors and the tombstone window);
  `RetentionStoreTests` over both stores; `MeshEngineRetentionTests` (what is protected, a failing read or write);
  `MeshEngineRetentionReserveTests`, two engines (55 v1 and 55 ratchet DMs re-served 11 minutes after the trim, then a
  restart, with nothing back and `liveIds` equal); `MeshEngineRetentionGroupTests` (the leave replay with an anchor
  kept); and `UnreadTests` for the badge.
