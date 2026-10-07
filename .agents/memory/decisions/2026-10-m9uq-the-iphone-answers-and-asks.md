---
id: "2026-10.m9uq"
slug: the-iphone-answers-and-asks
title: "The iPhone answers and asks blob holder queries"
date: 2026-10-05
topics: [mesh, blobs, interop, wire]
---

# ADR 2026-10.m9uq — The iPhone answers and asks blob holder queries

Status: Accepted (2026-10-05). Amends ADR 2026-10.ym9y (asking) and ADR 2026-09.khjj (two more upkeep types).
Mirrors knit-next ADRs 2026-10.f7gg (`1c82da2d`) and 2026-10.6e5t (`403cd861`), at the pin `5f521cb9`.

**Context:** a node used to ask every neighbour for a blob at once, and again every 60 s, so one asker paid for every
holder in range. Android's trial for knit-next ADR 2026-10.f7gg logged six 70-second Bluetooth copies of one picture
where three would do; the lab iPhone took two of them. Android now asks one neighbour at a time:

- **The query.** It sends each neighbour whose HELLO carries `CAP_BLOB_HAVE` (`0x2000`) an unsigned `blobhave` naming
  up to 32 hashes. The answer, a `blobhas`, gives each a state (NONE, HAVE with a size, SENDING, FETCHING), the
  responder's load and the query's id.
- **The ask.** Once every answer is in, or 5 s on, it asks the best holder alone, confirms one that brings nothing
  within 5 s, and falls back to the next. A neighbour that cannot answer gets f7gg's round: the author, then the hop
  the frame came from, then everyone once a 5 s grace is up. When nobody holds it, a neighbour that lacks it is asked
  to pull it through, and a dead blob's cycles back off from 45 s to 6 min.

The iPhone refused a `blobhave` as unsigned, and asked for its sender's key when that was not pinned, so Android asked
it blind.

**Decision:** the iPhone answers in every build, and asks as Android does.

