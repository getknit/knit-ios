---
id: "2026-10.mueg"
slug: a-lonely-iphone-in-the
title: "a lonely iPhone in the background seeks peers within a wake budget"
date: 2026-10-02
topics: [ble, transport, interop]
---

# ADR 2026-10.mueg — a lonely iPhone in the background seeks peers within a wake budget

Status: Accepted (2026-10-02)

**Context:** an iPhone in the background that loses its last link is never linked again until someone opens Knit. On
2026-10-02 the Pixel 9 Pro XL's link to the iPhone 12 ended at 15:58 in a supervision timeout, and a DM sent at about
16:24 waited, with the phones a metre apart. It was not a doorbell fault: the doorbell (ADR 2026-09.khjj) wakes a
suspended iPhone, but only over a link that is up. Nothing could build one. A backgrounded iPhone's `0xFE30` UUID
moves to Apple's overflow area, which only an iOS scan filtered on that UUID reads, so neither Android, nor BlueZ, nor
an iPhone at the front can find it. And Knit's own scan, which asks for every advert, goes quiet in the background.
P8's scan-filter check had already measured the fix and its cost (`.agents/context/linux-peer.md`). Locked, a scan for the UUID
found peers 30 to 120 s after they appeared, Android's service data included. But each match resumed Knit for about
10 s, and near five phones Knit ran three quarters of the time, so the scan stayed unfiltered.

**Decision:** the link manager seeks peers while Knit is in the background, holds no link, and has wakes left to spend,
and the radio scans for the `0xFE30` UUID alone while it does (`Radio.seekPeers`). `KnitBLE` filters its scan then,
and the other radios do nothing, since nothing suspends them. The rule lives in `LinkManager+Seeking.swift`, where
the Linux suite drives it. Three things change while seeking:

- **One sighting is enough.** iOS reports a peer rarely in the background and resumes Knit for about 10 s, so the
  12 s dwell could never end. Promotion runs with no dwell; the −90 dBm floor, the 12 s silence limit and backoff
  hold.
- **The order is ignored, in promotion only.** No peer can find a backgrounded iPhone, whatever its
  `FLAG_DIALS_GATT_PEERS` says, so the iPhone dials whomever it finds. Admission keeps the order (`weDial`), so a
  cross-dial settles as at the front: the larger side refuses a dialer it sighted, and the smaller admits it. The
  roadmap's version ignored only a service-data peer's flag. That is too narrow, since an iPhone at the front scans
  unfiltered and cannot read the overflow area either.
- **A budget bounds the wakes.** A spell of seeking spends at most 8 wakes (`seekWakeBudget`). A sighting 10 s or
  more after the current wake began starts the next, counted from the wake's start, so wakes that iOS chains back to
  back count too. The wake that spends the budget still dials what it found. A spent budget waits for the front,
  Bluetooth coming back on, or the loss of a link that held 30 s; a link that flapped carries the count on.

The background means the scene phase `.background`, not "not active": under Control Center Knit is still on screen
and still found. The app also seeds the state at launch from `UIApplication.applicationState`, so a relaunch to
restore Bluetooth seeks. In the background a channel deadline found more than 1 s late is put off once by 3 s. Timers
do not fire in suspension, and on resume the timer and the radio's news reach the actor in no fixed order. KnitBLE
restarts a scan whose filter is not the one wanted, as a scan restored by iOS may be. It also keeps a GATT read's
connection 2 s for the dial that seeking makes on that read.

**A suspended iPhone must hear its last link end, or it never seeks.** A link the iPhone dialed ends in
`didDisconnectPeripheral`, a delegate event that resumes Knit. A link the far side dialed had no such event: its end
reached Knit only through the L2CAP channel's streams, which wait in a suspended process. On the first build an `ios`
peer that dialed the locked iPhone was killed, and Knit heard of it four minutes later, when it was opened. So
`KnitBLE` connects the far side of every accepted link as a peripheral too (`attach`), over the connection the device
already holds, and the end of that connection reaches `didDisconnectPeripheral` like a dialed one's.

Two alternatives were weighed:

- **Filter the scan whenever Knit is in the background,** links or not. That is P8's cost, for discovery a linked
  iPhone already has through its links.
- **A background task that re-arms seeking.** `BGAppRefreshTask` runs when iOS chooses, often hours apart, so it
  bounds nothing a user would notice. It stays on the roadmap as the way to seek again after a spent budget.

**Consequences / limits:**

- **A spent budget means dark until the front.** With no link and an unfiltered scan, nothing wakes Knit to seek
  again. Eight wakes cost about 80 s of runtime a spell. Near peers it cannot link, such as one too far away or one
  that refuses it, that is the most it spends.
- **The budget lives in memory.** A relaunch to restore Bluetooth starts a fresh one.
- **Uncounted wakes.** A stranger's `0xFE30` advert whose GATT read gives no sighting wakes Knit uncounted.
- **The far side must have forgotten the iPhone.** An A3 phone that sighted the iPhone at the front in the last 90 s
  refuses its dial once, as a sighted dialer below it. Backoff then waits for its sighting to linger out.
- **On hardware, 2026-10-02** (`.agents/context/linux-peer.md`, "What background seeking showed"): with the watch,
  hci1 powering off resumed the locked iPhone in the same second. A Pixel 9 that force-stopped and reopened Knit was
  heard 4.8 s later, dialed by the iPhone on its third wake, and linked 36 s after the drop, and its DM then arrived
  in 2.5 s, all with the iPhone locked. Stopping the Pixel's Knit again ended the link the iPhone had dialed, heard in
  4.5 s. Near four refused phones the budget spent its eight wakes in 2 minutes, and Knit then slept.
- **A far side that keeps its connection after its app dies goes unheard.** Android drops it, so the iPhone hears.
  A stack that keeps a GATT client of its own on the link, as BlueZ may, would leave the iPhone's connection up and
  its channel's end waiting; no such peer was tried. Nor was a radio going off under a link with no watch, so whether
  the channel's end alone wakes Knit then is not known.
- **The watch costs a connection attempt per accepted channel,** most of them refused dialers whose channel closes
  before it connects; closing the channel cancels it.
- **Guards:** `LinkSeekingTests`, `LinkSeekDialTests` and `LinkSeekBudgetTests` pin when Knit seeks, whom it dials and
  the budget. `MeshControlTests` pins the `seeking`, `seekWakes` and `seekSpells` status fields. `interop.py
  iphone-seek` checks the whole path on hardware: `--mode drop` ends a link under a locked iPhone, `--mode relink`
  restarts the far side, and `--mode budget` counts the wakes.
