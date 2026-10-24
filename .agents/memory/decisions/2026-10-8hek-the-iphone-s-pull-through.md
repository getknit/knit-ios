---
id: "2026-10.8hek"
slug: the-iphone-s-pull-through
title: "The iPhone's pull-through carries a hop budget and a deadline"
date: 2026-10-24
topics: [mesh, blobs, interop, wire]
---

# ADR 2026-10.8hek — The iPhone's pull-through carries a hop budget and a deadline

Status: Accepted (2026-10-24).

- **Amends** ADR 2026-10.m9uq (asking: the pull-through and the backoff) and ADR 2026-10.ym9y (answering: a
  neighbour that lacks a blob no longer always wants it).
- **Mirrors** knit-next ADR 2026-10.2drc (`385bfba0`) and its amendment of 2026-10-19 (`1ce131fd`). Both are past the
  pin `5f521cb9` and were read on knit-next `main` at `eac3debc`.

**Context:** knit-next #195.

- **The stranded card.** The Pixel 9 held a DM card, `92134a58…`, whose bytes never arrived. Each neighbour asked to
  pull it through made a want of its own, an *echo*, and the echoes asked each other back.
- **Why it never ended.** A pull ask refreshed the want's clock, so no want aged out. The backoff stopped at 6 min.
- **Android's fix.** It now puts the difference between a root's ask and an echo's on the wire: a hop budget and a
  deadline.

The ADR names this port as the half that keeps a mixed fleet looping. The iPhone asked with no budget, refreshed its
want on any ask and echoed without bound. An Android want that only fetches and an iPhone want therefore kept each
other alive with no root. Android can bound only its own half: an ask with no field never refreshes a want there.

**Decision:** the iPhone carries and honours the budget and the deadline as Android does. It also ports the two
backoffs that came with them.

