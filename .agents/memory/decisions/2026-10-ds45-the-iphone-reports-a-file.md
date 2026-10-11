---
id: "2026-10.ds45"
slug: the-iphone-reports-a-file
title: "The iPhone reports a file's progress to its sender, and holds on a SENDING answer's eta"
date: 2026-10-07
topics: [mesh, blobs, interop, wire]
---

# ADR 2026-10.ds45 — The iPhone reports a file's progress to its sender, and holds on a SENDING answer's eta

Status: Accepted (2026-10-07). Amends ADR 2026-10.m9uq (the hold), ADR 2026-10.h6zz (what a receiver sends back)
and ADR 2026-09.khjj (a sixth upkeep type). Mirrors the receiving and asking halves of knit-next ADR 2026-10.nsr7,
ahead of the pin: ported from its uncommitted work on knit-next's `main` above `3890f16b` on 2026-10-07, and checked
the same day against its commit, `79f38d3d`.

**Context:** knit-next ADR 2026-10.nsr7 has a file's receiver tell its sender how much of the file it holds. Every 2 s
of chunks it sends an unsigned, point-to-point `blobprog` (`BlobProgressContent`: the hash, the bytes held, and the ms
since the header by the receiver's own clock). An Android sender cannot see its own drain, because the Bluetooth
stack's queue sits between its writes and the air. With the reports, a holder that parks a second ask behind a copy it
is feeding waits for that feed as long as it really takes: until it ends, stalls for 15 s, or passes a deadline set
from its first measured rate. The old 30 s bound is gone. A SENDING answer to a parked asker gains `eta`, the ms until
the asker's copy should land, and the asker holds on that holder until then plus 30 s, rather than ask another.

This port took a `blobprog` for a signed frame. From a pinned sender it was dropped as unsigned, and from an unpinned
one it was dropped for want of a key, and the key was asked for. Android therefore sends none to a link whose HELLO
carries `CAP_DOORBELL`, which misses knit-peer's `android` profile. And with no reports from the iPhone, Android judged
a feed to it by its pace and its writes alone: in rep 65 on 2026-10-06 that read a 410 KB photo to the iPhone as about
100 s from its end, and the holder fed three more copies beside it.

**Decision:** the iPhone takes the frame, sends it as a receiver, and honours `eta` as an asker. It does not measure
what it feeds.

- **The wire.** `FrameType.blobProgress` (`blobprog`) joins `isUnsignedPointToPoint`, so it is never verified,
  carried, flooded or the cause of a key request. `BlobProgressContent` has three required fields in Android's order.
  `BlobHasItem.eta` follows `held` and is omitted when `nil`. The two new vectors, `blobProgressContent` and
  `blobHasContentSendingEta`, are synced from knit-next's working tree.
- **Sending a report** (`LinkManager.fileChunk`, `MeshEngine.fileProgress`). The link stamps each FILE_HEADER. A
  chunk of a kept file that lands 2 s or more after the header or the last report emits `.fileProgress`, with the
  bytes held and the ms since the header on the monotonic clock. A skipped file is never reported, and a stall sends
  nothing, which is how the sender sees one. This port never resumes a cut transfer, so `held` is the bytes received.
  The engine sends the report only to a neighbour whose HELLO carries `CAP_BLOB_HAVE` and not `CAP_DOORBELL`, the gate
  Android uses: an iPhone holder measures nothing, and an iPhone on an older build would count every report dropped.
- **Taking a report** (`MeshEngine.handleBlobProgress`). It is taken only from the link's own peer with
  `relay = false`, as a holder query is, and only when its counts are not negative and its hash is at most 128
  characters. It is counted (`progressTaken`) and does nothing else. This port feeds each link at its own 28 KiB/s and
  parks no asks (knit-next ADRs 2026-10.8jwn and 2026-10.g24x are not mirrored), so a report has nothing to time.
- **The asker's hold** (`BlobExchange.hold`). An answer keeps a SENDING item's `eta` as `etaAt`, the answer's time
  plus the eta, taken as at most 15 min (`holdCapMilliseconds`). A hold runs to the later of the ask's serve-memo floor
  and `etaAt` plus 30 s (`holdSlackMilliseconds`). A holder we only waited on, with no ask of ours on it, now holds us
  too when it promises, as on Android. This port's own SENDING answers carry no `eta`, which nsr7 allows a holder that
  cannot tell.
- **Upkeep.** A `blobprog` never rings a doorbell. It is the sixth upkeep type on both platforms
  (`DoorbellPolicy.UPKEEP`).

What Android gains is the rep 65 case: it takes a report from any link (`BlobExchange.onProgressReport`, with no
gate), so its feeds to an iPhone are measured as soon as both phones run these builds. Its gate on sending reports to
an iPhone can stay. This build would take them quietly, but nothing here reads them until this port meters its own
feeds, so they would cost air for nothing.

The alternative is the holder half too: a meter on our feeds, and parking behind them. Without 8jwn's shared pace
budget this port's feeds take nothing from each other, so there is nothing yet to park behind. It waits with 8jwn on
the roadmap.

**Consequences / limits:**

- **Air:** one `blobprog` of about 120 bytes every 2 s per file arriving from an Android phone.
- **A promise that breaks** costs the asker its `eta` plus 30 s before it asks the next holder, where it used to cost
  the ask's 45 s floor. A holder that lies holds us for up to 15.5 min a round, as nsr7 accepts.
- **An older knit-peer** on the `android` profile counts this build's reports as dropped. Lab only: no iPhone or
  Android build without the type ever gets one from us.
- **Mirrored ahead of the pin,** which is still `5f521cb9`. nsr7 committed as `79f38d3d`; its vectors were synced
  from that commit, and its `PROGRESS_EVERY_MS`, `HOLD_SLACK_MS`, `HOLD_CAP_MS` and `hold` match these
  (`.agents/context/knit-next.md`).
- **Guards:**
  - `GoldenVectorTests` (63 vectors) and `BlobHaveContentTests` for the wire;
  - `LinkFileProgressTests` for the cadence, and `MeshTests.aFileStreamingInIsReportedBackToItsSender` through the actor;
  - `MeshEngineBlobQueryTests`' two progress cases for the gate and for taking a report without a key;
  - `BlobAskStandsTests`' three `eta` cases for the hold and the cap;
  - `LinkDoorbellTests.upkeepGoesOutWithoutRinging` and `PeerNodeTests` for `status.blobs`.

**Amendment (2026-10-07): an asker withdraws its ask (`blobcancel`).** The same day, knit-next's nsr7 gained a fourth
unsigned type, committed with the rest as `79f38d3d`: `blobcancel` (`BlobCancelContent`: the hash), under `CAP_BLOB_HAVE`,
with the vector `blobCancelContent`. Until then nothing could withdraw an ask, so moving on to a second holder risked a
second copy. This port mirrors both ends.

- **The wire.** `FrameType.blobCancel` joins `isUnsignedPointToPoint`, and it is the seventh upkeep type on both
  platforms, so it never rings.
- **The holder** (`MeshEngine.handleBlobCancel`, `LinkManager.cancelQueuedFile`). A withdrawal from the link's own peer
  takes that blob's copy off the link if it is still waiting behind another file, before its header goes. The serve
  memo then forgets it, so a later ask of the peer's own is served. A copy already streaming goes on. Android also
  drops the ask if it parked it, and this port parks none. `cancelsTaken` counts only withdrawals that took a copy off,
  as Android's `blobCancelsTaken` does, but every withdrawal taken is logged, as `blob cancel ← <id> <hash>…` with
  `queued copy dropped` or `nothing queued`, so a device run can tell one that came too late from one that never
  came. Android lifted its gate on sending one to an iPhone on 2026-10-07, uncommitted on knit-next's `main` that day;
  its gate on `blobprog` stays.
- **The asker** (`BlobExchange.over` and `obtained`, `MeshEngine.withdrawAsks`). When a fetch falls back from a holder
  that is still linked, our ask on it is withdrawn: at its floor, when a grace runs out, or after a confirm. Once the
  blob lands, every other neighbour we asked gets one, never the neighbour it came from. When the blob turns up held
  some other way, every neighbour asked gets one. Each ask is withdrawn once (`Want.withdrawnAt`). Withdrawals go where
  reports go (`readsBlobUpkeep`): to a neighbour with `CAP_BLOB_HAVE` and without `CAP_DOORBELL`. They are counted as
  `cancelsSent`. Two asks are never withdrawn, both from knit-next's device rerun the same day:
  - **A blind first ask, at the widening.** Widening adds asks and gives up on nobody, and the first pick, often the
    author, may have the closest copy queued. On Android, a Pixel 8's ask that its author had parked was withdrawn at
    the widening, so when the feed ahead of it was cut it had lost its place and its copy came 28 s late. The first
    pick's ask is withdrawn only at landing, unless it brought the blob.
  - **An ask of a neighbour that said, at or after the ask, that it lacks the blob** (`Answer.receivedAt`). That ask
    was a pull through, and a neighbour that lacks a blob remembers no asker, so there is nothing to withdraw. A dead
    want there sent a cancel every cycle. An answer older than the ask proves nothing, since the ask may have found the
    blob there, and an ask nobody answered, such as a blind one, is still withdrawn at landing.
- **Not mirrored.** Two asker changes knit-next made the same day, neither on the wire, are on the roadmap: leaving a
  neighbour whose other stream to us has more than 30 s left while an idle holder is linked (Android's fifth
  fallback, which withdraws too), and letting go of an ask that found its neighbour lacking the blob. A pushed photo
  withdraws the other asks as it lands here, where Android withdraws them at the blob's next step, the pusher's too.
- **Limits.** A holder that starts our copy before the withdrawal reaches it still sends a second copy, and so does
  one already streaming. An Android build with `CAP_BLOB_HAVE` from before the amendment drops a withdrawal as an
  unsigned frame of a type it does not know, as it drops Android's own. The hold floors are unchanged.
- **Device check (2026-10-07), passed:** the iPhone 12 on this build, with a Pixel 8 and a Pixel 9 on knit-next's
  working tree. The iPhone fed the Pixel 8 a 4 MiB DM file, at about 8 KB/s for 524 s. A photo posted to a group of
  the three queued behind it for the Pixel 8 while the Pixel 9 took its copy in 76 s. Then the Pixel 8 withdrew its
  ask: the iPhone logged `blob withdrawn … before it streamed` and `queued copy dropped`, and `cancelsTaken` went
  to 1. The Pixel 8 took its one copy from the Pixel 9, and none followed from the iPhone after the DM. There was no
  key request and no drop, and the links stayed up. A first run had shown a cancel taken with nothing queued, and the
  Pixel 8's never-reasked NONE answerer, which knit-next then fixed.
- **Guards:**
  - `GoldenVectorTests` (64 vectors) and `BlobHaveContentTests` for the wire;
  - `LinkFileCancelTests` for the link;
  - `MeshEngineBlobCancelTests`' four cases for both ends, the gate and the widening;
  - `BlobAskStandsTests`' floor and link-gone cases for the fallback, and for withdrawing once;
  - `BlobPullThroughTests.aPullHasNothingToWithdrawOnceItsNeighbourSaysAtOrAfterItThatItLacksTheBlob`;
  - `LinkDoorbellTests.upkeepGoesOutWithoutRinging` and `PeerNodeTests` for `status.blobs`.

**Amended 2026-10-09 by ADR 2026-10.xwjc:** the iPhone reports at the window's cadence: on every chunk that brings
2 KiB, at least every 500 ms, and once more after chunks no report carried. Every two seconds is now the
`feedWindow`-off case. It now measures what it feeds: a report it takes clocks the window of the file streaming to
that peer. So `blobprog` and `blobcancel` go to an iPhone too, to every neighbour whose HELLO carries `CAP_BLOB_HAVE`.
Android's gate on sending reports to an iPhone is the one left, and the maintainer lifts it in knit-next.

**Amendment (2026-10-10): the iPhone reports a skipped file, leaves a stream that won't end soon, and parks a second
ask.** The interop audit of 2026-10-09 (`orders/interop-audit/findings.md`, knit-next `8dc60836` against this repo's
`9ac4cdf`) found three gaps on this side. This amendment ports the committed Kotlin for each, rule for rule. No wire
byte moves and no vector changes.

- **A skipped file is reported** (AND-7, IOS-3). This reverses "a skipped file is never reported" above. Android
  keeps every file whose header decodes and reports it (`FileIntake.kt:124-131`, `RxReports.kt:48-70`). So when the
  iPhone skipped an attachment nobody wanted, an Android sender's window heard nothing: after 3 s it fell back to the
  paced 4 KiB/s (`FeedWindow.kt:367`, `:474`) and streamed the whole file into nothing. `FileIntake` now keeps a
  skipped file's key, its declared size and a count (`FileIntake.reading`), and the link reports it at the receiver's
  cadence: on every chunk that brings 2 KiB, at least every 500 ms, and once more after chunks no report carried. The
  iPhone still keeps none of the bytes.
  - A file this port drops past one of its own limits, the photo cap or the shared buffer, is read on the same way,
    since Android would have kept it.
  - A file that passes Android's 8 MiB and 64 KiB ceiling goes silent, as Android's `abort` does
    (`FileIntake.kt:308-318`). A stream cut off by another header stops reporting there, and the new file's count
    starts from its own header.
  - A header with a malformed key is still not reported. Android reads its chunks and rejects it at its END, but a
    `blobprog` names a hash, and this one has none.
- **The asker leaves a stream that won't end soon** (IOS-1; knit-next `79f38d3d` and `09f70b3e`,
  `BlobExchange.kt:371-528`). While the holder a fetch waits on streamed us another file, the fetch polled every 2 s
  for as long as the stream ran, and knit-next's trace of that shape stalled for 12 min. Three rules now let it go.
  - An ask whose neighbour answered NONE at or after it is dropped, not failed (`askedLacking`). That neighbour may
    hold the blob soon, and its HAVE asks it again.
  - A stream with more than 30 s left (`STREAM_SWITCH_MS`) is left when another neighbour said HAVE with load 0 and
    streams us nothing (`idleHolderPast`). The holder fails for the cycle, and our ask on it is withdrawn.
  - While stuck behind such a stream, a neighbour that said NONE is queried again every 10 s, and that doesn't count
    against `PULL_RECHECKS` (`lackedWhileStuck`).

  The time left is Android's `rxEtaMs`: the declared size less the bytes so far, at the rate since the header
  (`MeshTransport.fileArrivingLeftMilliseconds`), a skipped stream's included. This closes the first "Not mirrored"
  item above.
