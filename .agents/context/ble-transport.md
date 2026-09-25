# Bluetooth LE transport

How knit-next's `mesh/bluetooth/` and `mesh/link/` behave at the pinned commit, and what that means for an
iPhone. The iPhone's own design decisions are ADRs; this file is the Android ground they stand on.

## No GATT on the mesh plane

Android uses no services, characteristics, notifications or MTU exchange. Each phone is both roles at
once:

- **Peripheral:** a connectable advert and an L2CAP server (`listenUsingInsecureL2capChannel`).
- **Central:** a scanner and an L2CAP client (`createInsecureL2capChannel(psm)`).

Channels are LE credit-based and insecure: no pairing, no bonding, no link encryption. CoreBluetooth's
equivalents are `publishL2CAPChannel(withEncryption: false)` and `CBPeripheral.openL2CAPChannel(_:)`.

## The advert

Legacy advertising (`ADV_IND`, connectable and scannable), about one second apart, medium power, 1M PHY.
There is no local name, no UUID list and no scan response, which is 31 bytes on air:

```text
02 01 <flags>          Flags, inserted by the stack
1B 16 30 FE <24 bytes>  Service Data for 16-bit UUID 0xFE30 (little-endian on air)
```

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | capabilities, low byte (`0xFF` on current builds) |
| 1 | 16 | node id as raw bytes (the 26-character base32 id, decoded) |
| 17 | 4 | digest cue: the low 32 bits of the custody FNV fold, big-endian; nothing on BLE reads it |
| 21 | 2 | L2CAP PSM, big-endian, assigned by the stack when the server opens |
| 23 | 1 | BLE-local flags: bit 0 is `FLAG_SIDE_CHANNEL`, always 0 in release builds; bits 1–7 are reserved |

A payload shorter than 23 bytes is dropped, exactly 23 reads the flags as 0, and anything past 24 is
ignored. There is no version byte: the UUID implies the version. `0xFE30` sits in the SIG member block and
is not assigned to Knit, which knit-next accepts as a risk. `0xFE38` carries the side channel's
extended-advertising pages, which this port never uses.

## The link

Once L2CAP is open, the link is a stream of records `[type:1][len:4 BE][payload]`, each at most 524,288
bytes. The tags:

| Tag | Record | Payload |
| --- | --- | --- |
| 1 | `FRAME` | CBOR `WireEnvelope` (`wire-format.md`) |
| 2 | `FILE_HEADER` | UTF-8 JSON `{"kind":"AVATAR"\|"ATTACHMENT","key":"<64 lowercase hex>","mime":"…"}` |
| 3 | `FILE_CHUNK` | raw bytes, 16 KiB from Android; a file over 8 MiB + 64 KiB is aborted |
| 4 | `FILE_END` | empty |
| 5 | `KEEPALIVE` | empty; Android never sends one and ignores it on receipt |
| 6 | `HELLO` | UTF-8 `nodeId\|version\|capsHex`, for example `ffbbh6thbepahqxsv2gqog45m4\|1\|fff` |
| 7 | `DIGEST` | UTF-8 JSON `{"ids":[…]}` |

- **An unknown tag, a bad length or a truncated record throws on Android and drops the link.** Never send
  a tag outside 1..7.
- A `FRAME` that does not decode is counted and skipped, and the link stays up. Frames and digests may
  interleave with file chunks.
- Only one file streams each way at a time. A new `FILE_HEADER` discards a partial file.
- Android caps each socket write at `min(maxTransmitPacketSize, 8192)` bytes and paces files to 28 KiB/s.
  Keep our writes at 8 KiB or less.

### The handshake

The dialer writes its HELLO first. The responder must see a HELLO as the first record within 5 s
(`ACCEPT_HELLO_TIMEOUT_MS`), or it closes. Then it checks the tie-break at
`BluetoothMeshTransport.kt:754`:

```kotlin
if (localNodeId >= clientNodeId || clientNodeId in links.keys) { link.close(); return }
```