- **The wire.** `BlobRequestContent` gains two fields after `offset`, both omitted when nil:
  - `pull`: an int32 on the wire, kept as a 64-bit `Int` once decoded;
  - `until`: epoch ms on the frame's clock.

  A plain ask's bytes do not move. Every ask a step sends carries its want's budget, 0 included, and its deadline
  when it has one. `blobReqContentPull` and `blobReqContentPullSpent` are typed fixtures now. `blobReqContentFastOnly`
  stays decode-only (knit-ios #8).
- **The budget.** A want of our own has `pullBudget`, 3. Asked with `n` for a blob it lacks, the iPhone wants it with
  `min(n, 3) − 1`, and an absent field reads as 1. When that comes out below 0 (asked with 0 or less), it serves a
  held blob and makes no want (`blob no-echo … (fetch only)`). A want with a budget of 1 or more may pull through. One
  at 0 only queries and fetches.
- **The refresh rule** (`noteAsker`). This is the change that ends the loop.
  - Only a want of our own refreshes the want's clock unconditionally.
  - A neighbour's ask refreshes it only when the ask carries at least the want's budget.
  - An ask that carries more raises the budget and takes the ask's deadline.
  - An ask with no field never refreshes.
- **The deadline** (`PullThroughGate`).
  - **Where it comes from.** It is folded from the rows naming the hash: when every row is a DM's, it is the latest
    `sentAt` plus 24 h, the DM's custody window. Otherwise there is none. The re-arm and a delivery re-derive it, and
    an avatar's want keeps the one it has.
  - **What it stops.** Past the deadline nobody pulls the blob through or makes an echo of it (`blob no-pull … (past
    its deadline)`, `blob no-echo … (past its deadline)`). A holder still serves it.
  - **Its clock.** The exchange keeps its times on the monotonic clock, and only the deadline is compared with the
    wall clock, as custody's TTL is.
- **Newcomers.** A neighbour that linked in this cycle and lacks the blob is asked to pull at once, once per link-up,
  by any want that may pull.
- **Backoffs.**
  - **The blind round.** A cycle whose blind asks found nothing counts as dead from the third lead-less cycle on.
  - **The long backoff.** A dead streak at the 6 min ceiling keeps doubling, to about 3.2 h, once it is a day old or
    its want's deadline has passed.

  The deadline is the trigger an iPhone needs. iOS ends Knit often, and the streak lives in memory, so it would rarely
  reach a day.
- **Logs and counts.**
  - Every `blob ask`, `blob fetch` and `blob pull` line ends `[pull n]`, or `[pull n, until <ms>]`.
  - `blob no-pull` and `blob no-echo` are Android's words.
  - A declined echo's `mesh blobreq … from …:` line says `not held; no echo (<why>)`.
  - `status.blobs` gains `echoesDeclined` and `pullsWithheld`.

**Where the port differs from the Kotlin:**

- **`pull = Int32.min` is a fetch only here.** Kotlin's `Int` arithmetic wraps `minOf(pull, 3) − 1` to `Int.MAX_VALUE`
  and makes an echo with an unbounded budget (knit-next #212).
- **A failed read keeps the deadline.** The SQL stores here answer an empty list on an error, which would read as "no
  deadline". So a delivery folds its own row into the rows it reads, and the re-arm leaves the deadline as it was for a
  hash with no rows read.
- **No twin here:** the carrier's custody want, the user's tap and the fast-only fetch. This port pulls no carried
  frame's photo (ADR 2026-10.ym9y) and has not ported knit-next ADR 2026-10.js2p (knit-ios #8).

**Alternatives:**

- **Only what the ADR says iOS owes:** the wire, the budget, the refresh rule and the deadline. That left dead wants
  at the 6 min ceiling. On an iPhone, which restarts more than daily, that is the Pixel 9 symptom the amendment fixed.
- **A capability bit.** It is not needed, as on Android. A build that predates the fields reads as a fetch only.

**Consequences / limits:**

- **Reach.** A holder five or more links from a root that nothing else carries for is not found by pulling.
- **A DM's far end past a day.** Nobody pulls it through. It is reached again once the two ends link directly, or once
  a neighbour says HAVE.
- **A want outlives its root** by a TTL per budget level, plus the wait for the sweep that removes it: within
  (3 + 1) × (30 min + the 10 min sweep), about 2 h 40 min on a phone.
- **Latency once a pair is a day dead, or past its deadline.** The long cycle can be about 3.2 h. A neighbour that
  links is still queried, and pulled, at once.
- **A blind neighbour,** a build without `CAP_BLOB_HAVE`, is asked at the backed-off pace past the first two lead-less
  cycles.
- **A copy can be swept while it streams.** An echo made for an asker that sends no field lives one TTL. A copy for an
  older Android build that takes more than 30 min to stream in can be swept, and is then refused on arrival, as on
  Android.
- **Guards:**
  - `BlobPullBudgetLabTests`: engines linked with `CAP_BLOB_HAVE`. Each ring spends a hop and the third only queries.
    Echoes end within four TTLs of their root's row going, and a pair that keeps relinking cannot keep an echo alive.
    Past its deadline a DM's want pulls nobody;
  - `BlobPullBudgetTests` for the budget, the refresh rule, newcomers and an own want restoring an echo;
  - `BlobLongBackoffTests` for the ramp from a day or from the deadline, on two clocks with different bases;
  - `BlobRoundTests.aBlindRoundKeepsItsPaceForTwoCyclesThenBacksOff` and `BlobPullThroughTests` for the pull and its
    withholding;
  - `PullThroughGateTests` and `MeshEngineBlobDeadlineTests` for the deadline at the re-arm and at a delivery,
    including a failed read;
  - `MeshEngineBlobTests` and `MeshEngineBlobParkTests` for the ask's fields, the declined echo, and an unparked echo
    keeping its budget;
  - `GoldenVectorTests` and `BlobHaveContentTests` for the two vectors and the field's bounds.
- **The device oracle:**
  - the iPhone's `mesh blob ask|fetch|pull … [pull n, until <ms>]`, `blob no-echo` and `blob no-pull` lines;
  - `status.blobs.echoesDeclined` and `pullsWithheld`;
  - the Pixels' `blob no-echo … for <iPhone>` and `blob cycle … next if dead in`.

  A photo nobody holds is wanted by no phone about 2 h 40 min after its root stops. A live photo still arrives through
  a one-hop pull.