- **The holder parks a second ask, and answers with an `eta`** (AND-5; knit-next `79f38d3d`, `e2191bb9` and
  `3890f16b`, `BlobExchange.kt:1185-1452`). This reverses "it does not measure what it feeds" and "this port's own
  SENDING answers carry no `eta`".
  - **The meter.** `FeedMeter` ports `FeedMeter.kt` line for line. Each link's feed is measured from its receiver's
    reports, with Android's 15 s stall and its deadline of ETA × 5/4 + 30 s.
  - **Parking.** A holder already feeding a live copy of a blob parks a second ask for it. It serves the parked asks
    when that feed ends, stalls or passes its deadline, one a pass: members of the blob's conversation first, then
    the fastest link, then the oldest ask. A member goes beside a carrier's copy, and a carrier waits behind any copy.
    An ask goes beside a member's copy only when its own would end first and save more than it costs the feeds
    already running.
  - **The `eta`.** A SENDING answer carries the asker's own feed's ETA. A parked asker gets the feed ahead's end plus
    its own copy, and its park is kept that long plus 30 s.
  - **The edges.** A `blobcancel` drops a parked ask. The link tells the engine when a feed's reading moves
    (`LinkManager.takeFeedsChanged`, read by `Mesh` after each batch of events), and a poll every 1 to 10 s covers
    stalls and deadlines.