It closes without replying when the dialer's id is not strictly greater, or when the two are already
linked. Otherwise it replies with its own HELLO, and the dialer checks that the reply's node id matches
the advert it dialed. There is no negotiation, no identity proof and no key exchange at this layer. Bytes
after the HELLO belong to the frame loop, and Android may send frames right after its reply.

Node ids compare as Kotlin strings, which for `[a-z2-7]` is ASCII order: the digits `2`–`7` sort before
`a`–`z`. Compare the 26-character strings, never the raw 16 bytes.

### After link-up

Android runs these at link-up, then every 60 s for each linked neighbour (`MeshManager.kt:2230`):

1. Push its signed profile as a `FRAME`, plus its avatar as FILE records if this peer has not had that hash
   this session.
2. Send a `blobreq` for each blob it wants.
3. Send a `DIGEST` of every live custody id.
4. Send a `keyreq` for keys it lacks.
5. Resend owed delivery ticks.

On receiving a peer's `DIGEST`, Android pushes every live custody frame the list omits (`ForwardSync.kt:97`).
It never replies with a digest, so each side must send its own.

## Scanning, promotion and backoff

The pure policies port to Swift with their tests. The scan duty cycle does not, because iOS owns the
radio.

- **Presence** (`BlePresenceTracker`): RSSI EWMA with α = 0.35. A gap over 8 s resets dwell. Entries linger
  90 s. Identity is the node id, and the newest sighting's device wins, so address rotation is harmless.
- **Promotion** (`PromotionPolicy`): smoothed RSSI of at least −90 dBm and 12 s of dwell, strongest first.
  At most 6 links. Overflow sheds the weakest link that is at least 20 s old. At the budget, the weakest
  link is replaced only by a candidate 8 dB stronger. A link from a peer never sighted scores −127
  (`ABSENT_LINK_RSSI`), so it is shed first.
- **Backoff** (`ConnectBackoffPolicy`): 10 s × 2^(streak − 1), capped at 180 s, ±20 % jitter. A link that
  ends at EOF also bumps the streak, and success resets it.
- **Connect:** a 12 s watchdog around each dial (`CONNECT_TIMEOUT_MS`). No MTU request, no PHY preference,
  no bonding.

## What this means for an iPhone

- **iOS cannot advertise service data**, only a local name and service UUIDs. Android's scanner filter
  requires service data, so Android never sees an iPhone. The iPhone can read Android's service data, so it
  sees Android.
- **So the iPhone dials Android, and Android's responder refuses it** unless the iPhone's id sorts higher.
  Companion change A1 accepts a dialer Android never sighted. Until A1 ships, roughly half of iPhone and
  Android pairs cannot link.
- **Backgrounded iPhones are not rediscovered.** An iOS app in the background loses its local name, and its
  service UUID moves to an overflow area that only foreground iOS scanners see. Android's advert has no
  UUID list, so a background scan filtered on `0xFE30` probably cannot match it either; check that on
  hardware. Open L2CAP links survive backgrounding with the `bluetooth-central` and `bluetooth-peripheral`
  modes.
- **Address rotation is harmless**, because everything keys on node id.
- **Stale links block reconnects** until Android's link-supervision timeout notices the drop, because the
  responder refuses a peer it still thinks is linked. A1 lets an unsighted dialer replace its own stale
  link.
- **Nothing is encrypted at this layer.** Profiles, room posts and HELLOs are plaintext on the air, and DMs
  carry their own end-to-end encryption.

## In this port

`KnitMesh/Link/LinkManager.swift` applies these rules for every radio, and the radios only move bytes
(ADR 2026-09.6es2). It keeps Android's numbers: 12 s of dwell at −90 dBm or better, six links with an 8 dB
hysteresis and a 20 s hold, the 10 s × 2ⁿ backoff capped at 180 s, and the 5 s HELLO and 12 s connect
timeouts. Its admission rule is A1's, which Android 2.7 does not have yet: it admits a dialer it never
sighted whatever the order, lets such a dialer replace its own stale link, scores an unsighted link at
−90 dBm, and keys links by channel, so one channel's teardown never touches another's.
