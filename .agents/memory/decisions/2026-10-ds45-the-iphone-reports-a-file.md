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
uncommitted on knit-next's `main` above `3890f16b` on 2026-10-07, ahead of the pin.

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
- **Mirrored ahead of the pin.** When nsr7's commit lands, check its vectors, `PROGRESS_EVERY_MS`, `HOLD_SLACK_MS`,
  `HOLD_CAP_MS` and `hold` against these (`.agents/context/knit-next.md`).
- **Guards:**
  - `GoldenVectorTests` (63 vectors) and `BlobHaveContentTests` for the wire;
  - `LinkFileProgressTests` for the cadence, and `MeshTests.aFileStreamingInIsReportedBackToItsSender` through the actor;
  - `MeshEngineBlobQueryTests`' two progress cases for the gate and for taking a report without a key;
  - `BlobAskStandsTests`' three `eta` cases for the hold and the cap;
  - `LinkDoorbellTests.upkeepGoesOutWithoutRinging` and `PeerNodeTests` for `status.blobs`.
