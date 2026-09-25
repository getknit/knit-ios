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
- **It is probably off while the link is up.** After each close the Pixel's dwell started again from zero,
  which fits the kernel re-enabling a connected advertising instance only at disconnect. Confirming it takes
  `sudo btmon -i hci1`, or a second phone looking for the peer while it is linked. Either way, KnitBlueZ
  registers its advertisement again after each inbound connection (hci1 has 4 instances), so the peer stays
  findable while it is linked, as an Android phone does.
- **The advert interval is the kernel's default,** probably 1.28 s, close to Android's presence advert
  (`INTERVAL_HIGH`, about 1 s). BlueZ's `MinInterval` and `MaxInterval` are experimental, and `Experimental`
  is off in `/etc/bluetooth/main.conf`, so changing it would need root.

## Android's scan cadence decides how long a test waits

A settled Pixel 3 on battery with its screen off ran Knit's scan only every 17 minutes or so (`dumpsys
bluetooth_manager`), so it can take that long to notice a new peer. Awake, it found the peer within 15 s. With
the session's go-ahead for the phone, wake it (`input keyevent KEYCODE_WAKEUP`) and send the bridge's
`…debug.HEAL` to start a scan.
