# The Linux peer (`knit-peer` and `KnitBlueZ`)

A headless Knit node on this machine's second Bluetooth adapter, for interop runs against Android phones
before there is an iPhone (P4). `.agents/specs/mvp.md` has what it must prove; `.agents/rules/devices.md` has
the rules for the radios and phones it touches.

## The adapter

- **`hci1` is an Edimax BT-8500** (USB `7392:c611`, Realtek RTL8761BU), public address `0A:BC:DE:00:00:A1`,
  named "linux-host #2". It has the central and peripheral roles, `LEAdvertisingManager1` with 4 advertising
  instances, and `GattManager1`.
- **`hci0` is the maintainer's.** The peer checks that `/org/bluez/hci1` has the address above before it does
  anything, and binds every socket to that address, so nothing it does can land on `hci0`.
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
| `knit-peer scan [--seconds 20] [--advertise android\|ios]` | lists the Knit nodes in range, never dialing; `--advertise` also shows the advert |
| `knit-peer keygen [--above NODE_ID] [--below NODE_ID] [--instance NAME]` | keeps a new identity whose node id sorts inside the window |

- **Every command checks the adapter first.** `--adapter` defaults to `hci1` and `--adapter-address` to the Edimax's
  address. `hci0` is refused by name, and an adapter with another address stops the peer before anything opens.
- **State** lives in `~/.local/state/knit-peer/<instance>/`: `identity` (0600) and `profile.json`, which keeps the
  profile version and publish stamp across restarts. Custody, peers and messages live in memory.
- **Control lines** are JSON objects with a `cmd`, and an optional `tag` that the reply echoes:
  `status` (with `fileRecords`, the FILE records discarded so far), `peers` (names, aliases and safety numbers), `links` (links and sightings), `room` (`text`),
  `dm` (`to`, `text`), `accept` (`conv`), `name` (`name`, `status`, `openToChat`), `deny-link` and
  `allow-link` (`peer`), `digest` (live custody ids and their fingerprint), `messages` (`conv`, `limit`) and
  `quit`.
- **Events** are `ready`, `link` (`up` true or false), `profile`, `message` (with `request` for a stranger's
  first DM), `sent` and `delivered`.
- **Log lines** carry `ms`, the wall-clock time, so they line up with a phone's logcat.

`scripts/interop.py` runs checklist L against one phone through knit-next's debug bridge: `check` in either
dial order (`--blank-name` for alias parity, `--expect-avatar` for FILE records, `--radio-profile ios` for the
A1 group), `refusal` for the `ios` profile against Android 2.7, `replace` for A1's stale-link rule, and `soak`.
It needs the session's go-ahead for the phone (`.agents/rules/devices.md`). It keeps the run on that phone:

- **Before the peer starts**, it scans and picks a node id that no other phone in range dials.
- **Once the peer is up**, it refuses every other phone with `deny-link`.

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
  (`MeshRouter.handleInbound`), so both platforms converge only after the 10 minutes.
- **A replaced link is not a new neighbour to Android,** so the Pixel does not push its profile again. The
  second process, holding no keys, gets the Pixel's frames by back-fill before the Pixel's profile, drops them
  (77 in one run, 16 parked), and marks them seen, so custody converges only after the SeenSet's 10 minutes.
  An iPhone that keeps its peers' keys will not see this.
- **Two traps in the rig.** A frozen process still holds its advert and GATT application in bluetoothd, and
  bluetoothd ended the whole ACL about a minute later, so the trial kills the frozen process once the phone
  has replaced its link. Two processes with one identity must publish the same profile frame, or the phone
  holds a copy the second never carries, so the second copies the first's state after the first is up.

