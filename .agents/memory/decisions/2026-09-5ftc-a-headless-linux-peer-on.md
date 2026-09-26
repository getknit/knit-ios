---
id: "2026-09.5ftc"
slug: a-headless-linux-peer-on
title: "a headless Linux peer on hci1 is the first interop rig"
date: 2026-09-25
topics: [interop, ble, testing]
---

# ADR 2026-09.5ftc — a headless Linux peer on hci1 is the first interop rig

Status: Accepted (2026-09-25)

**Context:** there is no Mac or iPhone yet, so nothing can run CoreBluetooth. The engine and link manager are
tested one node at a time (ADR 2026-09.gq84), and the goldens pin the bytes, but neither shows that Android
accepts what this port puts on the air. This machine has a second adapter, `hci1` (an Edimax BT-8500). `hci0`
is the maintainer's own adapter, with live connections, and must never be touched.

**Decision:** `knit-peer` runs the same `Mesh` the app will run, over a BlueZ `Radio` on `hci1`, and takes JSON-lines
commands on standard input. `scripts/interop.py` drives it against a phone through knit-next's debug bridge. The
details:

- **The radio.** `KnitBlueZ` has one thread, with one `poll` loop over the mailbox, a private libdbus connection
  and every L2CAP socket. It advertises through `LEAdvertisingManager1`, registering a new advert before it
  withdraws the old one, and scans through `Adapter1`. For `--radio-profile ios` it also serves the GATT payload
  (ADR 2026-09.xzpt).
- **Keeping off `hci0`.** `hci0` is refused by name. The adapter's address is checked against BlueZ before any
  socket opens, and every socket binds to that address. The check is what keeps the peer off `hci0`, because
  the kernel binds and listens on an address no adapter has.
- **Tests.** A fake BlueZ on a peer-to-peer libdbus server, with Unix `SOCK_SEQPACKET` sockets in place of L2CAP,
  runs the whole radio in CI with no adapter and no bus daemon.
- **Rig controls.** `deny-link` refuses a peer both ways, for forcing a line. `keygen` takes a window of node ids,
  which picks the dial order. `scan` lists the Knit nodes in range without linking.

The alternatives were Python scripts or an emulator. Python, as spike (e) used, would test a second
implementation instead of this one. knit-next's emulator script takes the same dongle and needs an Android build.

**Consequences / limits:**

- **No advertising while linked.** The RTL8761BU cannot advertise while a peer is connected to it: `Roles` lacks
  `central-peripheral`, and `RegisterAdvertisement` fails until the link closes. bluetoothd's own GATT client
  holds every LE link up after its channels close, which left the peer unreachable for hours after spike (e).
  So the radio disconnects a device once its last channel closes, when it goes down, and at start
  (`BlueZChannelTests`' link-release cases). An interop run also keeps every other phone from dialing the
  peer (the `keygen` window, then `deny-link`).
- **The peer dialing a phone is fragile.** The Pixel advertises at −11 dBm, so the peer hears it near the
  promotion floor and rarely; `--rssi-floor` loosens the floor for development only. A link the kernel dials
  gets its 420 ms default supervision timeout, where Android's own is 5 s, and a busy phone misses that. The
  phone-dials order is the reliable one for checklist L until hci1's `supervision_timeout` is raised
  (`sudo scripts/hci1-supervision.sh`, or its udev rule, since a replug resets it).
- **Small SDUs.** The radio writes SDUs of 247 bytes at most (`L2CAPSockets.defaultSendMTU`, `--send-mtu` to
  change it). A Moto G on an Android 14 GSI lost the stream after large SDUs in every full check and never with
  these; Android reads the channel as a byte stream, so only the SDU count changes.
- **Slow back-fill.** Android's back-fill runs at about 1 KB/s over this pair, and a new post queues behind it.
  `interop.py` times posts only after custody converges.
- **Not tested here.** Relaying between two peers needs a second adapter. Reading a GATT payload from a
  UUID-only advert is not built, so the advert never sets `FLAG_DIALS_GATT_PEERS`. (Amended 2026-09-26: the
  `ios` profile reads it now and sets the flag, ADR 2026-09.xzpt; no real device has served it one yet.)
- **Guards.** `BlueZLoopTests`, `BlueZAdvertTests`, `BlueZChannelTests`, `BlueZModelTests`' `hci0IsRefusedWhateverItsAddress`
  and `BlueZEdgeTests` guard the radio. `PeerNodeTests` guards the control surface. `LinkRefusalTests` guards
  `deny-link`, and a floor in `scripts/coverage-floors.json` guards each target.
