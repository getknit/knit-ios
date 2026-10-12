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
  `ios` profile reads it now and sets the flag, ADR 2026-09.xzpt; no real device has served it one yet. The
  relay line runs with a second peer on a shared `hci0`, below.)
- **Guards.** `BlueZLoopTests`, `BlueZAdvertTests`, `BlueZChannelTests`, `BlueZModelTests`' `hci0IsRefusedWhateverItsAddress`
  and `BlueZEdgeTests` guard the radio. `PeerNodeTests` guards the control surface. `LinkRefusalTests` guards
  `deny-link`, and a floor in `scripts/coverage-floors.json` guards each target.

**Amended 2026-09-26, for the relay line and `TemporaryTimeout = 0`:** the maintainer allowed `hci0` for tests that
need two adapters, one session at a time (`.agents/rules/devices.md`). Two rules came with it:

- **A shared adapter.** `hci0` is still refused by name unless `--shared-adapter` is given, and its address is
  checked like any adapter's. A shared adapter's links belong to whoever else uses it, so the peer skips the start's
  release of links left from before, and it only ever drops a link it made. `interop.py relay` runs peer B there,
  and passed 16 of 16. The guards are `BlueZModelTests`' `hci0IsTakenOnlyAsSharedAndStillByItsAddress` and
  `BlueZChannelTests`' `aSharedAdaptersLinksAreLeftAlone`.
- **The radio forgets quiet devices.** With `TemporaryTimeout = 0`, which stops bluetoothd cutting a link when a
  phone rotates its address, bluetoothd forgets no device at all. In 25 minutes, about 240 piled up across the two
  adapters, until the desktop's Bluetooth applet ran out of D-Bus match rules and power-cycled both adapters. So
  the radio asks BlueZ to forget a device it has not heard for 60 s, and when it stops, every device its run
  found. It never forgets a device with a link, a channel or a GATT read in progress, or one that is paired,
  bonded or trusted. On a shared adapter it forgets only what appeared after it started. The guards are
  `BlueZModelTests`' `onlyAQuietUnlinkedDeviceNobodyOwnsIsStale` and `BlueZChannelTests`' forgetting cases. The
  alternative was to keep bluetoothd's 30 s and live with the cuts, which ended 127 of the night soak's 213 links.

**Amended 2026-09-26, for the iPhone:** two rig limits showed once an iPhone joined (`.agents/context/linux-peer.md`,
"What the iPhone showed").

- **iPhone runs put the peer on a shared `hci0`.** `hci1`'s controller has 27-byte LE buffers, so the kernel
  offers an MPS of 23. On such a channel the iPhone sends about 16 fragments and then stops, with credits to
  spare, so its second message never completes. On `hci0` its writes arrive. The maintainer allows `hci0` for
  iPhone runs, one session at a time, under the shared-adapter rules above.
- **bluetoothd runs without its battery plugin** (`scripts/bluetoothd-no-battery.sh`). The plugin reads an
  iPhone's Battery Service, which needs encryption, so bluetoothd asks the iPhone to pair, and the kernel drops
  an unanswered link 30 s later. The change is machine-wide, so `hci0`'s devices show no battery level while it
  is in place.

The alternatives were pairing the iPhone with the rig, which would test an encrypted link that no phone uses,
and a dongle with larger LE buffers, which this machine does not have.

**Amended 2026-09-29, for the ATS2851:** the maintainer replaced the Edimax on `hci1` with an Actions ATS2851,
and it is `knit-peer`'s default adapter (`--adapter-address`) for now
(`.agents/context/linux-peer.md`, "What the ATS2851 showed").

- **The iPhone's writes flow on `hci1`.** Its controller has 251-byte LE buffers, so the kernel offers an MPS of
  247, and on a link the peer dialed the iPhone back-filled 206 KB in 8.3 s. It also advertises while linked, which
  the RTL8761BU could not.
- **It takes no incoming LE connection.** The controller answers neither a connect request nor a scan request,
  whatever the scan duty, so the peer on `hci1` only dials. A run where a phone dials the peer or reads its
  GATT payload needs `hci0`, under the go-ahead and the shared-adapter rules above, or the Edimax plugged back
  in and named with `--adapter-address`. The iPhone runs keep the peer on `hci0` as before.
- **Its settings go through `btmgmt`, interactively.** A one-shot `btmgmt --index 1 <command>` acts on `hci0`
  (BlueZ 5.72), so the root tools for `hci1` run as `.agents/rules/devices.md` says. `hci1-supervision.sh` now
  checks for the ATS2851's address.

The guard for the default is `PeerOptionsTests`' `runIsTheDefaultOnHci1WithTheRadiosOwnProfile`. The alternative
was keeping the Edimax, which leaves the iPhone's writes stalled on `hci1`.

**Amended 2026-10-01, for adapters by address:** a reboot that day made the ATS2851 `hci0` and the maintainer's adapter
`hci1`. The kernel numbers adapters in the order `btusb` binds them, and `btusb`, a module loaded late in boot, binds
them in USB enumeration order. At every boot port 3-7, the ATS2851's, comes about a second before port 3-14, the
Intel's internal one. The ATS2851 had been `hci1` only because it was plugged in after boot. knit-peer then refused it
as `hci0` unshared, and the sudoers lines for `btmon`, `btmgmt` and `hcitool` reached the maintainer's adapter.

- **knit-peer takes an address, not a name.** `--adapter` is gone. `AdapterProbe.select` finds the adapter BlueZ lists
  with `--adapter-address`, under whatever `hciN` it has, and the peer exits when no adapter has it. The rule that kept
  the peer off `hci0` now keeps it off the maintainer's address (`AdapterSelection.maintainersAdapter`) unless shared,
  and the probe checks it before asking BlueZ anything.
