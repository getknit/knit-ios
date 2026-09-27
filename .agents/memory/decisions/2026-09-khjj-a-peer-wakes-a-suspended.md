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
and answers each write.

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

**Consequences / limits:**

- **Cross-platform law.** The UUID becomes law once Android rings, which is companion change A4 in knit-next.
  Until then Android does not ring, and a locked iPhone reads Android's frames only at its next foreground.
- **Battery.** Each ring wakes the iPhone for about 9 s. A busy link keeps it awake most of the time, bounded at
  12 wakes a minute per link.
- **Anyone in range can ring.** The doorbell is unauthenticated. iOS wakes Knit before Knit can decide anything,
  so a stranger can spend the iPhone's battery, though a ring carries nothing.
- **An iPhone rings nobody yet.** It could ring only the peers it dialed, since CoreBluetooth has no GATT client
  toward a central that dialed it. Two locked iPhones wake each other only once `KnitBLE` rings.
- **BlueZ reads the services of a peer that dialed it on its own, some time after the link comes up.** A ring
  before then waits for that read. `Device1.Connect` does not force it: for an iPhone it takes BlueZ's BR/EDR path
  and hangs until the D-Bus timeout.
- **Guards.** `LinkTests`' `theGATTIdentifiersArePinned`, `LinkDoorbellTests`, `BlueZDoorbellTests`, and
  `scripts/check.sh ios`, which fails if the app lacks `peripheralManager:didReceiveWriteRequests:`.
  `interop.py iphone-wake --sender peer` checks the whole path on hardware.
