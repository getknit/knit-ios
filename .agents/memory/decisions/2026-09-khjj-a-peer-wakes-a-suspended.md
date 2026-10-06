---
id: "2026-09.khjj"
slug: a-peer-wakes-a-suspended
title: "a peer wakes a suspended iPhone by writing its GATT doorbell"
date: 2026-09-27
topics: [ble, interop, transport]
---

# ADR 2026-09.khjj — a peer wakes a suspended iPhone by writing its GATT doorbell

Status: Accepted (2026-09-27)

**Context:** iOS suspends Knit a few seconds after it leaves the screen. On iOS 27, data arriving on an open L2CAP
channel does not resume it. In MVP item 9's wake test an iPhone 12 stayed locked for 14 minutes with its link to the
Pixel 3 up the whole time, and Knit read none of ten DMs until someone opened it. All ten then arrived within a
second, from the link's buffer. What CoreBluetooth does resume a suspended app for is a delegate event: a
disconnect, a characteristic's notification, or a read or write request to the app's own GATT server. bluetoothd
takes a RunningBoard assertion on the app for each one, and Knit then runs for about 9 s. Without such an event, a
locked iPhone neither receives nor relays, though its links stay up.

**Decision:** a node that iOS may suspend serves a doorbell. This is a second characteristic in its `0xFE30` service,
`f34c056b-5830-4243-a888-01f92f49e446`, minted on 2026-09-27. It can be written with or without a response, and
its value means nothing. A write resumes Knit, which then reads whatever waited on its links, answers it, and posts
its notifications. `LinkManager` decides when to ring, one link at a time. After a frame goes out on a link it
rings that link, at most once every 5 s. If more frames go out during those 5 s, it rings once more when they end,
so a burst costs two wakes. Digests and HELLOs do not ring: they are the link's own upkeep, and wait for the next
wake. The radio decides whether it can ring. `Radio.ring(_:)` does nothing by default. `KnitBlueZ` does a write
without response to the doorbell BlueZ found on the device at the channel's other end, so the write rides the
link the channel already uses. It waits until BlueZ has read that device's services. `KnitBLE` serves the doorbell
and answers each write. It rings the peers it dialed, looking the doorbell up once per connection and writing
without a response when CoreBluetooth has room for one. A ring heard is a `RadioEvent.rung`, counted as `rung` in
the control protocol's `status`. The Linux peer's `ios` profile serves a doorbell too, though it never sleeps, so
that the iPhone's rings can be checked.

It was tried by hand before it was built. On 2026-09-27, with the iPhone locked and knit-peer on a shared `hci0`, a
DM that went unanswered for 40 s was delivered 4.8 s after a write without response, and 7.7 s after a write with
one. runningboardd showed bluetoothd resuming Knit at each write, and Knit ran 9 s each time.

Three alternatives were weighed:

- **Notifications to the iPhone as central.** A notification wakes an app too, but Android serves no GATT at all.
  The iPhone would also have to subscribe on every link it holds.
- **A background mode that keeps Knit running.** Audio or location would keep Knit alive, but using either for
  this is exactly what App Review refuses.
- **Item 9's fallback, where a DM arrives at the next foreground.** It needs nothing new, but a locked iPhone
  would then carry nothing for the mesh.

