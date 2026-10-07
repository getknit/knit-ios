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
  as Android's `blobCancelsTaken` does. Android sends an iPhone none yet: the gate is the one on `blobprog`, and it
  lifts once knit-next hears that this build takes the type.
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
- **Guards:**
  - `GoldenVectorTests` (64 vectors) and `BlobHaveContentTests` for the wire;
  - `LinkFileCancelTests` for the link;
  - `MeshEngineBlobCancelTests`' four cases for both ends, the gate and the widening;
  - `BlobAskStandsTests`' floor and link-gone cases for the fallback, and for withdrawing once;
  - `BlobPullThroughTests.aPullHasNothingToWithdrawOnceItsNeighbourSaysAtOrAfterItThatItLacksTheBlob`;
  - `LinkDoorbellTests.upkeepGoesOutWithoutRinging` and `PeerNodeTests` for `status.blobs`.
