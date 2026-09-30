# The Linux peer (`knit-peer` and `KnitBlueZ`)

A headless Knit node on this machine's second Bluetooth adapter, for interop runs against Android phones
before there is an iPhone (P4). `.agents/specs/mvp.md` has what it must prove; `.agents/rules/devices.md` has
the rules for the radios and phones it touches.

## The adapter

- **`hci1` is an Edimax BT-8500** (USB `7392:c611`, Realtek RTL8761BU), public address `0A:BC:DE:00:00:A1`,
  named "linux-host #2". It has the central and peripheral roles, `LEAdvertisingManager1` with 4 advertising
  instances, and `GattManager1`. Its controller has 27-byte LE buffers, so the kernel offers a channel an MPS
  of 23, the least the spec allows. Android copes with that; an iPhone does not ("What the iPhone showed").
- **`hci0` is the maintainer's**, an Intel controller (Bluetooth 5.4) at `A0:00:00:00:00:01` that holds the
  maintainer's own devices. The peer checks that its adapter has the expected address before it does anything,
  and binds every socket to that address, so nothing it does lands on another adapter. It runs on `hci0` only
  as a shared adapter, with a go-ahead: for the relay line's second peer, and for every iPhone run.
- **knit-next's emulator script passes the same dongle through** to an Android emulator; the two cannot use it
  at once.

## What spike (e) showed

Run on 2026-09-25 as `maintainer`, without root; D-Bus policy lets a user register advertisements.

- **The advert:** BlueZ takes Android's layout through `LEAdvertisingManager1` on `hci1`: `Type` peripheral,
  `Discoverable`, and `ServiceData` for `FE30` holding the 24-byte payload, with no name and no includes.
  `RegisterAdvertisement` succeeds and `ActiveInstances` goes to 1.
- **The LE CoC listener:** a `SOCK_SEQPACKET` L2CAP socket bound to `hci1`'s address as `BDADDR_LE_PUBLIC`
  with PSM 0 gets a dynamic PSM (`0x0080` on the first try) at `BT_SECURITY_LOW`, and `BT_MODE` reads back
  LE flow control. `CBluetoothShim`'s `sockaddr_l2` is 14 bytes, the same as the kernel's.
- **`btmgmt --index 1 advinfo` hangs for a normal user.** Read state from the D-Bus properties instead.

## What the Pixel 3 showed

Three runs on 2026-09-25 against the Pixel 3 (Knit 2.7.0-alpha.0, a debug build), with the peer advertising a
node id just below the Pixel's so that the Pixel dials. The two other Knit phones in range sort lower and
never dialed.

- **Android finds the advert and dials the PSM:** RSSI −54 to −56 dBm, PSM parsed as 128, promotion after
  the 12 s dwell, and an L2CAP connect in 0.2 to 3.6 s.
- **The two-way HELLO works.** Android sends `nodeId|1|fff`, accepts our `nodeId|1|9`, and logs `bt link up`.
  It dials from a resolvable private address (LE random), which stayed the same across four links in five
  minutes.
- **After every link-up** Android sends its profile (one 548-byte `FRAME`), then a `DIGEST`, and another
  `DIGEST` about every 60 s while it is awake. No `KEEPALIVE`, and nothing else while we send nothing.
- **A link we close** reads `eof` on Android, which retries after about 10 s.
- **The advert comes back when an inbound link ends:** the Pixel saw the peer again and re-dialed four times
  in a row, 24 to 34 s after each close, the first after a link held for 100 s.
- **It is off while the link is up.** After each close the Pixel's dwell started again from zero. P4 confirmed
  why: see "What P4 found" below.
- **The advert interval is the kernel's default,** probably 1.28 s, close to Android's presence advert
  (`INTERVAL_HIGH`, about 1 s). BlueZ's `MinInterval` and `MaxInterval` are experimental, and `Experimental`
  is off in `/etc/bluetooth/main.conf`, so changing it would need root.

## Reading a GATT payload

In the `ios` profile the peer finds a node that advertises only the `0xFE30` UUID, as an iPhone does, by reading
the payload from its GATT characteristic (ADR 2026-09.xzpt), and its advert sets `FLAG_DIALS_GATT_PEERS`. The
`android` profile reads none and leaves the flag clear, as Android 2.7 and A1 do, so an iPhone meets it as it
meets Android.

- **A read** is `Device1.Connect`, then a wait for `ServicesResolved`, then `GetManagedObjects` to find the Knit
  characteristic in the device's `0xFE30` service, then `ReadValue`. The radio then drops the link, unless a
  channel uses it, for the reason bluetoothd's links are dropped below.
