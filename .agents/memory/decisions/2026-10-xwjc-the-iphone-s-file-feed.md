---
id: "2026-10.xwjc"
slug: the-iphone-s-file-feed
title: "The iPhone's file feed is clocked by its receiver's reports"
date: 2026-10-09
topics: [ble, mesh, blobs, interop]
---

# ADR 2026-10.xwjc — The iPhone's file feed is clocked by its receiver's reports

Status: Accepted (2026-10-09). Amends ADR 2026-10.h6zz (the pace) and ADR 2026-10.ds45 (the report's cadence, and who
gets reports and withdrawals). Mirrors knit-next ADR 2026-10.5buf, with its amendments of 2026-10-08, and knit-next
ADR 2026-10.8jwn, ahead of the pin. Both were read from knit-next's working tree at `713b29d6`: `FeedWindow.kt`,
`RxReports.kt`, `FramedLink.kt:367-430` and `:686-828`, `CodedPhyPolicy.kt:311-387`, and
`BluetoothMeshTransport.kt:1174-1227`. No wire change.

**Context:** this port fed every link at 28 KiB/s in 16 KiB chunks (ADR 2026-10.h6zz). On 2026-10-07 knit-next's A/B
found that a fixed pace is wrong both ways. 28 KiB/s overfed a slow pair: 8jwn measured 1M drains of 4.8 to 11 KB/s,
and texts waited 50 to 280 s behind a photo. A dark pair drained the same photo in about 12 s, where the 4 KiB/s base
took 111 s. Android now clocks a file by its receiver's `blobprog` reports: a window sized from the drain the reports
measure, with the 4 KiB/s base as the fallback for a receiver that is silent or reports only every two seconds. It
leaves iPhones out on both sides. It sends no report to a link whose HELLO carries `CAP_DOORBELL`
(`BlobExchange.onFileProgress`), and it never windows a feed to one (`BleFeedPolicy.windowed`). This port reported
only every 2 s (ADR 2026-10.ds45), a cadence that the window cannot be clocked by.

**Decision:** the iPhone does all three parts of it, and Android lifts its two gates separately.

- **It reports at the window's cadence** (`RxReports`, `LinkManager.fileProgress`). It reports on every chunk that
  brings 2 KiB since the last report, at least every 500 ms, and once more 500 ms after chunks that no report carried.
  That last one is the trailing report, a deadline in `LinkManager.nextDeadline`, as every timer here is (ADR
  2026-09.gq84). A stall sends nothing. That is about four reports a second per file coming in, roughly 500 B/s back.
  It is ready for Android to window its feeds to an iPhone once that gate lifts.
- **It windows its own feed** (`FeedWindow`, a line-for-line port). A file to a peer whose HELLO carries
  `CAP_BLOB_HAVE`, an iPhone included, is written while what no report has said landed stays under
  `rate × (round trip + 250 ms)`, from 4 to 64 KiB. Each chunk is about a quarter second of the rate, 2 to 16 KiB. The
  rate is the largest of the last twelve drain samples. The round trip is the smallest in the last 10 s, probed when
  it goes stale. The window is the link's, kept across its files. A report frees the window at once
  (`LinkManager.fileProgressReported`, through `MeshTransport`), and a report about another file only wakes the feed.
  A chunk counts as written when it is handed to the radio. The radio's report that the chunk left its queue still
  gates the next chunk, so frames go out between chunks as before.
- **Its fallback is 8jwn's pace.** One 4 KiB/s budget is split evenly among the links feeding at the pace, each chunk
  two seconds of a link's share, 2 to 16 KiB. A windowed feed takes no share of it. The fallback is used for:
  - a peer whose HELLO lacks `CAP_BLOB_HAVE`, an Android build from before it;
  - a receiver silent for 3 s, until it reports;
  - one taken for a two-second reporter, in 2 KiB chunks, until three on-time answers give the window back.

  Each chunk still waits its own spacing, so a resumed app never bursts (h6zz). A windowed wait that fires late, as a
  suspended app's timer does, tells the window how late (`FeedWindow.slept`). With nothing owed, that time is not the
  receiver's silence.
- **This port's own gate lifts.** `blobprog` and `blobcancel` go to every neighbour whose HELLO carries
  `CAP_BLOB_HAVE`, iPhones included (`MeshEngine.readsBlobUpkeep`). That windows iPhone↔iPhone links and knit-peer's
  `ios` profile now. The maintainer accepted the cost on 2026-10-09: an iPhone on a build from before ADR 2026-10.ds45
  takes either type for a signed frame and spends key requests on it.