- **Answering** (`MeshEngine+BlobQueries`). A query is taken only from the link's own peer, with `relay = false`. The
  first 32 hashes are answered, within a budget of 16 answers a burst and one a second per neighbour. Each is read in
  the order the bytes move: SENDING when a copy is on the link or served inside the memo (peeked at, never stamped),
  HAVE with its size when a `blobreq` would be served (the store's index, never the bytes), FETCHING when the file is
  streaming in or landing, NONE otherwise. Android also reads its store's screening; this store takes a file in one
  step on the actor. A query serves, wants and stamps nothing.
- **The bit.** Every HELLO claims `CAP_BLOB_HAVE`, as it claims `CAP_DOORBELL`: Android reads it from the link alone,
  so `Capabilities.local`, the signed profile and the emitted vectors keep `0xF`. Both types are doorbell upkeep.
- **Asking** (`BlobExchange`). It ports Android's cycles, constants and log words. One radio collapses its tiers to
  whether a holder is streaming us a file, then its load, then its id; there is no Wi-Fi Aware link to raise and no
  Coded PHY to see. Timers are engine deadlines (ADR 2026-09.gq84), and wants due within 1 s step together, so their
  queries share a frame. A chat's photo is asked of its author, then of the hop it came from, and a re-armed one of the
  sender of the earliest message naming it (`MessageStore.attachmentSenders`).
- **The gate.** `MeshConfiguration.queriesBlobHolders` is on in a debug build and knit-peer, and off in a release one
  until an iPhone device trial, as Android's `BuildConfig.BLOB_QUERY` is. Off, every neighbour gets f7gg's round, which
  ships in release.
- **The landing window** (knit-next #138). A radio read runs all its records before the engine sees one, so a frame
  ahead of a FILE_END found its blob neither arriving nor held. A whole file now stays arriving until the engine takes
  it (`MeshTransport.fileTaken`).
- **The Kotlin's quirks are ported as written,** so both phones log the same steps: the second confirm's answer is
  never read (`BlobExchange.kt:385`), an answer naming no query is still taken, one step's asks share a request id,
  and FETCHING rechecks have no cap. The first is a knit-next fix this port mirrors when it lands.

Two alternatives were set aside. Putting the bit in `Capabilities.local`, where Android's own sits, moves the signed
profile and the emitted vectors for a reader that never looks there. Answering alone, the least knit-next's ADR asks,
leaves the iPhone paying a copy per holder in range whenever it asks.

**Consequences / limits:**

- **One round trip** before a capable neighbour is asked, up to 5 s on a busy link. A miss in the blind round costs a
  5 s grace before everyone is asked.
- **Not covered:**
  - resuming a cut transfer (knit-next ADR 2026-10.wtyc, knit-ios #2);
  - knit-next ADR 2026-10.nxfb's holder half, which keeps a fed file in flight while its link feeds that peer more;
  - the 4 KiB/s pace budget (knit-next ADR 2026-10.8jwn).

  This port still feeds 28 KiB/s a link, so an Android asker on an older build can be served twice across the
  stack's buffer (`.agents/memory/roadmap.md`).
- **Guards:**
  - `BlobExchangeTests`, `BlobRoundTests`, `BlobHolderQueryTests` and `BlobPullThroughTests` for the books, f7gg's
    round, the query's tiers, confirms and fallbacks, the pull-through and the backoff;
  - `MeshEngineBlobQueryTests` and `MeshEngineBlobTests` for both ends through the engine;
  - `LinkFileTests` and `FileIntakeTests` for the landing window and a peer streaming to us;
  - `GoldenVectorTests` and `BlobHaveContentTests` for the three vectors and an unknown state;
  - `LinkTests.theBlobHaveBitIsPinnedAndKeptOutOfWhatWeSign`, `LinkDoorbellTests` and `PeerNodeTests` for `status.blobs`.
- **The device oracle:** the iPhone's `mesh blob query`, `blob answer`, `blob fetch`, `blob has` and `blob ask` lines
  against the Android phones' `blob …` lines in logcat. Each (asker, hash) owes one `file ATTACHMENT/<hash>`, on the
  holder its `blob fetch` named.

**Amended 2026-10-06, for knit-next #140 (its ADR 2026-10.6e5t's amendment of that date):** an ask to a holder now
stands until its link goes, its floor passes or the holder says it no longer holds the blob. On 2026-10-06 the lab
Pixel 3 took five photos twice each. Its own outgoing frames were 13 to 44 s behind, so every answer missed the wait and
the author was asked blind. The author's HAVE landed inside that ask's grace, but its header did not. When the grace
ended, a second holder's late HAVE was asked, and nothing on the wire withdraws the first ask. The iPhone's asker did the
same: `BlobAskStandsTests` holds the trace. Mirrored from knit-next's `fix/blob-ask-race` before it merges, with its
author's word that the design is settled. No wire change.

- **A blind first pick that said it holds the blob is confirmed, not widened past.** Its fetch is re-tiered as a
  holder's, and the round counts as widened, so a fallback asks the next holder.
- **Silence holds; only a no moves on.** A silent confirm, or a holder still sending after two confirms, is held to its
  floor: our last ask plus the 45 s serve memo (`blob hold <h8>… on <node> (<why>), floor <ms> ms`). At the floor the
  next holder is asked (`blob fallback … (floor) → next`). A NONE, FETCHING or unknown answer still moves on at once.
  A stream from the held holder restarts what is left of the hold from the stream's end, as any grace does, since our
  copy may sit behind it (knit-next ADR 2026-10.nxfb), so a hold can outlast the floor it logged.
- **`askHolder` never asks past a holder asked inside its floor** whose answer is older than the ask.
- **A link that goes steps its blobs at once** (`MeshEngine.linkDown`, `BlobExchange.fetches(on:)`), so the next
  holder is asked without waiting for a timer or the tick.
- **Waits sized by the round trip.** Each matched answer's round trip is kept per neighbour (`AnswerRoundTrips`) and
  forgotten when it links again. The wait for its answers, and for a confirm's, is that round trip plus 5 s; an ask's
  grace gains the round trip. Both stop at 30 s (`queryWaitCapMilliseconds`).

The cost, as on Android: a holder whose ask really died on a link that stays up keeps the blob waiting up to 45 s from
the ask, not about 15 s. The `BlobExchange.kt:385` quirk stays: the second confirm's answer is still never read, and the
holder is now held rather than passed over. Guards: `BlobAskStandsTests`, the hold in `BlobHolderQueryTests`, and
`MeshEngineBlobQueryTests.anAskWhoseLinkGoesAsksTheNextHolderAtOnce`.

**Amended 2026-10-07, for knit-next ADR 2026-10.nsr7 (ADR 2026-10.ds45):** a SENDING answer may carry `eta`, and a hold
then runs to the later of the ask's floor and that promise plus 30 s, the promise taken as at most 15 min. A holder we
only waited on now holds us when it promises. Guard: `BlobAskStandsTests`' `eta` cases.