- **The scripts and the root tools go by address too.** `interop.py` passes addresses alone, and finds an index through
  `hcitool dev` where it must name one. `hci1-supervision.sh` finds the ATS2851 by its address. Root goes through
  `scripts/knit-hci.sh`, installed root-owned in `/usr/local/sbin`, which runs `btmon`, `hcitool` or `btmgmt` on the
  ATS2851 alone. sudoers grants it in place of the three lines that named `hci1`.
- **Limits.** The radio watches the path it started on. A replug that renumbers its adapter mid-run leaves the radio off
  until the peer restarts, and another adapter at that path fails the address check. The notes keep `hci1` and `hci0`
  as names for the ATS2851 and the maintainer's adapter. The alternative was forcing the boot order, holding the dongle
  unauthorized until the Intel binds. That races `btusb`'s load, and its robust form changes USB authorization for
  every external device.
- **Guards.** `BlueZModelTests`' `theMaintainersAdapterIsRefusedUnderAnyName`,
  `theMaintainersAdapterIsTakenOnlyAsSharedAndStillByItsAddress`, `hci0IsTakenLikeAnyOtherName` and
  `anAdapterIsFoundByItsAddressUnderWhateverNameItHas`, `BlueZEdgeTests`' probe cases, and `PeerOptionsTests`'
  `noFlagNamesAnAdapterByItsIndex`. They replace `hci0IsRefusedWhateverItsAddress` and
  `hci0IsTakenOnlyAsSharedAndStillByItsAddress`, and `runIsTheDefaultOnHci1WithTheRadiosOwnProfile` is now
  `runIsTheDefaultOnTheATS2851WithTheRadiosOwnProfile`.

**Amended 2026-10-03, for the nRF52840 dongles:** the maintainer bought two Nordic nRF52840 Dongles
(PCA10059). Both run `firmware/knit-hci`, Zephyr's `hci_usb` sample with Knit's controller settings, built and
flashed by `scripts/dongle-firmware.sh` (`.agents/context/linux-peer.md`, "The nRF52840 dongles"). Dongle A
(`$KNIT_ADAPTER_A`) is `knit-peer`'s default adapter, in place of the ATS2851. Dongle B (`$KNIT_ADAPTER_B`)
takes a run's second peer, in place of the maintainer's adapter.

- **The firmware sets what the earlier adapters lacked.** 251-byte LE buffers × 8 and data length extension give
  an MPS of 247. It holds 8 connections and has 4 advertising sets. Both dongles take incoming LE connections and
  advertise while linked in either role (`linux-peer.md`, "What the nRF52840 dongles showed").
- **The firmware gives the controller a public address.** Zephyr's controller otherwise reports none and runs on a
  static random address, which knit-peer's `BDADDR_LE_PUBLIC` sockets would not route to. Each chip's FICR device
  address becomes its public address, so knit-peer, the scripts and their address checks need no change. The
  alternative was teaching `KnitBlueZ`, `AdapterProbe` and the scripts to bind a random identity address, which
  touches every socket and every check by address.
- **No run needs the maintainer's adapter.** `interop.py`'s second peer runs on dongle B, unshared. The Intel still
  needs a go-ahead, and the peer still runs there only with `--shared-adapter`.
- **The root tools cover the dongles.** `scripts/knit-hci.sh` takes `a`, `b` or `ats2851` and never another address,
  and `hci1-supervision.sh` sets every Knit adapter it finds. Both must be installed again for sudo and udev to see
  the change.
- **Zephyr is pinned to `v4.4-branch` at `f8523a9c66`, not v4.4.2.** v4.4.2's USB HCI class copies each packet to
  the host into a 64-byte buffer, which 251-byte packets overflow, and the controller stops answering. The branch
  fixed it in `ea86c1235c`.
- **The iPhone works on a dongle.** It dials dongle B and writes 2,570-byte SDUs from the start, and
  `interop.py iphone-peer` passed 21 of 21 there on 2026-10-03.
- **Limits.** Reflashing needs someone at the dongle's reset button. The relay line on B and six links at once are
  still to run. Two of three dials in one run took 12 to 14 s to open the
  channel, so knit-peer's 12 s watchdog cut one short.

The guard for the default is `PeerOptionsTests`' `runIsTheDefaultOnDongleAWithTheRadiosOwnProfile`.

**Amended 2026-10-11, for a rotating stranger (knit-ios #3):** knit-next #154's trial needs a device that rotates its
address under `0xFE30`, and the identity addresses above must not move. So `knit-peer stranger` runs on dongle B with
LE privacy on, set through `knit-hci b btmgmt`, for the length of `interop.py android-strangers` only, and the run
turns it off again however it ends. With privacy on, the kernel sends each advertising instance from a resolvable
private address. `Adapter1.Address` and the debugfs identity stay the public address knit-peer finds the dongle by.
The stranger registers its advert afresh every `--rotate` seconds, but that does not move its address on the air. On
2026-10-12 the kernel gave each new advertising set its own resolvable private address, as btmon on dongle B showed.
Dongle A, listening, still heard the stranger at one address through a minute of registrations, and the Pixel 7 read
it at one address for 15 minutes, the kernel's default `rpa_timeout`. The dongles' controller advertises from the
device's random address, not the set's. So a rotating stranger needs that address to change. A power cycle under
privacy appears to give a new one. Debugfs `rpa_timeout` would rotate it in place, through a `knit-hci` command that
does not exist yet (the kernel's floor is 30 s). Neither is settled. The stranger runs no link manager and hangs up on any dialer
before a HELLO, so it never links. `PeerOptionsTests`' stranger cases and `BlueZAdvertTests`'
`aRotatingAdvertIsRegisteredAfreshOnItsDeadlineAndTheOldOneWithdrawn` guard it.