- **Switches:** `LinkManager.Configuration.feedWindow` (Android's `BLE_FEED_WINDOW`, on) turns both the window and
  the cadence off together. knit-peer's `--feed pace` is the A/B switch, as Android's `…debug.LINKTUNE --es feed` is.
  The app has no switch.
- **Oracles:**
  - `link file window back|paced: receiver silent|paced: two-second reporter → <node>` on each change;
  - `link file window rate=… target=… queued=… rtt=… → <node>` when the rate moves by a quarter;
  - `link file pace budget=… feeding=… share=… chunk=… → <node>` when a link's count of paced feeders changes;
  - the sent line ends with `@<rate> window` or `@<pace>`.

**Left out, with reasons.**

- **Android's Coded parts.** CoreBluetooth never shows the PHY, so `forgetLink`, `stepBacklog` and a smaller Coded
  chunk have nothing to trigger them. A 1M↔2M step is followed by the drain filter and the 10 s probe, as on Android.
- **The resume offset.** This port never resumes a cut transfer (knit-ios #2).
- **nsr7's holder half.** That is the meter, parking a second ask behind a live feed, and `eta` on a SENDING answer.
  The window replaces the pace the meter would time, but nothing here parks yet (`.agents/memory/roadmap.md`).
- **The boost** (knit-next ADR 2026-10.2da4). An iPhone cannot ask for a connection interval as a central. As a
  peripheral, Android's doorbell already asks BALANCED for the supervision timeout (knit-next ADR 2026-09.dqvb). The
  window measures whatever drain the interval gives. A Pixel snoop of an iPhone feed should come first.

The alternative a reader reaches for first is to drop 28 KiB/s to Android's 4 KiB/s and stop there. That stops the
overfeed but cuts a fast pair's photo to a seventh of its drain, and the A/B showed links in one lab running from 4.8
to more than 28 KB/s. A simpler window was also tried on Android and broke in three ways (knit-next device sweeps):

- refilled only on reports, it sank to its floor;
- without the round trip, it got half the link;
- with four drain samples, it spiralled down.

So this is a port, not a redesign.

**Consequences / limits:**

- **Until Android lifts its report gate, an iPhone feeding an Android phone hears nothing.** It writes the 8 KiB
  starting window, waits out the 3 s silence, and goes on at the 4 KiB/s fallback, where it went at 28 KiB/s before.
  That is slower for a fast pair. In return a DM no longer waits a minute behind a photo in Android's stack.
- **Android windows its feed to an iPhone only once `BleFeedPolicy.windowed` lifts.** Until then it feeds an iPhone at
  its paced base, and this build's quicker reports cost about 500 B/s of reverse air for nothing but Android's meter.
- **A suspended iPhone reads nothing until a doorbell wakes it** (ADR 2026-09.khjj), and FILE records never ring. So
  a sender to a backgrounded iPhone hears nothing and falls back to the pace after 3 s. The window comes back with
  three on-time answers once Knit is in front, which is when someone is watching the chat.
- **The trap:** a test clock that jumps past a feed's wait reads as the app suspended, not the receiver silent.
  `LinkRig.run(until:)` fires each deadline in turn for that reason.
- **Guards:**
  - `FeedWindowTests` (the rules) and `FeedWindowSimTests` (Android's simulated link, its bounds unchanged);
  - `FilePaceTests` for the split;
  - `LinkFileWindowTests` and `LinkFileTests` for the feed, the gate and the fallback through the link manager;
  - `LinkFileProgressTests` for both cadences;
  - `MeshEngineBlobQueryTests` and `MeshEngineBlobCancelTests` for the lifted gate and the hand-off;
  - `MeshTests.aReportArrivingOnTheLinkFreesTheWindowOfThePhotoWePush` through the actor;
  - `PeerOptionsTests` for `--feed`.
- **Device check owed** (with a go-ahead on the phones): knit-peer on dongle A with `--radio-profile android`, which
  a release Pixel reports to and windows already.
  - **The peer pushing a photo near 1 MiB:** read `link file window rate=` and a DM sent mid-file landing within
    about 5 s, then the same with `--feed pace`.
  - **The Pixel sending to the peer:** read `bt file window rate=` in its logcat and no `paced: two-second reporter`.
