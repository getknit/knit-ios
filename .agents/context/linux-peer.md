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
| `knit-peer scan [--seconds 20] [--advertise android\|ios]` | lists the Knit nodes in range, never dialing; `--advertise` also shows the advert |
| `knit-peer keygen [--above NODE_ID] [--below NODE_ID] [--instance NAME]` | keeps a new identity whose node id sorts inside the window |

- **Every command checks the adapter first.** `--adapter` defaults to `hci1` and `--adapter-address` to the Edimax's
  address. `hci0` is refused by name, and an adapter with another address stops the peer before anything opens.
- **State** lives in `~/.local/state/knit-peer/<instance>/`: `identity` (0600) and `profile.json`, which keeps the
  profile version and publish stamp across restarts. Custody, peers and messages live in memory.
- **Control lines** are JSON objects with a `cmd`, and an optional `tag` that the reply echoes:
  `status`, `peers` (names, aliases and safety numbers), `links` (links and sightings), `room` (`text`),
  `dm` (`to`, `text`), `accept` (`conv`), `name` (`name`, `status`, `openToChat`), `deny-link` and
  `allow-link` (`peer`), `digest` (live custody ids and their fingerprint), `messages` (`conv`, `limit`) and
  `quit`.
- **Events** are `ready`, `link` (`up` true or false), `profile`, `message` (with `request` for a stranger's
  first DM), `sent` and `delivered`.
- **Log lines** carry `ms`, the wall-clock time, so they line up with a phone's logcat.

`scripts/interop.py` runs checklist L against one phone through knit-next's debug bridge: `check` in either
dial order, `refusal` for the `ios` profile against Android 2.7, and `soak`. It needs the session's go-ahead
for the phone (`.agents/rules/devices.md`). It keeps the run on that phone:

- **Before the peer starts**, it scans and picks a node id that no other phone in range dials.
- **Once the peer is up**, it refuses every other phone with `deny-link`.

## What P4 found

Measured on 2026-09-25 against the Pixel 3, with three other Knit phones in range.

- **No advertising while a phone is linked.** `Roles` on hci1 is `central` and `peripheral`, without
  `central-peripheral`. While any phone is connected to the peer, `RegisterAdvertisement` fails with
  `org.bluez.Error.Failed`, and the advert that was up is silent until the link closes. So one phone dialing
  in, even one refused at its HELLO, hides the peer from every other phone. The radio keeps retrying every 5 s.
- **Phones are heard rarely.** A scan hears each busy phone (three links and Wi-Fi Aware) only 2 to 10 times
  in 30 s, though Android advertises once a second, while other BLE devices nearby come through 20 to 44
  times in 20 s. Restarting discovery every 1 or 3 s changed nothing, so it was taken out. When the peer
  dials, promotion's 12 s dwell with gaps under 8 s can take a minute or more.
- **Back-fill is slow on a weak link.** At −84 dBm the Pixel sent its custody, about 45 frames, at roughly
  1 KB/s, one record per write. A post it makes meanwhile queues behind that and arrives about 10 s late.
  Posts made once custody has converged arrive within the MVP's 5 s.
- **The kernel binds to any address.** An LE socket binds and even listens on `00:00:00:00:00:01`, an address no
  adapter has. The BlueZ address check is therefore the only thing that keeps the peer on its own adapter,
  and no test opens a Bluetooth socket.
- **adb over the network goes stale** while the phone sleeps: `adb shell` hangs although `adb devices` lists it.
  `interop.py` reconnects that one serial and retries once.
- **One corrupted stream,** once in six runs: a record with tag 0 after the link had dropped with `ETIMEDOUT` and
  redialed. The radio logs every read at debug level (`bluez chN read …`), for the next time it happens.