- **What BlueZ does with it** (BlueZ 5.72's `src/device.c`): `Connect` answers once the link is up, and
  `ServicesResolved` follows. A `Disconnect` while it is still connecting cancels it, which is how a read that
  runs out of time ends. `Connect` also makes a device permanent, and BlueZ stores it under
  `/var/lib/bluetooth/`, unless its address is private. Phones' addresses are, so reading an iPhone leaves
  nothing behind; reading another Linux peer, on a public address, leaves its entry under hci1.
- **The pacing** is `GattPayloads`' in `KnitMesh`: one device at a time, 12 s for each read. A failed read waits
  30 s, and a device that serves no payload waits ten minutes. A payload lasts until a dial to the device fails, a
  HELLO there names another node, or the device goes unheard for a minute of scanning while nothing links it (ADR
  2026-09.xzpt, amended 2026-09-29), and BlueZ forgetting the device drops it too. The log says `bluez read <node id>
  on PSM <psm> from dev_… over GATT`, or why a read failed, and `bluez forgetting the GATT payload of dev_…` with why.
- **Not yet seen on the air.** The fake BlueZ's GATT servers are the only ones this reader has met. Nothing in
  range serves the payload until the Mac (P7) or the iPhone (P8). A read makes hci1 a central for a second or
  two, and whether this controller keeps advertising meanwhile is unmeasured.

## Android's scan cadence decides how long a test waits

A settled Pixel 3 on battery with its screen off ran Knit's scan only every 17 minutes or so (`dumpsys
bluetooth_manager`), so it can take that long to notice a new peer. Awake, it found the peer within 15 s. With
the session's go-ahead for the phone, wake it (`input keyevent KEYCODE_WAKEUP`) and send the bridge's
`…debug.HEAL` to start a scan.

## Running it

`knit-peer` is the `Mesh` this port's app will run, on the BlueZ radio (ADR 2026-09.5ftc). Build it with
`swift build --product knit-peer`; the binary is `.build/out/Products/Debug-linux-x86_64/knit-peer`.

| Command | Does |
| --- | --- |
| `knit-peer run [--radio-profile android\|ios] [--instance NAME] [--name NAME] [--log debug\|info\|warning\|off]` | runs the node; JSON lines in on stdin, out on stdout, logs on stderr |
| `knit-peer run … --rssi-floor -100 --receive-mtu 247 --send-mtu 8192` | development knobs: a promotion floor below Android's −90 dBm, the L2CAP receive MTU (65535 by default), and the largest SDU written (247 by default, never above what the peer offers or 8192) |
| `knit-peer run … --never-sight NODE_ID[,NODE_ID…] --no-gatt-payload` | test switches, BlueZ only: never report those nodes as sighted, so the peer never dials them and admits their dials unsighted; and, in the `ios` profile, serve the doorbell without the payload characteristic, so a phone that reads payloads (A3) files the peer as a stranger and never sights it |
| `knit-peer scan [--seconds 20] [--advertise android\|ios]` | lists the Knit nodes in range, never dialing, and links a node that advertises only the UUID just long enough to read its payload; `--advertise` also shows the advert |
| `knit-peer keygen [--above NODE_ID] [--below NODE_ID] [--instance NAME]` | keeps a new identity whose node id sorts inside the window |

- **Every command checks the adapter first.** `--adapter` defaults to `hci1` and `--adapter-address` to the Edimax's
  address. An adapter with another address stops the peer before anything opens.
- **`hci0` is refused by name** unless `--shared-adapter` is given, with its address
  (`--adapter hci0 --adapter-address A0:00:00:00:00:01 --shared-adapter`). A shared adapter keeps the links other
  devices hold: at start the peer drops only links on an adapter of its own, and it only ever drops links it made.
  `.agents/rules/devices.md` says when it may be used.
- **State** lives in `~/.local/state/knit-peer/<instance>/`: `identity` (0600) and `profile.json`, which keeps the
  profile version and publish stamp across restarts. Custody, peers and messages live in memory.
- **Control lines** are JSON objects with a `cmd`, and an optional `tag` that the reply echoes. `KnitControl`
  holds the protocol, and a debug build of the app speaks it too, over USB (ADR 2026-09.kwa8):
  `status` (with `fileRecords`, the FILE records discarded so far; `footprint`, the size of each table the mesh
  keeps in memory; and `router`, what the router has admitted, relayed and refused), `peers` (names, aliases and
  safety numbers), `links` (links and sightings), `room` (`text`),
  `dm` (`to`, `text`), `accept` (`conv`), `name` (`name`, `status`, `openToChat`), `deny-link` and
  `allow-link` (`peer`), `digest` (live custody ids and their fingerprint), `custody` (every live frame),
  `messages` (`conv`, `limit`), `stop` and `start` (the mesh, as Settings' Stop and Start do), and `quit` (the
  peer exits; the app's bridge only closes the connection).
- **Events** are `ready` (with `radioProfile`, and `host` and `version` from the app), `link` (`up` true or false), `profile`, `message` (with `request` for a stranger's
  first DM), `sent`, `delivered` and `radio` (`state`: `on`, `off`, `unauthorized` or `unsupported`).
- **Log lines** carry `ms`, the wall-clock time, so they line up with a phone's logcat.

`scripts/interop.py` runs checklist L against one phone through knit-next's debug bridge: `check` in either
dial order (`--blank-name` for alias parity, `--expect-avatar` for FILE records, `--radio-profile ios` for the
A1 group), `refusal` for the `ios` profile against Android 2.7 only (every A1 build admits the dialer it expects
refused), `replace` for A1's stale-link rule, `soak`, `relay`, `android-rings` for companion change A4, and
`android-reads`, companion change A3's device gate. It needs the session's go-ahead for the phone
(`.agents/rules/devices.md`). It keeps the run on that phone:

- **Before the peer starts**, it scans and picks a node id that no other phone in range dials.
- **Once the peer is up**, it refuses every other phone with `deny-link`, and then any node it sights later
  (`soak`, `relay`).

`soak` is MVP item 11's hour against that phone: room posts both ways, 20 a minute in all. With `--extras`, the
phone also reacts, types, sends DMs and posts photos, and the peer DMs back. It checks why each link ended, every
post's arrival and tick, the footprint against the caps, memory through the second half, and custody at the end,
and writes `.build/interop-soak/<start>/`.

`relay` rehearses MVP item 7's line with a second peer on `hci0`, which needs its own go-ahead; `iphone-relay` runs
the line itself, with the iPhone in the middle ("What the iPhone showed"). The line is the
phone, then peer A on `hci1` in the `ios` profile standing in for the iPhone, then peer B on `hci0`, which refuses
the phone. Both peers sort above every phone, and A above B, so A dials the phone and B and nobody dials either.
Posts and DMs go both ways across A, and the three custody sets must converge.

`android-rings` is `iphone-rings` the other way round: Android rings the doorbell of a peer whose HELLO asks for it,
which is companion change A4 (knit-next `c3191717`, its ADR 2026-09.dqvb). The phone must run a debug build that
has it, and the first step checks that before the peer starts. A debug build logs a `bt state`
line every minute, and only an A4 build's counts `doorbells=` and `rings=`, so a line without them ends the run.
The peer then runs on `hci1` in the `ios` profile. Its GATT application serves a doorbell that counts rings
(`status.rung`), and its HELLO carries `CAP_DOORBELL`. `--link` picks whose link it is:

- **`dialed`**, the default, needs A3 too, and a `bt state` line with `gattPayloads=` shows it. The peer's id sorts
  below the phone's, so the phone reads its payload and dials it, and the ring tests a link Android dialed, whose
  capabilities came from the peer's HELLO reply. A phone with the flag set is waited for; one with it clear would be
  dialed by the peer as well, so then the peer runs with `--never-sight` for the phone.
- **`accepted`** is the link A4 rang before A3. The peer serves its doorbell without the payload
  (`--no-gatt-payload`), so an A3 phone takes it for a stranger and never sights it, and its id sorts above the
  phone's, so it dials the phone whatever the phone's flag.

The run checks five things in turn:

1. The phone logs `bt doorbell found <peer>` and rings the peer for its link-up frames.
2. The back-fill drains, and custody converges within `--converge-timeout` (600 s). A phone with knit-next's ADR
   2026-09.g64k sends each sender's key ahead of their backlog, so the fresh peer keeps all of it. It kept no key
   proofs before database v16, so frames from senders it pinned before its upgrade may stay behind until they
   expire. Those are allowed, and counted, as long as the peer holds nothing the phone lacks and dropped them
   for want of a key. The step also reports how many keys the phone served meanwhile, to anyone.
3. A room post from the phone, sent through its debug bridge, rings the peer again, and so does a DM. Android rings
   as it queues a frame, not as it writes it, so the run waits for 6 s with no ring, sends, and wants a ring
   within 8 s. That ring is the post's, even while the post itself waits in the link's queue.
4. The phone logs `bt ring <peer>`.
5. Neither side drops the link.

Last, the post and the DM must each reach the peer within `--arrival-timeout` (600 s) of being sent, and the step
reports how long each took. On `hci1` that can be minutes, behind the digests the phone queued during the back-fill
("Why the frames were late").

`android-reads` is companion change A3's device gate (knit-next ADR 2026-09.kwq2, merged in `f3f9cb9d`). The phone
runs an A3 debug build, whose `bt state` line counts `gattPayloads=` and `gattReads=`; the first step checks it. The
peer runs on `hci1` in the `ios` profile, serving its payload and its doorbell, and `--order` puts its id on one side
of the phone's:

- **`peer-below`:** the phone logs `bt gatt read <address> → <peer>`, dials the peer (`bt connect ok`), finds its
  doorbell on that link and rings it for the link-up frames. The peer must never dial the phone. A phone with
  `FLAG_DIALS_GATT_PEERS` set is waited for of the peer's own accord, and the run checks that it was. With the flag
  clear the peer would sight the phone, dial it, and refuse the phone's dial as one it makes itself, so the peer then
  runs with `--never-sight` for the phone: it holds its dials and admits the phone's unsighted.
- **`peer-above`:** the phone reads the payload and never logs `bt initiating to <peer>`; the peer dials, and the
  phone logs `bt accepted client <peer> (Admit, sighted=true)`, a sighting only the read can have given it. The peer
  refuses the phone until the phone has logged the read, or its dial could land first and be admitted unsighted.

In both orders every `bt gatt read` names a node without service data, never an Android phone the scan heard, and the
link must hold. The run reports the first link's time from the peer's start, MVP item 2's measure.

`android-forgets` shows each of the payload lifetime's forget rules firing once on the phone, through its `bt gatt
forget <address> (dial|hello <node>|quiet)` lines (ADR 2026-09.xzpt, amended 2026-09-29). Every peer on `hci1` has the
adapter's address, so each new identity is a node taking a reused address. In order: a peer below the phone is read,
linked and stopped, and the phone's redial fails (`dial`); the run then waits 30 s for the stack's own connect to
lapse. A peer above the phone is read and stopped, and nothing advertises for a minute of the phone's scanning
(`quiet`, which on a floored scan can take minutes). A peer above is read and stopped, and a new identity above it
dials in at once (`hello`, on a link the phone accepted). A peer below is read, linked and stopped, and a new identity
below it answers the phone's redial on the same PSM (`hello`, in the reply to the phone's dial).

`scripts/soak.py` is the other way round: a night against every Knit phone in range, driving none of them, so it
needs no go-ahead for a phone. The peer takes a node id above every phone's and dials them all, since this adapter
cannot be a central and a peripheral at once. It then sends traffic by phase, the way knit-next's lab soak does:

- **shakeout:** MVP item 11's hour, at 6 posts a minute.
- **sparse:** a post every few minutes.
- **dark:** only a burst or a round of DMs every hour or two, so the phones can doze.
- **mixed:** a last hour of steady posts.

Its posts carry knit-next's audit keys (`soak …` and `burst …`), so that repo's `.private/scripts/soak/cleanup.sh`
can purge them from the fleet afterwards; running it drives every phone. `status` and `report` read a run's
directory while it runs, and `report` checks it against item 11: crashes, why each link ended, custody, the
footprint, memory, and tick and DM delivery by phase.

## What P4 found

Measured on 2026-09-25 against the Pixel 3, less than a metre from the dongle, with three other Knit phones
in range.

- **bluetoothd keeps a link after the channel closes.** On every LE connection bluetoothd attaches its own
  GATT client and reads the peer's services, and that holds the ACL up after every L2CAP channel on it has
  closed. A link from spike (e) was still up hours later. While one is held, the adapter stays a peripheral,
  and this controller cannot advertise connectable while it is one. `Roles` lacks `central-peripheral`, and
  `RegisterAdvertisement` fails with `org.bluez.Error.Failed`. The Pixel's dials then end in the controller
  with HCI status 0x02, cancelled before our advert was ever heard (its `dumpsys bluetooth_manager` snoop
  summary). So the radio asks BlueZ to disconnect a device once its last channel closes, when the plane goes
  down, and at start for any link left from before. With that, the phone-dials order passed 12 of 12 twice.
- **The Pixel advertises quietly.** Knit asks for `TX_POWER_MEDIUM`, and the Pixel's controller picks −11 dBm, so
  the dongle hears it at −84 to −88 dBm while the Pixel hears the dongle at −55. A scan hears it only 3 to 10
  times in 30 s. Other BLE devices nearby come through 20 to 44 times in 20 s, and restarting discovery
  changed nothing. When the peer must dial the Pixel, promotion (12 s of dwell at −90 dBm or better) took up
  to nine minutes.
- **A link the peer dials times out in 420 ms.** The Pixel's HCI log shows every link at a 45 ms interval, the
  2M PHY and 251-byte packets. The supervision timeout differs: 5 s when the Pixel dials, 420 ms when hci1
  does. 420 ms is the kernel's default for connections it makes (`le_supv_timeout`, 0x2a). A Pixel busy
  with three other links misses that much, and the link ends in `ETIMEDOUT`, often within a minute. Only root
  can change it, per adapter and until the dongle is replugged: `sudo scripts/hci1-supervision.sh` writes 500
  (units of 10 ms) to `/sys/kernel/debug/bluetooth/hci1/supervision_timeout` once it has checked the adapter's
  address, and `scripts/hci1-supervision.sh --udev-rule` prints a rule that does it on every plug-in. No normal
  user can read the value back (`btmgmt` hangs, debugfs is root's). With it at 5 s,
  the peer-dials order passed 12 of 12, and the Pixel's log showed the link at 5000 ms. Without it, the
  phone-dials order is the reliable one. `interop.py` loosens the peer's promotion floor to −100 dBm, a
  development aid that nothing may depend on, so that the peer dials a quiet phone at all.
- **Back-fill is slow.** The Pixel sends its custody, 45 to 90 frames, at 0.5 to 0.8 KB/s, one record per write,
  in either dial order and at a 247 or a 65535 receive MTU alike: about two writes a second whatever their
  size. knit-next does not pace it, and the link parameters above are sound, so the Pixel's own stack is the
  limit. A post made meanwhile queues behind it and arrives about 10 s late. Posts made once custody has
  converged arrived in 1.3 to 2.9 s, within the MVP's 5 s.
- **The kernel binds to any address.** An LE socket binds and even listens on `00:00:00:00:00:01`, an address no
  adapter has. The BlueZ address check is therefore the only thing that keeps the peer on its own adapter,
  and no test opens a Bluetooth socket.
- **adb over the network goes stale** while the phone sleeps: `adb shell` hangs or returns nothing although
  `adb devices` lists it. `interop.py` reconnects that one serial and retries once.
- **A corrupted stream,** twice, both with the peer dialing: once a record with tag 0 after an `ETIMEDOUT`
  redial, and once a single 65,535-byte read, the whole receive MTU, starting `00 00 00 58`, after 79 s of
  quiet. Android never writes more than 8 KiB, so the kernel handed up a bogus SDU, apparently from a lost SDU
  boundary. The link manager drops the link on it, as Android does, and custody re-syncs after the redial.
  The short supervision timeout above is the likely trigger; the radio logs every read at debug level
  (`bluez chN read …`) to confirm it.
- **The `ios` profile re-registered its advert on every custody change.** The digest cue moves with each frame
  back-fill brings in, and the radio re-registered the advert each time, although neither the UUID-only advert
  nor the GATT value (cue zeroed) changes with it. The kernel logged `Unexpected advertising set terminated
  event` on `hci1` every second or two. The radio now re-registers only for bytes that reach the air.
- **bluetoothd on this machine is degraded.** Since 02:17 on 2026-09-25 it has logged `Unable to register device
  interface` for most newly found devices, about 14,000 times by evening; the log does not say which adapter
  found them. The peer still works, since the phones' device objects already exist. A restart of bluetoothd
  probably clears it, but it would also drop `hci0`'s live connections, so that is the maintainer's call.

## What A1 showed

Run on 2026-09-25 against the Pixel 3, first on the reviewed branch of companion change A1 and then on knit-next
`main` once it merged as `05dc2be1` (knit-next ADR 2026-09.shzv), the peer in the `ios` profile, so the Pixel never
sights it.

- **Android 2.7 refuses, as expected.** In 5 minutes the peer dialed the Pixel 5 times from below its id; 2 dials
  connected, and the Pixel closed each right after the HELLO. 3 never connected, the usual cost of the peer
  dialing.
- **A1 admits in both orders.** The Pixel logs `bt accepted client <id> (Admit, sighted=false)`. From below its
  id the checklist passed 14 of 14 and 13 of 13, and from above it 13 of 13, on the branch. On `main` it passed
  13 of 13 in each order.
- **A1 replaces a stale link.** `interop.py replace` links one peer, freezes it (the kernel keeps its channel
  open, so the Pixel's link goes quiet), then dials from a second process with the same identity. The Pixel
  logs `Replace, sighted=false` and no link-down for the replaced link, and the new link carries posts both
  ways in 1.5 to 4.9 s.
- **`main` holds a link 30 s before it replaces it.** A second dial 11.8 s and 22.4 s into the hold was refused
  (`bt refused client <id> (sighted=false heldAgeMs=…)`), and one 31 to 34 s in replaced the link. `interop.py
  replace` shows the two in turn: the refused process does what the radio always does when its last channel on a
  device closes and disconnects the phone, which ends the shared ACL and the first link with it, so the trial
  links again before the replacement.
- **The rig's weak spot is the shared ACL.** Two peer processes share one ACL to the phone, and in two of the runs
  on `main` the new link ended from this host 40 s after the replacement, with nothing in bluetoothd's log. In
  another, both processes crashed at once, when a write to their log file failed and `FileHandle.write(_: Data)`
  trapped (a CI container had just exited on this 98 % full disk); knit-peer now drops a line it cannot write.
  None of this is A1's: the replaced link's end never took the new link down.
- **The Moto G admits in both orders too.** It runs a TrebleDroid GSI (Android 14, LineageOS's stack) and logs
  `Admit, sighted=false` from below and above its id, and the two A1 phones still link to each other as before.
- **The Moto G loses what the peer sends it.** In 3 of 3 full checks with the default SDUs (up to 8192 bytes) the
  profile arrived and nothing after it did: no room post, no DM, no tick, and `unknown record type 0` when the
  link ended, so its reader had lost its place in the stream early on. With `--send-mtu 247` the same check
  delivered everything. Short probes at 512 to 8192 bytes, without the check's long back-fill, delivered their
  post every time, one of them with a bad record at close. The suspect is its stack reassembling a many-packet
  SDU while it is itself sending hard; not proven. The Pixel 3 takes 8192-byte SDUs throughout. Android reads
  the channel as a stream, so the radio now writes SDUs of 247 bytes by default.
- **A third phone's frames wait out the SeenSet.** The Moto G's back-fill carries the Pixel's frames ahead of the
  Pixel's profile, so a fresh peer drops them for want of the key (57 in one run), parks 16, and marks all seen;
  41 stayed unconverged through each check. Android's router marks a frame seen before it verifies it too
  (`MeshRouter.handleInbound`), so both platforms converged only after the 10 minutes. knit-next's fix (its ADR
  2026-09.9xuu, branch `fix/custody-converge`) serves profiles first and parks a whole custody quota per
  sender, and this port mirrors both (`CustodySync.missing`, `PendingInbound`).
- **A replaced link is not a new neighbour to Android,** so the Pixel does not push its profile again. The
  second process, holding no keys, gets the Pixel's frames by back-fill before the Pixel's profile, drops them
  (77 in one run, 16 parked), and marks them seen, so custody converges only after the SeenSet's 10 minutes.
  An iPhone that keeps its peers' keys will not see this.
- **Two traps in the rig.** A frozen process still holds its advert and GATT application in bluetoothd, and
  bluetoothd ended the whole ACL about a minute later, so the trial kills the frozen process once the phone
  has replaced its link. Two processes with one identity must publish the same profile frame, or the phone
  holds a copy the second never carries, so the second copies the first's state after the first is up.


## What the soak found

The first run of `scripts/soak.py`, 05:24 to 13:32 on 2026-09-26, against the Pixel 7, the Pixel 9, the Moto G
and the Pixel 3, with the peer dialing all four. It ran the shakeout, sparse and dark phases and was stopped before
the mixed hour. The run's directory is `.build/soak/20260926-0523/`.

- **Against MVP item 11:**
  - **Crashes:** none. The peer ran 8.1 hours without a restart.
  - **Growth:** none. Memory rose from 33.5 to 40.9 MB in the first hour, then held at 41.0 to 41.9 MB for seven.
    Open files stayed at 14 to 18. Custody peaked at 583 and fell to 441 as the room posts reached their 6 h
    TTL. The SeenSet held 2,603 ids, under its 4,096 cap. The other tables stayed flat, and no frame was
    parked.
  - **Delivery:** all 422 room posts were ticked, and all 36 DMs were delivered, 9 to each phone.
  - **Frames Android sends:** the peer discarded 14 FILE records without dropping a link.
  - **Link drops:** our side ended 1 of 213 links, on the bad read below.
  - **Not covered:** the phones posted nothing, since the run drives none of them. The room traffic went one way
    (the 145 posts received were back-fill), and `interop.py soak` is still the test for both ways.
- **bluetoothd cut 127 links: phones rotate their address.** BlueZ removes a device it has not heard for
  `TemporaryTimeout` (30 s by default), and removing a connected device disconnects it. Every advert restarts the
  timer, connected or not (5.72's `device_update_last_seen`). So when a phone moves to a new private address, the
  link on the old one is cut 30 s after its last advert. The socket reads `ECONNABORTED` (HCI reason 0x16,
  terminated by the local host), a whole-second GLib tick after the silence. Each of the 127 came 29.5 to 32 s
  after its address went quiet. No D-Bus call prevents it: `btd_device_set_temporary` ignores private addresses,
  so `Connect` and `Pair` cannot keep the device. `TemporaryTimeout = 0` in `/etc/bluetooth/main.conf` does. The
  maintainer set it the same day; below is what it took. The iPhone does not have this problem; it is this rig's
  BlueZ.
- **`TemporaryTimeout = 0` has to sit under `[General]`.** Appended at the end of `main.conf`, it lands in
  `[AdvMon]`, and bluetoothd logs `Unknown key TemporaryTimeout for group AdvMon` at start and keeps 30 s. That
  cost the first relay trial its link to the Pixel, cut 30.16 s after the Pixel's old address went quiet.
- **With it, nothing forgets a device, and the desktop's applet power-cycled both adapters.** bluetoothd kept every
  address every phone and every passing device rotated through: 124 objects on `hci0` and 114 on `hci1` within
  25 minutes. `blueman-applet` adds a D-Bus match rule per device. At 14:37:29 it hit the system bus's 2,048 match
  rules and then its 1,024 pending replies. A second later `blueman-mechanism` started and both adapters powered
  off for 25 s, which dropped every link on both, the maintainer's own included. So the radio now forgets quiet
  devices itself (`BlueZDevice.isStale`):
  - it forgets a device 60 s after it was last heard;
  - never one with a link, a channel or a GATT read in progress;
  - never one that is paired, bonded or trusted;
  - on a shared adapter, only a device that appeared after the peer started.
- **The rest of the drops were the radio's.**
  - **77 supervision timeouts,** most of them on the Pixel 7 once its signal fell to −93 dBm and below.
  - **4 unexplained `ECONNABORTED`s,** also on the Pixel 7 near the edge of range, with no silence and no
    disconnect from us or bluetoothd before them. Probably the dongle's controller ending a weak link and
    reporting it as a local disconnect; only btmon, which needs root, would show it.
  - **1 close from the phone.**
  - **Share of the run each link was up:** the Pixel 3 96 %, the Moto G 94 %, the Pixel 7 85 %, and the Pixel 9
    13 %. The Pixel 9 is a daily driver: it reset most dials with `ECONNRESET`, and was often out of range.
- **The 65,535-byte read came back at a 5 s supervision timeout.** Once in 213 links, after two minutes of quiet, a
  Pixel 3 channel read the whole receive MTU starting `00 00 00 d0`, and the link manager dropped the link on its
  tag-0 record. P4 blamed the 420 ms timeout; that no longer explains it.
- **The Pixel 3's own drops are a controller matter.** Its HCI log shows hci1's links at a 5 s supervision
  timeout, and it ends them with 0x28, "Instant Passed": holding six links, it misses the dongle's link-layer
  update instant.
- **Ticks wait for back-fill, and churn.** The phones carried about 300 custody frames, so a post's tick took four
  minutes at the start. After that the median was 6 to 8 s, and 90 % came within about 20 s. The dark phase's
  bursts, landing on dozing phones, had a median of 10 s and a 95th percentile of 52 s. All of it is above the
  MVP's 5 s. Each link lasted a few minutes before bluetoothd cut it, and every new link starts with a digest
  exchange, so the churn is the likely cause; a run with `TemporaryTimeout = 0` and the radio forgetting quiet
  devices would tell.
- **Two traps in the rig.** The lab phones' custody holds the profiles of about 33 old knit-peer identities, so the
  peer pins them all. The first trial DMed every pinned peer, which put 66 DMs into the lab's custody for a day;
  the driver now DMs only the phones in range. And while the peer is linked, its `android` advert is re-registered
  with every custody change. The dongle then answers each change with an advertising-set-terminated event, and
  the kernel logs `Unexpected advertising set terminated event`, about every 1.5 s in the shakeout. It did no
  visible harm.

## What the relay line showed

Three runs of `interop.py relay` on 2026-09-26, against the Pixel 3 on a debug build of knit-next `aeba5382`. Peer
A was on `hci1` in the `ios` profile, and peer B on `hci0`, shared, in the `android` profile.

- **Run 3 passed all 16 steps.**
  - **Links:** A linked B in 19.7 s and the Pixel in 6.7 s. B never linked the Pixel, and no link dropped.
  - **Custody:** A matched the Pixel's 451 frames in 195 s, and B matched A at once. At the end, B matched the
    Pixel at 455 frames. A relayed 455 frames and refused none.
  - **Group frames are left out.** Android serves a group frame only to the group's members
    (`ForwardSync.onDigest`), as `CustodySync.missing` does, so the check leaves out the Pixel's one group frame.
  - **Room:** B's post was on the Pixel in 2.4 s. The Pixel's took 22.6 s to reach B (below).
  - **DMs:** the Pixel's first DM reached B as a message request in 2.4 s, and B's reply was delivered in 1.7 s.
    The Pixel's DM was ticked.
- **Runs 1 and 2 failed on the rig, not the line.** Run 1 lost its link to the ignored `TemporaryTimeout`, and run
  2 lost both links to blueman's power cycle ("What the soak found"). Run 2 also held one frame, `fOqw…`, on A and
  B for seven minutes that the Pixel did not hold. It never came back, and the check now names the frames that
  differ (the peer's `custody` command and the phone's `STORE` rows).
- **A post right after a back-fill waits behind stale digests.** Android re-offers its whole custody id list, 13.6 KB
  at 451 ids, to every neighbour every 60 s (`reofferToNeighborsPeriodically`), on the link's single write queue.
  Behind the three-minute back-fill, three of them queued. Once the back-fill drained, they went out back to back
  at the Pixel's 1.6 KB/s, and the Pixel's post, written at 15:00:51, came after them. For knit-next: a queued
  DIGEST could give way to the newest one rather than wait beside it.
- **Back-fill ran at 2.3 frames a second in run 3,** and under one a second in runs 1 and 2. Android sends every
  missing frame in one loop, so the rate is its link's.

## What the both-ways soak showed

`interop.py soak --extras` against the Pixel 3, 15:07 to 16:12 on 2026-09-26. It ran MVP item 11's hour at 20
room posts a minute, both sides together, and 1,123 posts in all. Every 15 posts the phone also reacted, sent a
typing cue, posted a photo, or traded a DM with the peer, 74 extras in all. The run's directory is
`.build/interop-soak/20260926-1507/`. It passed 11 of 12 checks.

- **Against item 11:**
  - **Crashes:** none.
  - **Links:** the peer ended none. One link lasted 57 minutes, and then two ended a minute apart. On each, the
    Pixel logged reason 0x28, "Instant Passed", and the peer read `ETIMEDOUT` 5 s later. Both times the link had
    carried almost nothing for about 70 s before it ended. The Pixel was holding three links, as in the night
    soak.
  - **Growth:** custody peaked at 669 frames and the SeenSet at 2,250. Memory held at 38 MB and peaked at 40.6.
  - **What Android sends:** every photo's caption and every DM arrived. The three FILE records the photos carried
    were discarded without dropping the link. The peer refused no frame.
- **Delivery:** all 561 of the phone's posts arrived, with a median of 1.5 s and a 90th percentile of 14 s. 426 of
  them arrived within 5 s. The peer ticked every one, the ones the Pixel served again after a drop included.
  Custody matched at the end, at 668 frames.
- **21 of the peer's 562 posts were never ticked.** They are the ones sent in the stall before the first drop and
  across both drops. All 21 reached the Pixel, which shows them. The ticks were lost with the links: Android sends
  a room tick once, straight onto the author's link, and does not send it again once that link dies. For
  knit-next: a post can stay at ✓ though it was delivered.
- **Late phones are refused in time.** Two phones came into range during the hour, and the peer refused each
  before either could dial.

## What the iPhone showed

An iPhone 12 on iOS 27.0, from 2026-09-26, installed from this machine with `xtool dev run --usb` and read with
`idevicesyslog -p Knit` (`.agents/context/toolchain.md`). It links the Linux peer and the lab's Android phones
within seconds of opening. Two app bugs and two rig limits stood in the way first.

- **The app stopped at the Bluetooth grant.** xtool links every target as a static archive, and the linker left
  out `BLECore+Delegates.o`, which only the Objective-C runtime calls into. iOS then refuses a central manager
  with a restore identifier and no `willRestoreState`. The `Knit` target links with `-ObjC`, and
  `scripts/check.sh xcode` checks the app for the delegate methods.
- **A relaunch to restore Bluetooth found nobody.** iOS relaunches Knit in the background after an install, and
  the restored central already reports a scan, so the radio never asked for one. A scan for every advert finds
  nothing in the background, and still nothing once Knit comes to the front. `BLERadio.foregrounded()` starts
  the scan again whenever the scene becomes active.
- **bluetoothd asks the iPhone to pair.** Once a link is up, bluetoothd's battery plugin reads the iPhone's
  Battery Service, which iOS guards with encryption, so bluetoothd raises the link's security. The prompt comes
  back on every link, and left unanswered, the kernel's SMP timeout drops the link 30 s later.
  `sudo scripts/bluetoothd-no-battery.sh` runs bluetoothd without the plugin, for the whole machine, and
  `--undo` puts it back. Android phones serve no such service, so only the rig hits this.
- **The iPhone's writes to `hci1` stop after the HELLO.** `btmon` shows the kernel offering MTU 65535, MPS 23
  and 2,850 credits. The iPhone sends 16 or 17 fragments of 19 bytes in all, then nothing, with thousands of
  credits left. Its second message never completes, so the peer never reads it, though the link stays up and
  the peer's own traffic reaches the iPhone. A 247-byte receive MTU let one more message through and then
  stalled the same way. On `hci0` the iPhone's writes arrive at once, in 2,570-byte SDUs, so iPhone runs put
  the peer there with `--shared-adapter`. The iPhone's writes to the Android phones flow either way.

On `hci0`, with the peer refusing the Android phones so that it can advertise:

- **The room works both ways.** A post from the peer reached the iPhone, and the iPhone's tick marked it
  delivered: the peer reports a tick as a `delivered` event. The iPhone's posts reached the peer.
- **Profiles cross.** The peer pinned the iPhone's profile, which has no name, under its alias, and the
  iPhone's profile screen showed the peer's safety number.
- **DMs work both ways.** The iPhone's first DM reached the peer as a message request 84 ms after it was
  sent. Once the peer accepted it, the peer's sealed reply was opened on the iPhone and receipted as delivered,
  and the iPhone showed its own DM as delivered too. With the room, that passes MVP items 3 to 5 against the
  peer.
- **Back-fill is heavy.** Each side served the other hundreds of frames from the lab phones' old runs, and the
  iPhone's digest, about 20 KB, goes out again every minute.

On `hci1` again, for MVP item 8, with the peer in `--radio-profile ios`, so both sides find each other only
through the GATT payload:

- **Both orders link.** With the peer's id below the iPhone's, the iPhone read the peer's payload in 3 s and
  dialed it. With a `keygen --above` identity, the peer read the iPhone's payload, the first a real device has
  served it, waited out the 12 s dwell and dialed. `hci1`'s 23-byte fragments still stall the iPhone's writes
  after the HELLO, so item 8 checks the link here and `hci0` checks the traffic.
- **A backgrounded iPhone takes a dial.** iOS relaunched Knit in the background after an install, and the peer,
  which already knew the iPhone's address and PSM, dialed it; the link held when Knit came to the front. That
  is not background discovery, since the peer never had to find it.
- **The iPhone read its peer's payload again every 5 to 30 s.** After each read it drops the connection it made,
  CoreBluetooth reports a disconnect, and the handler forgot the payload as if a dial had failed. It forgets now
  only when a dial did.
- **A new identity at an old address draws a stale dial.** Swapping the peer's identity on `hci1` left the old
  node's sighting at the same address, so the iPhone dialed the old id once more, and the new peer refused it,
  until the sighting's 90 s linger ran out.

Against the Pixel 3 (Knit 2.7.0, a debug build with A1), with the iPhone dialing it, the peer refusing it, and
the other lab phones linked to both. The iPhone side was read from its database through a read-only container
mount (`.agents/context/commands.md`):

- **Profiles and safety numbers match.** The Pixel 3 renders the nameless iPhone as RegallyCosmicDune, the alias
  the iPhone shows for itself, and the iPhone shows Pixel3 by name. Both profile screens show the same safety
  number.
- **The room works both ways.** A post from the Pixel 3 reached the iPhone 1.4 s after it was sent. A post from
  the iPhone reached the Pixel 3 in under 3.1 s, a bound set by polling once a second, and the iPhone marked it
  delivered. Both posts showed ✓✓. The Pixel 3's tick can't be pinned on the iPhone, since the other phones tick
  too.
- **DMs work both ways, with the Android phone asking first.** The Pixel 3's first DM reached the iPhone in
  1.5 s and waited there as a request. The iPhone receipted it at once, and the Pixel 3 showed it delivered.
  After Accept, the iPhone's reply and the Pixel 3's answer each crossed in under 1.7 s, and each showed
  delivered on its sender. Only the recipient can sign a DM receipt, so Android takes the iPhone's receipts. An
  iPhone's first DM arriving as a request on Android is left untested, because this pair's conversation now
  exists; the peer covers the iPhone's side of that.

Through the debug bridge (ADR 2026-09.kwa8), `interop.py iphone` ran against the Pixel 3 at 23:02 with nobody at
either phone, and 13 of its 15 steps passed:

- **Items 3 to 6 hold unattended.** The iPhone pinned Pixel3 with the safety number the Pixel 3 shows. Posts and
  DMs crossed both ways in about 1.5 s, and each was ticked; the iPhone's DM carried the Pixel 3's own receipt.
  With the iPhone's mesh stopped, the Pixel 3 wrote a room post and a DM. The iPhone linked again 13.8 s after
  `start`, and both arrived 1.1 s after the link. Custody converged at 505 ids.
- **The direct link failed until the radio restarted.** Every dial to the Pixel 3 hung at connect for the 12 s
  watchdog, four times in two minutes, while three other phones linked in seconds, and the messages above went
  through them. After `stop` and `start` the Pixel 3 linked on the first dial. The cause was state restoration:
  when iOS relaunched Knit after the install, `willRestoreState` cancelled the connections the old process held
  before the central was powered on, and CoreBluetooth refused all 16 (`API MISUSE: can only accept this
  command while in the powered on state`), so they stayed up.
- **Fixed, and all 15 steps pass.** The radio now keeps restored connections aside and cancels them once the
  central reports `poweredOn` (`BLECore.dropRestored()`). After the next install iOS handed back 6, the radio
  dropped all 6 with no refusal, and at 23:12 the iPhone linked the Pixel 3 directly in 16 s. Posts and DMs
  crossed both ways in 1.0 to 1.5 s, the offline pair arrived 0.6 s after the link, and custody converged at
  519 ids.

`interop.py iphone-relay` ran MVP item 7's line twice from 23:28 with nobody at either phone, and both runs
passed all 17 steps. The line ran from the Pixel 3 through the iPhone to the peer, which ran on a shared `hci0`
in the `android` profile. The peer refused every node but the iPhone. The iPhone refused every node but the Pixel 3
and the peer, then let the rest link again at the end.

- **Links:** the iPhone dialed the peer about 23 s after it started. The peer linked nothing else, and neither
  side dropped a link.
- **Custody:** the iPhone already matched the Pixel 3, at 523 and 530 frames. It back-filled each new peer in
  40 s, and at the end all three sets matched, at 528 and 533.
- **The room:** the Pixel 3's post reached the peer in about 1.5 s, and the peer's reached the Pixel 3 in 1.4 and
  2.1 s.
- **DMs:** the Pixel 3's first DM reached the peer as a message request in 1.8 and 2.6 s. After Accept, the peer's
  reply was delivered in about 1.5 s, and the Pixel 3's DM showed delivered.
- **The iPhone's router relayed 8 and 9 frames** and refused none. These counts cover only frames the router
  passed on. The back-fill goes by digest, so it isn't counted.

`interop.py iphone-wake` ran MVP item 9's wake test from 23:46, with the maintainer locking the iPhone and later
unlocking it. Knit was open and linked to the Pixel 3 and three other lab phones. Every link was one the iPhone had
dialed, so a link to the iPhone's own channel is still untested. That run predates A4, so the Pixel 3 rang nothing.
Against a build with A4, `--expect-wakes` asks for what `--sender peer` does: every DM delivered within its minute,
and `bt ring` lines for the iPhone in the phone's log. Without it the run checks only the fallback.

- **L2CAP data does not wake a suspended Knit.** The iPhone locked at 23:47:14. bluetoothd released its last
  assertion on Knit at 23:47:23, and runningboardd suspended Knit that second. The Pixel 3 then sent a DM every
  minute for ten minutes. None was delivered in that window. runningboardd never resumed Knit, and bluetoothd took
  no new assertion on it, though four phones' traffic kept arriving on its links.
- **The link held.** The Pixel 3 listed the iPhone as linked at every look, 3 s apart, and logged no link down
  for it. The iPhone stayed locked for 14 minutes in all.
- **Everything waited on the link.** The maintainer opened Knit at 00:01:08, and all ten DMs arrived within the
  same second. They came from the link's buffer, not from custody. The Pixel 3 then showed all ten delivered.
  Knit posted a notification for each DM with Knit in front, each replacing the last, and none while the iPhone
  was locked.
- **The bridge did not come back.** iOS shuts an app's sockets when it suspends it (runningboardd logs
  `Shutdown sockets (SVC)`) and tells the listener nothing. The listener still looked ready, so the foreground
  left it alone. The arrival times above come from Knit's database, through the read-only mount, which also
  had to be mounted again. The bridge now makes a new listener at every foreground.

A doorbell then woke it (ADR 2026-09.khjj). Knit gained a writable characteristic beside its GATT payload, and a
peer on a shared `hci0` linked the locked iPhone, with the doorbell rung by hand through BlueZ's `WriteValue`:

- **A ring wakes Knit, and a DM with no ring still waits.** In each round the peer sent a DM and waited 40 s, and
  none was delivered. After a write without response the DM was delivered 4.8 s later, and after a write with a
  response 7.7 s later. At each ring runningboardd showed bluetoothd resuming Knit, which then ran for 9 s. In the
  third round a lab phone's link to the iPhone dropped first, and that disconnect woke Knit just the same.
- **BlueZ had not read the iPhone's services 13 s after the iPhone dialed the peer,** so its doorbell had no D-Bus
  object yet. BlueZ does read them on its own, and the devices left over from earlier runs held them, so the
  radio waits for the read. `Device1.Connect` is no way to hurry it: for the iPhone it took BlueZ's BR/EDR path,
  hung until the D-Bus timeout, and the link dropped and came back meanwhile.
- **bluetoothd refuses new devices.** Its journal shows `Unable to register device interface` for devices passing
  by, 709 times since midnight. The iPhone's own device registered, but a new phone might not. Restarting
  bluetoothd clears it, and would drop `hci0`'s live connections, so that is the maintainer's call.

With the ringing built into `LinkManager` and the Linux peer, `interop.py iphone-wake --sender peer` passed all 9
steps from 00:55, which is MVP item 9 against a sender that rings:

- **Every DM woke Knit.** For ten minutes locked, the peer sent a DM a minute and rang after each. By Knit's own clock
  each DM arrived 0.1 to 0.5 s after it was sent, and the peer saw each delivered at its next look, 3 s later (6 s
  once). The system log shows the same cycle ten times: Knit suspended, resumed by a ring, a notification posted,
  and suspended again. The peer rang 16 times in all.
- **The first ring waited 42 s for BlueZ.** The link came up at 00:55:16, BlueZ read the iPhone's services at
  00:55:58, and the ring the peer had been holding went out the same second.
- **The link held,** and the bridge answered as soon as Knit was opened, after 17 minutes suspended.

Then the iPhone rang. `interop.py iphone-rings` passed all 6 steps at 01:49, with the peer on `hci1` in the `ios`
profile, whose GATT application serves a doorbell that counts rings. The peer's id sorted below the iPhone's, so the
iPhone read its payload and dialed it:

- **The iPhone rings the peers it dialed.** It dialed the peer in 22 s. It found the peer's doorbell and rang it at
  once for the frames it sent at link-up, and rang again after a room post. Its frames on that link stalled on
  `hci1`'s fragments as before, but a ring is a GATT write, not a frame on the link, so it arrived.
- **Android links cost one look each.** The iPhone looked for a doorbell once on each of its three Android links,
  found none, and did not look again. None of those links dropped.
- **The peer rang back** in the same second. BlueZ read the iPhone's services far sooner than on `hci0`.

`interop.py iphone-scan` is P8's scan-filter check. A debug build's scan probe (`scan-filter` over the bridge) makes
Knit scan for the `0xFE30` UUID alone, as a scan in the background must, and records each advert it matches. Two
peers advertised, each on its own adapter: the `android` profile on a shared `hci0`, whose advert carries `0xFE30`
only as service data, and the `ios` profile on `hci1`, which lists it as a UUID. The iPhone refused both, so it only
watched them. The check ran three times from 02:25. The second run was stopped early (below), and the first and
third passed 7 of 7:

- **A filtered scan matches Android's advert.** With Knit open, the filter matched the `android` peer about once a
  second and all five lab phones by their service data, and the `ios` peer by its UUID list. iOS matches a UUID in
  service data as it does a listed one, so Android needs no UUID list for an iPhone to find it.
- **A locked iPhone matches both, slowly.** With the iPhone locked and Knit suspended, each peer started
  advertising on its own. The `android` peer first matched 30 s after its radio came on in the first run and 120 s
  in the third, and the `ios` peer 41 s in the third. In the first run the `ios` peer went unmatched for all of its
  60 s, and matched only as the screen woke, which starts the scan again, so the third run gave each peer 150 s.
  The lab phones matched too, each time one took a new address.
- **Each match wakes Knit.** bluetoothd took an assertion on Knit to deliver a match, as it does for a ring, and
  Knit ran for about 10 s each time. With five Android phones in range, the third run matched 71 adverts in five
  minutes locked, and runningboardd resumed Knit 16 times: it ran for 74 % of the window, and 77 % in the first
  run. In item 9's wake test, with the unfiltered scan, Knit slept for 14 minutes.
- **So Knit keeps its scan unfiltered.** An unfiltered scan goes quiet in the background, which is what lets a
  locked iPhone sleep between rings. Background discovery works with a filter, but needs a design that bounds its
  wakes, such as filtering only while Knit has too few links, since a link's disconnect wakes Knit anyway.
- **The iPhone keeps a GATT payload for as long as Knit runs,** unless a dial to that peer fails. The second run
  gave the `ios` peer a new identity, and the iPhone went on naming `hci1` by the old one. It never dialed the peer
  to find out, since the peer's id is the larger and the peer dials. The check now keeps the `ios` peer's identity
  from run to run. Only a test gives an address a new identity. A peer whose PSM changed fails the dial, and its
  payload is read again.
- **The `ios` peer hides while it reads.** With Knit open, the `ios` peer kept trying to read the iPhone's own
  payload, and a read can take over 12 s. `hci1` does not advertise while it holds a connection, so the filter
  matched the peer 5 times in 30 s, against 30 in the first run. While the iPhone was locked its advert listed no
  UUID, and the peer read nothing.

Also found on the way:

- **200 notifications for one back-fill.** The first build posted one per message. Each conversation now keeps
  one notification that shows its newest message, as Android's does, and a newer one replaces it quietly while
  it still shows.
- **Launching needs a hand.** `xtool launch` fails on iOS 27 (`DebugserverClient.Error.unknown`), so someone
  opens Knit on the phone.

## What A4 showed

The Pixel 3 ran a debug build of knit-next `c3191717`, built from a clean worktree and installed on 2026-09-27.
`interop.py android-rings` ran three times against it from 03:57, with the peer on `hci1` in the `ios` profile. The
third run passed 9 of 9, after the first two had shown what the run should measure:

- **Android rings the peer that asks.** In every run the Pixel looked up the peer's doorbell over the link's own
  connection and found it 4 s after the link came up, with no failed lookups. It rang once for its link-up frames,
  and once more 5 s later as that burst ended.
- **A ring comes as a frame is queued.** In the third run the post rang the peer 1.4 s after the bridge was told to
  send it, and the DM 1.5 s after, each after at least 6 s with no ring. Neither frame had reached the peer when
  the run ended.
- **The back-fill never drained.** The link carried about 0.5 KB/s for eight minutes, `hci1`'s rate, as in P4. The
  Pixel's custody is larger now, and 81 of its frames are relayed chats and receipts from senders whose keys a fresh
  peer lacks. The peer cannot verify them, so it keeps none, and the Pixel pushes them again while the link lasts,
  about every 10 minutes, since `LinkCrossings` holds back a frame that crossed the link inside that window. The
  first run timed the post's arrival and the second waited seven minutes for custody to converge; both failed on
  that queue. So the run checks rings, which do not wait for it, and only reports arrivals. knit-next found why
  (its ADR 2026-09.g64k). The Pixel held no signed copy of those senders' profiles: custody had lost them to the
  quota and the TTL, and its reinstall had emptied the only other copy, in memory. So neither it nor anyone else
  could send the key, and the peer's `keyreq` went unanswered. Android now keeps the frame each pin came from and
  sends that key ahead of a backlog, and this port mirrors it (`custody.md`, "Key recovery"). Senders the Pixel
  pinned before its upgrade stay stranded until their frames expire.
- **The link held** in all three runs, on both sides.

Then the iPhone, with a build whose HELLO carries `CAP_DOORBELL`. `interop.py iphone-wake --sender phone
--expect-wakes` passed 10 of 10 from 04:24, with the maintainer locking the iPhone and later opening Knit. It is MVP
item 9 against Android:

- **Every DM woke Knit.** The Pixel rang the iPhone within a second of each DM of the ten locked minutes. By Knit's
  database each DM arrived 0.1 to 0.3 s after it was sent, and the Pixel showed each delivered 3.2 s after it sent
  it. Knit posted a notification for each, without an error.
- **The iPhone heard 12 rings from the Pixel,** one for each DM and two for other frames. The Pixel's log held only
  the last 7 by the end, since its buffer turns over in about ten minutes, so `phone-rang` counts what is left.
  Another lab phone rang the iPhone too, so it runs an A4 build.
- **The first link attempt failed first.** Knit was opened at 04:20 and dialed the Pixel only at 04:21:53. That
  link, and the next at 04:22:05, each dropped within 2 s: the iPhone read a record whose tag was 87 (`W`), then one
  whose tag was 54 (`6`). Both bytes are printable, so the iPhone had lost its place in the stream, and it dropped
  the link, as it must. Each time the Pixel was still discovering the iPhone's GATT services for the doorbell,
  1 to 2 s into the link. The third link found the doorbell 4.5 s in and held for the whole run. The run's link
  check gave up at 120 s, before that third link, and the second run found it up at once.
- **The cause is not known yet.** It is new with A4 on both sides, and in every iPhone log kept this session these
  are the only two bad records. The iPhone's own streams are ruled out for the first drop, when no other channel
  was open, but not for the second, when one opened at the same moment.

A Bluetooth snoop log on the Pixel came next, from 04:45, turned on in Developer options and off again afterwards.
It did not catch a drop:

- **The drops did not come back.** The iPhone relinked 19 times, once after the Pixel's Bluetooth restarted and 18
  times through the bridge's `stop` and `start`, and no link dropped. What those links lacked was the first ones'
  load: the Pixel's avatar and a large back-fill, sent while its lookup ran.
- **The Pixel keeps each L2CAP frame whole.** The snoop kept only the last 11 of those link-ups, since Android
  keeps two files and the older one began at 11:24. On each, the Pixel discovered the iPhone's GATT services while
  L2CAP traffic ran, and no L2CAP frame on any connection, sent or received, was cut into by another. So the Pixel
  interleaving GATT packets into a frame is unlikely, though not ruled out under the first links' load.
- **Stop and Start left the iPhone without its GATT service.** In the first 8 relinks the Pixel found no doorbell.
  `stop()` removed the service, and the next start served it only if its value had changed, which it does only
  with the PSM, and iOS handed back PSM 192 every time. So after Settings' Stop and Start an iPhone served neither
  its payload nor its doorbell: no peer that reads GATT payloads could find it, and Android could not wake it.
  `stop()` now forgets the served value. With that build the Pixel found the doorbell on all 10 relinks.
- **The next drop explains itself.** A bad record's warning now says where in the stream it came, shows its first
  32 bytes as hex and as text, names the last four records' tags and sizes with the end of the last payload, and
  lists the last six reads (`LinkTrace`). A record that overran its length, a read that went missing and bytes
  that were never a record each look different there, on the iPhone and the peer alike.

## What the carrier's kept keys showed

knit-next's ADR 2026-09.g64k keeps the signed profile each pin came from and sends a sender's key ahead of their
backlog. The Pixel 3 ran it from 13:22 on 2026-09-27, as a debug build of that uncommitted work on
`fix/carrier-keeps-profile`, with A4 and database v16. Its custody still held about 200 room posts from knit-next's
own test sender, whose profile its quota had evicted. `interop.py android-rings` passed 10 of 10 from 14:46, with the
new custody step:

- **Custody converged.** The peer linked at 14:47:10, and 501 s later it held every one of the Pixel's 796 live ids,
  with nothing left behind. The Pixel served 2 keys during that time, to this peer or another neighbour. The
  morning's runs never converged, since 81 frames stayed unreadable.
- **The rings came on a quiet link.** The post rang the peer 3.5 s after it was sent, and the DM 1.6 s after, each
  after 6 s with no ring. Both phones held the link.
- **Neither frame had arrived when the run ended,** 12 s after the post and 3 s after the DM. `arrivals` looked
  once and did not wait. Both were late, not lost ("Why the frames were late").

## Why the frames were late

Six more runs against the Pixel 3 that afternoon found the frames late, not lost. One was a probe of five posts,
and five were `android-rings` runs as its `arrivals` step learned to wait. Every frame given long enough arrived: all
five posts, and the post and DM of the one run that waited 900 s. Three runs waited only 60 s and saw nothing, and
one failed on a helper bug before it looked. A frame the phone sends waits in its link's queue, and on `hci1` the
queue can hold minutes:

- **Android's link writer is first in, first out.** Frames and digests share one queue (`FramedLink.outbound`);
  only a file's chunks let frames in between them. The port's writer is the same (`Radio.write` writes "after
  everything written before").
- **A back-fill goes into it all at once.** A newcomer's digest reply queues every frame it lacks, about 780 and
  500 KB here, which `hci1` carries in about 9 minutes at 0.5 to 2.5 KB/s.
- **Digests pile up behind it.** Every 60 s the phone queues another digest of its whole custody, about 20 KB for 780
  ids, however much is already queued, and nothing merges or drops a stale one. After a 9-minute back-fill, about
  ten of them stand in line.
- **So a frame sent as custody matches waits behind them all.** In the run with a 900 s wait, the post and the DM
  took 393 s and 383 s. In the 6.5 minutes the post waited, ten digests landed where the phone makes one a minute,
  about 204 KB of the 211 KB the link carried. The link then dropped (`errno 110`) as that queue emptied, and the
  phone served both frames again from custody within 30 s of the next link.
- **Once the queue has emptied, frames are quick.** The probe sent its posts after custody had taken 10 minutes to
  match, and they took 1.0 to 6.3 s. The slowest landed 0.1 s after a digest it had queued behind.

Two runs had their first link drop with `errno 110`, 3 and 16 minutes in, and the peer dialed again within 20 s. In
three runs custody never matched within 600 s: once after such a drop, and twice because the other lab phones were
sending DMs, which queued behind the same digests. The custody step allows only frames the peer dropped for want of a
key, so live traffic like that fails it.

On a link between two phones, which carries tens of KB/s, the same queue drains in seconds, which is why only
`hci1` shows it. Both platforms now keep at most one digest waiting per link, and a newer one takes its place
(knit-next's ADR 2026-09.tjfb, this port's ADR 2026-09.3ch7). With that build on the Pixel 3, `android-rings`
passed all ten steps with a 900 s wait, and the post and DM took 133 s and 124 s. What was left was the
Android socket's own buffer, at least 120 KB: six digests already written there went out 33 to 37 s apart, and
the post landed right behind the sixth. The slot cannot reach bytes the socket holds.


## What the one-digest slot showed

This port's slot (ADR 2026-09.3ch7, at `5a05071`) ran on both radios on 2026-09-27, with the Pixel 3 on
knit-next `11b91371`, which has knit-next's own slot.

- **The Linux peer on `hci1`:** `interop.py android-rings --peer-log debug --arrival-timeout 900` passed 10 of
  10 from 19:26 to 19:40. Custody converged at 742 ids in 522 s, and the post and DM arrived in 142 s and 133
  s. The peer never replaced a digest: the Pixel was back-filling it, so its own queue never backed up.
- **The iPhone 12, from `xtool dev run --usb`:** `interop.py iphone` passed 14 of 15 at 20:46 against the
  Pixel 3. Posts and DMs crossed both ways in about 1.6 s, and the offline pair arrived 3.4 to 3.6 s after the
  link. Its links waited for socket space 44 times in 373 writes, once with 6,641 bytes waiting, about one
  digest, and each wait drained. It never replaced a digest either, since links between phones drain too fast.
  The replacement itself is checked by `LinkOutboxTests` and `BlueZOutboxTests`.
- **`custody-converges` can fail at a sender's quota for up to 10 minutes.** It failed at 180 s on two frames
  the Pixel 3 wrote itself. The iPhone held a receipt of the Pixel's, from 13:37, that the Pixel had lost. The
  Pixel held its own profile, which it signs again and stores at every link-up, and the iPhone lacked it. The
  Pixel held 195 of its own frames against the per-sender quota of 200, so, as knit-next reads it, each of
  those arrivals was the oldest row and was evicted as it came in. The id stays in the 10-minute seen set, and
  `LinkCrossings` holds a frame off a link for 10 minutes after it crosses, so neither copy came back until
  both windows passed. At 21:46 both phones held the same 570 ids: the returned receipt had evicted the
  Pixel's older profile. knit-next found no rule on either side that drops such a frame for good. Wait out 11
  minutes, or flap the link, before reading this step as a failure.

## What the Mac showed (checklist M)

`knit-peer` runs on the Mac Mini on KnitBLE's CoreBluetooth radio, the iPhone's own, in the `ios` profile
(ADR 2026-09.vcdk). `scripts/mac-peer.sh` builds and signs it and runs it in the desktop session; macOS asked for
Bluetooth once, at the Mac, on 2026-09-28.

- **First light:** left alone for a minute with nobody refused, it linked three lab phones, learned 20 peers,
  converged custody on 366 frames, discarded 9 FILE records, and heard 12 doorbell rings from the A4 phones.
- **`interop.py check --mac` against the Pixel 3** (A1 and A4), 2026-09-28:
  - with the Mac's id below the phone's, 13 of 13: the link in 31 s, names both ways, custody converged on 369 ids
    in 21 s, the room both ways (1.7 s to the Mac), a DM from the phone arriving as a request, a DM from the Mac
    delivered and ticked, and the back-fill in 37 s;
  - with its id above, blank-named, 14 of 14: the same, plus alias parity (each side's alias the other shows) and
    the phone's three avatar FILE records discarded with the link kept.
- **The Mac always dialed.** Android before A3 cannot find an `ios`-profile peer, so in both id orders the Mac's
  central dialed the phone, and A1 admitted it unsighted. That was the same shape as the iPhone's links. An A3 phone
  with the flag set reads the Mac's payload, dials it when the Mac sorts below it, and the Mac waits.
- **`interop.py soak --mac --extras`, one hour against the Pixel 3** (12:19 to 13:24), passed 11 of 12. The link
  held all hour with no ending on either side, and the Mac's memory stayed at 12.5 MB. All 505 of the phone's
  posts arrived, 504 within 5 s (median 1.6 s), and all 506 of the Mac's were ticked (median 1.1 s). The extras
  crossed too: reactions, typing cues, 13 DMs each way, and 13 photos, whose FILE records were discarded. The
  footprint stayed bounded, and custody peaked at 501. The miss was `custody-converges-at-end`, at 303 s, on
  two of the Pixel's own frames at its sender quota, the case the one-digest slot's run describes: allow 11
  minutes.
- **The soak's guard had been dead since `7c77354`,** which gave `_keep_to` two more parameters and left `soak`
  calling it with the old three. The thread died at start, so a node the first scan missed could join a soak.
  It is fixed, and this soak refused the iPhone as it appeared.

## What the iPhone's soak showed

`interop.py iphone-soak --peer --extras` ran MVP item 11 on the iPhone 12 on 2026-09-28, 14:45 to 15:46, on a
build with the memory headroom in `status`. It used `iphone-relay`'s line: the Pixel 3, then the iPhone, then a peer
on a shared `hci0` that refused the Pixel. So every post crossed both of the iPhone's links, at 20 a minute each,
relays included. The three authors took turns, 976 posts in all. Every 15 posts came an extra: 10 reactions,
10 typing cues and 9 photos from the phone, and 9 DMs each way between the iPhone and each of the other two. The run's
directory is `.build/interop-iphone-soak/20260928-1422/`. It passed 21 of 27 checks, and none of the 6 misses was
the iPhone's.

- **Against item 11:**
  - **Crashes:** none. The bridge stayed open all hour, and the phone held no crash or jetsam report from Knit.
  - **Links:** neither the iPhone nor the peer ended one. The one ending came before the hour: at 14:23:14 the Pixel
    read EOF on all three of its links within 10 ms, the iPhone's among them. The iPhone dialed it again, and it was
    back 24 s later. Both links then held for the whole hour.
  - **Growth:** the iPhone's SeenSet peaked at 1,772 and its custody at 500. Its memory headroom fell 1.5 MB through
    the second half, to 2,129,278 kB. `LinkCrossings` filled at 1,024 entries per link after 35 minutes, and relays
    went on at the same pace.
  - **What Android sends:** the iPhone took reactions, typing cues and photo captions without dropping a link. No
    FILE record reached it this time, though the Mac's hour that morning discarded some from the same photo; why
    is not known. The peer started empty, so it took its keys from the iPhone's back-fill.
- **Delivery:** every post reached the other two nodes, 325 of the phone's at the peer through the iPhone. The
  phone's posts reached the iPhone in a median of 1.6 s, 323 of 327 within 5 s, and the peer through it in 1.8 s.
  Every post of the iPhone's and of the peer's was ticked, in a median of 0.1 s. Every DM was delivered, both ways,
  with each partner.
- **The misses:**
  - **Custody never matched** (four checks). The iPhone carried a DM the Pixel had sent two hours earlier, which the
    Pixel and the peer had both purged. The recipient's receipt reached the iPhone before the DM did, and a receipt
    that arrives first purges nothing, on either platform (`.agents/context/custody.md`). By the end the Pixel held
    one such DM too, a DM from the peer to the iPhone. The iPhone receipted it at once and relayed it after the
    jitter, so the Pixel had the receipt first. Every other id matched.
  - **The phone showed only the peer's last few minutes** (`peer-posts-on-phone`). The Pixel took and screened every
    post, but its room was over Android's 2,000-row cap from the day's runs, and its sweep trims the room every
    10 minutes, oldest first, starting with strangers. The peer was a stranger to it and the iPhone was not, so every
    post of the peer's from before the last sweep, at 15:41, was gone. The run now has the phone DM the peer before the
    hour, which makes the peer someone the phone talks to.
  - **`extras` asked for FILE records,** which the phone decides whether to send. The run now reports them instead.

## What the iPhone's reboot showed

`interop.py iphone-reboot --restart` ran MVP item 1's second half on the iPhone 12 on 2026-09-28. It reads the
debug bridge's `storage` reply, which says where the launch found the identity and the database, and how the
launch went.

- **Storage:** the Keychain item is `cku` (`…AfterFirstUnlockThisDeviceOnly`). The database's directory,
  `knit.sqlite`, `-wal` and `-shm` are all `NSFileProtectionCompleteUntilFirstUserAuthentication`, and the directory
  is out of backups. That settles the protection class P5 left for the iPhone.
- **Relaunch:** passes. Swiping Knit away in the app switcher did not close it, twice: the same process answered
  afterwards. Why is not known. `devicectl device process launch --terminate-existing` did close it, and the new process
  had the same node id, read its keys and skipped onboarding. The script's relaunch step asks for the swipe and
  waits up to `--unlock-wait` for a new process; a devicectl relaunch satisfies it too.
- **Reboot:** passes. `idevicediagnostics restart` took the phone off USB 10 s later, and it was back 36 s after
  that. Unlocked and opened, Knit had the same node id, remembered onboarding, read its keys, kept the protection
  class, and ran the mesh.
- **iOS relaunched Knit on its own** 20.5 s after the boot, before the phone was back on USB, and before anyone
  touched it. Bluetooth state restoration is the likely cause, though the run cannot tell it from app prewarming.
- **The phone had no passcode then,** so it counted as unlocked from boot, and the early launch read the Keychain at
  once. `ideviceinfo -k PasswordProtected` cannot show whether a passcode is set: it reads `true` while the phone is
  locked and `false` once it is unlocked.

`iphone-reboot --restart --skip-relaunch` ran again at 22:24 that evening, with a passcode set, and passed 12 of 12
(`.build/interop-iphone-reboot/20260928-2224.jsonl`).

- **The USB pairing did not survive the passcode.** lockdownd answered `Invalid HostID` until `idevicepair pair` ran
  again and someone accepted the Trust prompt on the phone.
- **The phone stays off USB until the first unlock.** It left usbmuxd's list 9 s after the restart and stayed off
  for the 4.5 minutes it sat locked, which fits USB Restricted Mode. It came back when it was unlocked. The script
  used to wait for USB before it started the locked window. It now counts `--locked` from when the phone leaves
  USB, asks for the unlock, and keeps Knit closed for `--closed` seconds before asking for it.
- **iOS did not launch Knit before the first unlock.** Without a passcode it relaunched Knit 20.5 s after the boot.
  With one, Knit stayed closed for the 4.5 locked minutes, and iOS launched it in the background 8.4 s after the
  unlock. That launch read the Keychain at once (`readyBy` is `launch`, `waited` is null), and Knit was running
  65 s before anyone opened it. It had the same node id, remembered onboarding, read its keys, kept the protection
  class, and ran the mesh.
- **The waiting launch has still not run on a phone.** Its guard is tested: `IdentityKeys.load(from:)` throws rather
  than making new keys when the store is locked (`IdentityTests`). The `Launch` stages after it are not: waiting,
  then starting from protected data, the foreground or Retry. If iOS ever launches Knit before the first unlock,
  the `storage` reply's `launch` records which one started it.

## What the iPhone's status line showed

MVP item 10 ran by hand on the iPhone 12 on 2026-09-28, 22:36 to 22:49, with three lab phones in range. Someone read
each line off the screen. The debug bridge's `status`, polled about every 5 s, gave the mesh's running state and its
links, and `idevicesyslog` gave each state the radio reported (`ble on`, `off` or `unauthorized`). Every check passed.

- **The count:** the line read "Connected to 3 nearby devices" while the bridge reported 3 links.
- **Stop and Start in Settings:** Stop mesh took the links to 0, and the chat list showed the stopped line with its
  Start button. After Start mesh the first link was back in 12 s and all three in 16 s.
- **Bluetooth off,** switched in the Settings app: the radio reported `off`, the line said Bluetooth is off, and the
  mesh stayed marked running with no links. Switched back on, two links were back in 25 s and the third in 46 s,
  in the same process.
- **Bluetooth not allowed,** switched off for Knit in Privacy & Security: iOS ended Knit's process. Opened again, the
  radio reported `unauthorized`, and the line asked for Bluetooth with a Settings button that opened Knit's page
  there. Allowing it on that page ended the process too. The next launch reported `on` and had all three links back
  in 21 s.
- **The unsupported device** is not on hand, so `test:ios:simulator` checks its line through `-seedDemo -demoRadio
  unsupported`, with the other two refusals, and asserts that all three lines differ (pipeline 821).
- **The bridge seems to answer one client at a time.** The watcher's poll got no answer while a `status` sent by hand
  was open.

## What both id orders showed

`interop.py iphone` and the new `interop.py iphone-peer` ran MVP items 2 to 6 on the iPhone 12 on 2026-09-29 from
01:21, with nobody at either phone. Every earlier iPhone run used the Pixel 3, whose id sorts above the iPhone's, so
only one order had been checked. The Pixel 7's sorts below it. The iPhone heard the Pixel 7 at −96 dBm, under the
−90 dBm floor, and never dialed it until the phone was moved closer. The runs are in `.build/interop-iphone/` and
`.build/interop-iphone-peer/`, and the link timings in `.build/interop-link-probe/`.

- **The Pixel 7, iPhone above: 20 of 20.** The pair had never talked. knit-next's bridge reports no request state,
  so the run reads the Requests screen through uiautomator: the iPhone's first DM was there, and the run tapped
  Accept. Replies then went both ways and were delivered. After a stop and a start, the link was back in 13.8 s.
  While the iPhone was stopped, each side wrote the other a post and a DM, and all four arrived 1.6 to 3.0 s after
  the link.
- **The Pixel 3, iPhone below: 17 of 17,** the same without the request, which this pair used up on 2026-09-26. The
  link was back in 16.7 s. The Pixel's offline pair reached the iPhone 0.7 s before that link, through a lab phone
  that linked first, and the iPhone's reached the Pixel 2.5 s after it.
- **The peer on a shared `hci0`, in both orders: 18 of 20 each.** Each run minted a fresh peer that refused every
  node but the iPhone. Names, aliases and safety numbers matched, posts and DMs crossed in under 0.1 s, and the
  iPhone's first DM arrived as a request. The offline four arrived 0.9 to 2.7 s after the link, which only their
  own link could carry. Both misses in each run were the stale DM below.
- **One stale DM kept custody apart.** The iPhone carries a DM the Pixel 3 sent `ux62sq…`, the Mac's peer, at 12:17
  on 2026-09-28, and the recipient's receipt for it, sent 1.5 s later. The iPhone took the receipt first, before
  the early-receipt fix, and holds both: it is the DM `iphone-soak` found. A fresh peer back-filled newest first
  also takes the receipt first, and with the fix it refuses the DM. The fix refuses such a DM on arrival and
  purges no copy already held, so the iPhone carries this one until it expires, at 12:17 on 2026-09-29. Until
  then, any custody check against the iPhone misses it.

Item 2's 30 s held for relinks to the phones, and not always for a first link:

- **Relinks after a start took 13.8 and 16.7 s to the phones, and 16.6, 20.7 and 38.7 s to the peer.** The last was
  a third `iphone-peer` run, after the fixes below, which passed 19 of 21 with the same two misses; its first link
  took 29.9 s.
- **A first link to a fresh peer took 14.7 to 54.7 s.** Of ten, three went past 30 s, in both orders. Every first
  dial succeeded within 0.7 to 1.6 s, so the time went before the dial.
- **The iPhone heard the peer's advert late and seldom.** Traced once a second, the iPhone first heard a new peer 3
  to 22 s after it started, at −48 to −58 dBm. Then it heard it every 3 to 5 s, once not for 10 s.
- **The advert's interval sets both delays.** With `hci0`'s interval set to 100 ms through debugfs, by hand and as
  root, the iPhone heard each of six fresh peers within 2 s and never went more than 1.7 s without one, and every
  first link came in 13.1 to 16.1 s, three in each order. Before, the peer advertised at the kernel's default, which
  could not be read without root. Android advertises about once a second (`INTERVAL_HIGH`, `BleAdvertiser.kt`), so a
  phone's first link should fall between the two.
- **Against the Pixel 7, two of five first links came within 30 s.** Its mesh was paused through the bridge until
  the iPhone forgot it, then resumed, five times, at −77 to −87 dBm: the links took 102.4, 28.2, 23.2, 37.2 and 73.3
  s. The iPhone first heard it 2 to 10 s after each resume, then with gaps of up to 15 s, which restarted the dwell
  in three of the five (`.build/interop-link-probe/*-phone`).
- **The iPhone dials a phone that has left.** The dwell counts from the first sighting until a later one shows a
  gap, so a departed phone stays promotable for the 90 s its sighting lingers. After each pause the iPhone dialed
  the silent Pixel two or three times, each dial timing out after 12 s, and its backoff reached 80 s. That held one
  dial until 72 s, 19 s after the dwell was met, and another until 98 s, after the first dial to the resumed phone
  also timed out, for a reason the log does not show. knit-next's `BlePresenceTracker` and `PromotionPolicy` have
  the same rule.
- **The dial waits for the next sighting.** `LinkManager` promotes on a sighting, a link event or a deadline, and no
  deadline marks a dwell running out, so a peer past its 12 s waits for the next advert heard from anyone. A gap
  over 8 s between sightings started the dwell again. Android's connect loop has the same rule.
- **Peers on `hci0` share one address.** The iPhone keeps a sighting for 90 s and redials it with backoff, so a peer
  started sooner is reached by a dial meant for the last identity, and its link time says nothing about item 2. The
  second `iphone-peer` run started 79 s after the first, so its 36.6 s is left out above. The scenario now waits for
  the iPhone to forget old peers (`iphone-forgot-old-peers`), and picks the peer's id so that as few phones as its
  order allows dial it and are refused.

`LinkManager` has since taken fixes for two of these (ADR 2026-09.6es2, amended 2026-09-29): it never dials a peer
quiet for more than 8 s, and it wakes when a candidate's dwell ends. Neither has been measured on the iPhone yet.
Neither helps a late first sighting, or a gap over 8 s that restarts the dwell.

## What A3's gate showed

`interop.py android-reads` ran on 2026-09-29 from 14:01 against flag-clear debug builds of knit-next `feat/gatt-peers`
(`7c16aae5`) on the Pixel 7 and the Pixel 3, with the peer on `hci1`. The runs are in `.build/interop-android-reads/`.

- **The reader and the dial work, on the Pixel 7.** Below the phone, the peer was read 7.1 s after it started, and the
  phone dialed it at 22.2 s, found its doorbell on that link and rang it, so the dialed link took `CAP_DOORBELL` from
  the HELLO reply. The peer never dialed, and the link held 60 s: 11 of 11. Above the phone, the read came at 10.1 s,
  the peer dialed, and the phone logged `bt accepted client … (Admit, sighted=true)`, having never dialed. The first
  link came at 18.9 s.
- **A failed first read costs 30 s.** One read failed at `connect`, waited out its retry, and that run's first link
  took 71 s. The dwell counts from the read's sighting, not the first UUID advert, so a first link takes at least the
  read, 12 s and the connect.
- **A phone keeps a payload for good at an address it never dials.** A payload goes only when a dial to its address
  fails, and a phone never dials a node above it. Every peer here has `hci1`'s public address, so after a run with a
  peer above a phone, that phone sighted each later peer as the old one, listed it in reach, and never read again.
  The Pixel 7 and the Pixel 3, which had read the Pixel 7's peers from across the room, both did, until Knit
  restarts. KnitBlueZ forgets a payload once BlueZ forgets a device unheard for 60 s, and so never meets this; KnitBLE
  and Android did. In the field it strands a public-address peer that comes back with a new identity. The maintainer
  made three forget rules shared law for both sides (ADR 2026-09.xzpt, amended 2026-09-29): a failed dial, a HELLO
  naming another node, and a minute of scanning without a sighting.
- **A dial outlived its watchdog.** The Pixel 7 redialed the departed peer, and its 12 s watchdog gave up, but the
  stack's connect lived on, brought up a link when the next peer advertised, and held it with no channel for eight
  minutes. This dongle cannot advertise while connected, so the phone never heard the next peer. The run now waits for
  the phone to forget the last peer before it starts (`phone-forgot-old-peers`).
- **A Linux central drops the link at 420 ms.** With the peer as central, after the doorbell lookup the Pixel's stack
  put back the link's first values, the kernel's 420 ms supervision timeout, and the link dropped 4 s later. The relink
  kept knit-next #102's 5 s. It is the walk test's 720 ms on a BlueZ central.

The gate ran again from 15:05 on knit-next `b7480e85`, still flag clear, with the payload lifetime's three forget rules,
freshly installed on both phones, and the peer built from this repo's `c7c25d5`:

| Phone | Order | Steps | Read at | First link at |
| --- | --- | --- | --- | --- |
| Pixel 7 (API 37) | peer below | 10 of 11 | 57.7 s | 73.2 s |
| Pixel 7 | peer above | 10 of 10 | 37.1 s | 43.1 s |
| Pixel 3 (API 31, the pre-33 read callback) | peer below | 11 of 11 | 13.2 s | 40.5 s |
| Pixel 3 | peer above | 10 of 10 | 98.8 s | 104.8 s |

- **Both phones read, dial and are dialed as A3 says.** Below the phone, it dialed, found the doorbell and rang it,
  and the peer never dialed. Above, the phone admitted the peer as a dialer it had sighted and never dialed. Every
  read named the peer, never an Android phone.
- **First reads fail often, and each costs 30 s.** Three of the four runs began with a failed read (`timeout@discover`
  twice, `connect` once), and the Pixel 3's second read failed too. That, not the dial, is where the long first links
  went.
- **The Pixel 7's one miss was the peer's own.** 58.8 s into the hold, the peer's channel read failed with errno 38,
  and the phone saw the link end at its 5 s supervision timeout. The same hold passed in every other run.
- **The Pixel 3 showed the 420 ms put-back again,** for half a second before knit-next #102's 5 s came back, and the
  link held.
- **Each forget rule fired, on the Pixel 7** (`android-forgets`): `quiet` at 15:22:20, once the address of a payload
  above the phone went unheard; `hello` on a link the phone accepted at 15:28:44, the dialer then admitted unsighted;
  `hello` in the reply to the phone's own dial at 15:29:58, the dial failing as HANDSHAKE; and `dial` at 15:40:12, a
  redial to the stopped peer that timed out.
- **The open case happened on the rig.** The first `android-forgets` began with a payload above the phone at `hci1`'s
  address, and its peer below the phone kept the address busy, so nothing forgot the payload and the phone never read
  the peer. The scenario now orders its stages so that a peer above the phone goes quiet before one below it starts.
- **The stray connection came back once,** after the phone redialed a stopped peer, and was dropped from `hci1`'s
  side. It predates A3 and has an order of its own.

## What A3's flag showed

knit-next `8a6d1a58` sets `FLAG_DIALS_GATT_PEERS` whenever the reader runs. From 16:04 on 2026-09-29 the lab's Pixel 7
and Pixel 3 ran debug builds of it, and the peer ran this repo's `8d9c62a`. Its scan read each phone's flags byte as
`0x03`, the side channel and the new bit.

| Run | Steps | First link at |
| --- | --- | --- |
| `android-reads`, Pixel 7, peer below | 10 of 11, then 11 of 11 on the rerun | 87.7 s, then 54.4 s |
| `android-reads`, Pixel 7, peer above | 11 of 11 | 207.9 s |
| `android-reads`, Pixel 3, peer below | 12 of 12 | 51.2 s |
| `android-reads`, Pixel 3, peer above | 8 of 11, then 11 of 11 on the rerun | 194.9 s, then 19.5 s |
| `iphone`, Pixel 3, iPhone below | 19 of 19 | 15.9 s, and 3.3 s after a restart |
| `iphone`, Pixel 7, iPhone above, moved within a metre | 19 of 19 | 10.5 s, and 13.8 s after a restart |
| `iphone-wake --sender phone --expect-wakes`, Pixel 3 | 10 of 10 | |

- **The flag works.** Below a flagged phone, the peer waited of its own accord and the phone dialed it, in both runs
  on each phone. The Pixel 3, above the iPhone, dialed the iPhone at link-up and again after a restart, and the
  iPhone, above the Pixel 7, dialed it both times.
- **A link Android dialed wakes the iPhone.** Locked for ten minutes, the iPhone took all ten of the Pixel 3's DMs
  3.2 to 3.8 s after each was sent, and the Pixel 3 logged ten rings. By Knit's database each DM arrived 0.1 to 0.3 s
  after it was sent. It is MVP item 9 on a link Android dialed, which only A3 can make.
- **Two misses were the rig's, and each passed on its rerun.** The Pixel 7's first link to a peer below it dropped
  three times, each a supervision timeout on the phone and errno 38 on the peer, which is `hci1`'s controller ending
  the link with a reason the kernel does not map. Each drop followed the phone moving the link to 50 ms with a
  peripheral latency of 5, and the rerun held through the same move, so the dongle as peripheral copes only sometimes.
  The Pixel 3 once never read the peer at all while its reader stood idle, then held a connection to `hci1` with no
  channel; dropped from `hci1`'s side, the rerun read it in 10.2 s. Its scanner history settled why: every 12 s
  window from 16:22 to 16:24 returned the three Android phones and never `hci1`, because `hci1` was not advertising.
  From 16:21:24, a second before the peer started, `hci1` held a central's connection to the Pixel 3's GATT server,
  and this dongle stops advertising while it holds any. The only thing on `hci1` then was `interop.py`'s pre-run
  `knit-peer scan`, which links any device BlueZ lists with the `0xFE30` UUID and no service data to read its
  payload, and BlueZ folds a phone's service-data UUID into that list. Its log was not kept, so the read is likely,
  not shown. `interop.py` now keeps the scan's log (`.build/interop-scan.log`), and `android-reads` checks that
  `hci1` holds no connection before its peer starts (`hci1-idle`).
- **The Pixel 7 needs to be near the iPhone.** At its usual place the iPhone heard it at −97 dBm, under the −90 dBm
  floor, and never dialed; within a metre it linked in 10.5 s.
- **The peer can be slow to dial a phone it may dial.** Above the Pixel 7, the peer's first dial came three minutes
  after the phone's read let it, while it waited to hear the phone's advert long enough; the peer's log does not name
  the device behind each advert, so the wait cannot be read closer.

## What the walk test showed

On 2026-09-29 from 03:48, the maintainer walked the Pixel 7 away from the iPhone 12 until it had no links left.
The iPhone stayed on this machine's USB, and the Pixel 7 had its Bluetooth snoop log on. The snoop, both Pixels'
logcats, the iPhone's log and a once-a-second record are in `.build/interop-walk/20260929-0348/`, and `btmon -r`
decodes the snoop.

- **The iPhone's link timed out.** It dropped at 03:53:28 with HCI reason 0x08, Connection Timeout, 0.73 s after
  the Pixel last heard the iPhone. The iPhone logged its channel ending, and the Pixel an EOF, within a second.
  Before the drop the iPhone heard the Pixel's advert at −81 to −92 dBm, and not at all in its last 34 s.
- **iOS sets a 720 ms supervision timeout.** The iPhone dialed, so it was the central. It opened the link at a
  30 ms interval, no latency and a 720 ms timeout, then moved it to LE 2M. Every link an Android phone dialed ran at
  a 5 s timeout, and the Pixel 3's moved to LE 2M too, so the radio mode is not the difference.
- **iOS took 5 s when the Pixel asked, and the Pixel's stack put 720 ms back.** When A4's GATT client began its
  discovery, Android's stack asked for a 10 to 20 ms interval and a 5 s timeout, and iOS granted 15 ms and 5 s.
  When discovery found the doorbell 2 s later, the stack asked for the link's first values, 30 ms and 720 ms, and
  got them. The next link-up went the same way (knit-next #102).
- **There was no Bluetooth link between the Pixels to compare.** Turning the snoop on restarted the Pixel 7's
  Bluetooth, and the Pixel 9 and Pixel 3 did not link to it again until after the walk. The Pixel 7 and Pixel 9
  stayed in touch through Wi-Fi Aware discovery, which the Diagnostics screen shows as a link. knit-next's bridge
  lists peers in reach as `reachable`, not links, so the Pixels' `bt state` lines in logcat are the record of their
  links.