**Amended 2026-09-27, when A4 was built** (knit-next `c3191717` on branch `feat/ble-doorbell`, its ADR 2026-09.dqvb;
on knit-next's local `main`, not yet pushed): Android rings a peer that asks to be rung, and the peer asks with a capability bit in its HELLO,
`CAP_DOORBELL = 0x1000`. Whether the HELLO carries it is the radio's call: `Radio.servesDoorbell` is true for
`KnitBLE` and for the Linux peer's `ios` profile, whose HELLOs read `1009`, and false everywhere else, where they
still read `9`. The bit stays out of `Capabilities.local`, the signed profile and the advert, whose one capability
byte could not hold it anyway, so no fixture or emitted vector moved. Android reads it only from the HELLO of a link
it accepted, because a dialed link takes its capabilities from the advert, so until A3 only links the iPhone dialed
ring. It then opens a GATT client on that link's own connection, looks the doorbell up once, and rings it with a
write without response, on this ADR's schedule. Both sides also stopped ringing for three frame types: `typing`,
`blobreq` and `keyreq` now wait for the next wake, as digests do. They are the link's upkeep, and the 60 s tick
re-sends both requests for as long as a blob or a key is missing, which would wake the iPhone every minute. The UUID
is cross-platform law once that commit reaches knit-next's `origin/main`. `LinkTests`'
`theDoorbellBitIsPinnedAndNeverOurs` and `LinkDoorbellTests` guard the bit and the filter. On hardware,
`interop.py android-rings` checks that Android rings, and it passed 9 of 9 against the Pixel 3 on 2026-09-27: the
Pixel found the doorbell 4 s after the link came up, and a post and a DM each rang within 1.5 s of being sent.
`interop.py iphone-wake --sender phone --expect-wakes` checks that those rings wake a locked iPhone. It passed 10 of
10 the same morning: every DM of ten locked minutes woke Knit, arrived within 0.3 s, was delivered within 3.2 s and
was notified. One cost showed up at link-up: twice in three links, the iPhone read a record tag outside 1..7 while
the Pixel was still discovering its GATT services, and dropped the link. The iPhone dialed again at once, and the
third link held for the whole run (`.agents/context/linux-peer.md`, "What A4 showed"). The cause is not yet known.

**Consequences / limits:**

- **Cross-platform law.** The UUID becomes law once Android rings, which is companion change A4 in knit-next.
  Until then Android does not ring, and a locked iPhone reads Android's frames only at its next foreground.
- **Battery.** Each ring wakes the iPhone for about 9 s. A busy link keeps it awake most of the time, bounded at
  12 wakes a minute per link.
- **Anyone in range can ring.** The doorbell is unauthenticated. iOS wakes Knit before Knit can decide anything,
  so a stranger can spend the iPhone's battery, though a ring carries nothing.
- **An iPhone rings only the peers it dialed.** CoreBluetooth has no GATT client toward a central that dialed
  it. Between two iPhones the larger node id dials, so it can wake the smaller, and the smaller cannot wake it.
  Nothing on an Android link rings from the iPhone: Android serves no doorbell, and one service discovery per
  connection finds that out.
- **BlueZ reads the services of a peer that dialed it on its own, some time after the link comes up.** A ring
  before then waits for that read. `Device1.Connect` does not force it: for an iPhone it takes BlueZ's BR/EDR path
  and hangs until the D-Bus timeout.
- **Guards.** `LinkTests`' `theGATTIdentifiersArePinned`, `LinkDoorbellTests`, `BlueZDoorbellTests`, and
  `scripts/check.sh ios`, which fails if the app lacks `peripheralManager:didReceiveWriteRequests:`.
  `interop.py iphone-wake --sender peer` checks the whole path on hardware, and `interop.py iphone-rings` checks
  the iPhone's rings.

**Amended 2026-09-30:** with groups (ADR 2026-09.n393) this build's capabilities are `0xB`, so a HELLO from a radio
that serves the doorbell reads `100b`, and one from any other radio reads `b`. A build from before groups still reads
`1009`, and every parser takes both. `LinkTests`' `theDoorbellBitIsPinnedAndNeverOurs` checks both.

**Amended 2026-10-03, for files (ADR 2026-10.h6zz):** FILE records never ring, as Android's `sendFile` never does.
A photo streaming to a locked iPhone therefore wakes it no more often than its frames do, and the frames around it
still ring. `LinkDoorbellTests.fileRecordsDoNotRing` pins it. The device check that a file streaming to a locked
iPhone does not hold back a DM's ring is owed (ADR 2026-10.nh55's plan, Phase 3).

**Amended 2026-10-05, for the blob holder query (ADR 2026-10.m9uq):** `blobhave` and `blobhas` join the upkeep that
never rings, five types in all, as Android's `DoorbellPolicy.UPKEEP` has them since `403cd861`. A HELLO now also claims
`CAP_BLOB_HAVE` (`0x2000`), so one from a radio that serves the doorbell reads `300f`, and one that does not, `200f`.