- **Left out, with reasons.**
  - Android's Wi-Fi Aware and Coded exceptions (`ridesSharedBudget`): with one radio, every feed shares the budget.
  - The boost's settling pace (`3890f16b`'s `settlingPace`): this port asks for no boost (ADR 2026-10.xwjc), so its
    feeds settle after 2 chunks.
  - `fedWhileBusy`, Android's count of a file fed in full while its link still feeds others: the radio here reports
    each chunk out of its queue.
  - The carrier's hold, which waits on Phase 4's carrier pulls, and resuming a cut transfer (knit-ios #2).
- **What grew.** `MeshTransport` gains `fileArrivingLeftMilliseconds(from:)`, `fileFeed(of:to:)` with its
  `FeedReading`, and `expectedFileRate(to:)`. Android gives each a default; here every transport answers them.
  `MessageStore.conversation(ofAttachment:)` names whom a holder serves first. `status.blobs` gains `asksParked`,
  Android's `blobAsksParked`.
- **Guards:**
  - `InteropAuditMeshTests`, both repros without `withKnownIssue`, and the idle holder;
  - `BlobStreamWaitTests` for the stuck rechecks and the waits that stay;
  - `FeedMeterTests`, `FeedMeterTest`'s ten cases;
  - `LinkFileFeedTests` and `MeshEngineBlobParkTests` for the readings, the parks, the order and the `eta`;
  - `MeshTests.aSecondAskForAPhotoWeFeedIsParkedAndServedOnceTheFeedEnds` through the actor;
  - `LinkFileProgressTests`' and `FileIntakeTests`' skipped-file cases;
  - `MessageAttachmentTests` for the conversation.
- **Device check (2026-10-10), passed.** The iPhone 12 ran this build (`81cd95b`) beside a Pixel 3 on knit-next
  `c544573c`, a Pixel 9 on `a0d8b488`, a Pixel 8 on `b7c13e57`, a Pixel 7 and a moto-g.
  - `interop.py iphone-photos` against the Pixel 3 passed all 17 steps.
  - An iPhone photo of 172 KB posted to the room, with the iPhone's log recorded. The Pixel 7 asked first and was fed at
    the 4 KiB/s pace. The Pixel 3 went beside it (`blob beside … its copy ~18152 ms, the feeds' 40173 ms; saves ~31097
    ms for ~9076 ms of theirs`) and held the photo 22.3 s after the post. The Pixel 8 and Pixel 9 were parked, then
    unparked one at a time, after 29.2 s and 71.8 s. The Pixel 9 held the photo 111.8 s after the post.
  - An earlier 290 KB photo reached the Pixel 3 in 20.4 s and the Pixel 9 in 139.1 s. The iPhone fed the Pixel 3 and
    Pixel 7 one after the other, and its SENDING answer held the Pixel 9 on its `eta` (`blob hold … floor 103889 ms`).

