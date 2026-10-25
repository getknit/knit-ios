# Bluetooth LE transport

How knit-next's `mesh/bluetooth/` and `mesh/link/` behave at the pinned commit, and what that means for an
iPhone. The iPhone's own design decisions are ADRs; this file is the Android ground they stand on. The
`bluetooth-owner` reads it before it writes and the `bluetooth-reviewer` before it judges (`.agents/rules/owners.md`).

## GATT on the mesh plane: a payload and a doorbell

On the mesh plane Android serves no GATT, and reads only two things a peer serves: the GATT payload of a node that
advertises only the `0xFE30` UUID, with companion change A3 (below), and a peer's doorbell (below). No notifications,
and toward an iPhone no MTU request of its own: only an Android peer's boosted link asks for one (knit-next #120,
`BleLinkTuner.kt`). Each phone is both roles at once:

- **Peripheral:** a connectable advert and an L2CAP server (`listenUsingInsecureL2capChannel`).
- **Central:** a scanner and an L2CAP client (`createInsecureL2capChannel(psm)`).

Channels are LE credit-based and insecure: no pairing, no bonding, no link encryption. CoreBluetooth's
equivalents are `publishL2CAPChannel(withEncryption: false)` and `CBPeripheral.openL2CAPChannel(_:)`.

Companion change A4 (knit-next `c3191717`, its ADR 2026-09.dqvb, in the pin) makes Android a
GATT client toward one kind of peer: one whose HELLO carries `CAP_DOORBELL` (`0x1000`), which says the peer serves
the doorbell. On a link it accepted from such a peer, Android attaches a GATT client to that link's own connection
(`connectGatt` on a device it is already connected to does not dial). It discovers the `0xFE30` service and finds
the doorbell, `f34c056b-5830-4243-a888-01f92f49e446`, provided it takes a write without response. Since `82898694`
(knit-next #102, an amendment to ADR 2026-09.dqvb) that lookup runs at link-up rather than at the first ring, and each
lookup that finds the doorbell asks for `CONNECTION_PRIORITY_BALANCED`: an iPhone that dialed is the central and runs
the link at a 720 ms supervision timeout, which the stack's own update during discovery raises to 5 s and then puts
back. BALANCED carries 5 s (30–50 ms, no latency), and iOS grants it. The put-back can land after that grant and
win, and a BlueZ central's 420 ms comes back the same way. Since knit-next `3e566b1f` (built as `ed9446bf`, a
further amendment to ADR 2026-09.dqvb, in the pin) the client asks again at once when a report shows a timeout under
5 s, and again 2 s after its ask unless a report since has shown 5 s, at most twice a lookup. A report with a failed
status spends no re-ask (`fe2eeed6`, built as `24bac000`). Each re-ask logs `bt doorbell priority <id> again
(put-back <ms>ms|settle)`. On the Pixel 7 the iPhone's 720 ms came back on every link, and the first re-ask brought
each back to 5 s ("What the put-back race showed", `linux-peer.md`). Then it rings the doorbell after the frames
it writes, with a 1-byte write without response, at most once every 5 s plus once after a burst. `typing`, `blobreq`
and `keyreq` frames never ring; nor do digests, FILE records or the HELLO. It never writes with a response, never
serves GATT itself, and never sets the bit. Before A3 a link it dialed took its capabilities from the advert's low
byte, which cannot show the bit, so it rang only links it accepted. A3 (below) takes them from the HELLO reply
instead, so it rings a dialed iPhone too.

Off the mesh plane, a build with `WEAR_STATUS` on (every debug build; release keeps it dark) serves a bonded Wear OS
watch one encrypted, read-only characteristic in a service of its own, `6b1f0a3e-5d2c-4f0e-9a57-3c8e2d41b7a0`
(knit-next ADR 2026-09.wetm). While the mesh is paused it raises an empty connectable advert so the watch can
reach it. Neither is in `0xFE30` or on the mesh wire, and Knit ignores both.

## The advert

Legacy advertising (`ADV_IND`, connectable and scannable), about one second apart, 1M PHY, at full power
(`TX_POWER_HIGH`) since knit-next ADR 2026-10.ryak; it was medium until then. A build running the Coded PHY
(knit-next ADR 2026-10.yvn6; debug builds, and release since knit-next `713b29d6`) also airs a second, extended set on
the Coded PHY with the same payload. An iPhone cannot hear that set, and nothing here reads it.
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
| 23 | 1 | BLE-local flags: bit 0 is `FLAG_SIDE_CHANNEL`, set while the side channel runs; bit 1 is `FLAG_DIALS_GATT_PEERS`, set while the GATT reader runs (A3); both are on in release since knit-next `713b29d6`. Bit 2 is `FLAG_NO_AWARE` (below); bits 3–7 are reserved |

A payload shorter than 23 bytes is dropped, exactly 23 reads the flags as 0, and anything past 24 is
ignored. There is no version byte: the UUID implies the version. `0xFE30` sits in the SIG member block and
is not assigned to Knit, which knit-next accepts as a risk. `0xFE38` carries the side channel's
extended-advertising pages, which this port never uses.

`FLAG_NO_AWARE` (`0x04`, knit-next ADR 2026-10.2t49, GitHub #44; `9552995d`, `438ffc72`) has inverted polarity: set
means "this phone will not run Wi-Fi Aware". Android sets it by default and clears it only after Wi-Fi Aware has been
held clear for 60 s (`NoAwareFlag.kt`). A peer whose service-data advert has it clear is an Aware candidate, and its
being near wakes Android's dormant Wi-Fi Aware plane (`AwareCandidateTracker.kt`). A GATT-payload sighting never makes
one, and neither does a link whose HELLO carries `CAP_DOORBELL`, so an iPhone's clear bit costs nothing. The Linux
peer's `android` profile advertises service data with the bit clear, so it keeps nearby Pixels' Wi-Fi Aware awake.
`BleAdvertPayload.kt:25-26` asks this port to reserve the bit. That is owed: `AdvertPayload` names bits 0 and 1 only,
and every radio here advertises bit 2 clear (`LinkManager+Channels.swift`).

## The link

Once L2CAP is open, the link is a stream of records `[type:1][len:4 BE][payload]`, each at most 524,288
bytes. The tags:

| Tag | Record | Payload |
| --- | --- | --- |
| 1 | `FRAME` | CBOR `WireEnvelope` (`wire-format.md`) |
| 2 | `FILE_HEADER` | UTF-8 JSON `{"kind":"AVATAR"\|"ATTACHMENT","key":"<64 lowercase hex>","mime":"…","size":<bytes>}`; `size` since knit-next ADR 2026-10.y9qh |
| 3 | `FILE_CHUNK` | raw bytes, 2 to 16 KiB from Android (2 KiB on a Coded link); a file over 8 MiB + 64 KiB is aborted |
| 4 | `FILE_END` | empty |
| 5 | `KEEPALIVE` | empty; since knit-next ADR 2026-10.697m, Android writes one at link-up on a link whose HELLO lacks `CAP_DOORBELL`, answers one there, and probes with it. On a doorbell link it sends none and ignores one. It may write one between a file's chunks (`FramedLink.sendKeepalive`, #203), which this port ignores like any other. This port never writes one (`interop.md`) |
| 6 | `HELLO` | UTF-8 `nodeId\|version\|capsHex`, for example `ffbbh6thbepahqxsv2gqog45m4\|1\|2fff`; the caps may carry `CAP_DOORBELL` (`0x1000`) and `CAP_BLOB_HAVE` (`0x2000`), which no advert can |
| 7 | `DIGEST` | UTF-8 JSON `{"ids":[…]}` |

- **An unknown tag, a bad length or a truncated record throws on Android and drops the link.** Never send
  a tag outside 1..7.
- A `FRAME` that does not decode is counted and skipped, and the link stays up. Frames and digests may
  interleave with file chunks.
- Only one file streams each way at a time. A new `FILE_HEADER` discards a partial file.
- A header's `size` is the length of the stream that follows, so the receiver can draw how far the file has got
  (knit-next ADR 2026-10.y9qh). It is only the sender's claim, so nothing bounds the stream by it. Android takes a
  total only in 1..8,454,144 and shows the bytes alone outside it. A size that will not decode is read as none and the
  file still lands, and a header from a build before the field has none. Android and this port always write it.
- Android caps each socket write at `min(maxTransmitPacketSize, 8192)` bytes. Keep our writes at 8 KiB or less.
- Android clocks a file to a peer that reports by the peer's `blobprog` reports (`FeedWindow`, knit-next ADR
  2026-10.5buf): a window of `rate × (round trip + 250 ms)`, 4 to 64 KiB, in chunks of about a quarter second of the
  rate. A peer that reports is any whose HELLO carries `CAP_BLOB_HAVE`, an iPhone included: knit-next `e658eb6f`
  lifted the two gates that left iPhones out (`BleFeedPolicy.windowed`, `BlobExchange.onFileProgress`), and no
  device run has checked either direction since (knit-ios #6). Otherwise, and as the fallback for a silent or
  two-second receiver, it paces by the link's PHY, read again before every chunk (`CodedPhyPolicy.pace`, #114):
  - on 1M and 2M, one budget of 4 KiB/s split evenly across the links feeding at the pace, each chunk two seconds of
    a link's share, from 2 to 16 KiB (knit-next ADR 2026-10.8jwn; it was 28 KiB/s a link before). An Android peer's
    link that has earned the boost (#120) takes 18 KiB/s of its own, or 12 KiB/s with more than four LE links
    (`CodedPhyPolicy.kt:416-432`). A doorbell link never earns it, so an iPhone's share stays inside the 4 KiB/s;
  - 1 KiB/s in 2 KiB chunks on Coded, outside the split.

  The pace is the sender's own choice, and a receiver takes a chunk of any length. This port does the same since ADR
  2026-10.xwjc, without the Coded parts: it windows any peer whose HELLO carries `CAP_BLOB_HAVE`, iPhones included,
  and paces the rest at 8jwn's budget, each chunk still behind the radio's report (ADR 2026-10.h6zz).

### The handshake

The dialer writes its HELLO first. The responder must see a HELLO as the first record within 5 s
(`ACCEPT_HELLO_TIMEOUT_MS`), or it closes. Then `BleAdmissionPolicy.decide` gives the verdict
(`BleAdmissionPolicy.kt:54-72`, called at `BluetoothMeshTransport.kt:2685`):

```kotlin
dialer == local -> Refuse
seen && local > dialer -> Refuse
heldLinkAgeMs == null -> if (atCap) Refuse else Admit
seen -> Refuse
heldLinkAgeMs < REPLACE_MIN_HOLD_MS -> Refuse
else -> Replace
```

`seen` is presence's sighting. For a dialer whose HELLO carries `CAP_DOORBELL`, and whose claim Android's own evidence
backs (`doorbellTrusted`), it also needs a sighting in the last 12 s (AND-3, below). `atCap` is a debug link cap, always
false in release. A refusal closes without replying. Otherwise it replies with its own HELLO, and the dialer checks that the reply's node id matches
the advert it dialed. There is no negotiation, no identity proof and no key exchange at this layer. Bytes
after the HELLO belong to the frame loop, and Android may send frames right after its reply.

Node ids compare as Kotlin strings, which for `[a-z2-7]` is ASCII order: the digits `2`–`7` sort before
`a`–`z`. Compare the 26-character strings, never the raw 16 bytes.

Two rules have moved that check since `02051b64`. A1 (knit-next ADR 2026-09.shzv) put it in
`BleAdmissionPolicy`, which admits a dialer it never sighted, whatever the order, and refuses a sighted one
below it. #103 (knit-next ADR 2026-09.hj4a) lets a phone dial upward when it is alone. An Android phone with
no BLE link, which has had none for `LONELY_AGGRESSIVE_WINDOW_MS` (180 000 ms, counted from the later of the
transport's start and its last link going down), may dial a peer it sights above it. It picks the strongest,
on an ordinary dial's filters and backoff, one dial at a time, and logs `bt lonely dial` first. A responder
that has sighted it refuses, and the phone counts a `HANDSHAKE` failure. One that has not, like a screen-off
phone, admits it. This port's `admit()` already gives both verdicts (ADR 2026-09.6es2), so nothing here
mirrors #103.

Since knit-next `99fbcad1` (#199, an amendment to its ADR 2026-10.9qr4), Android refuses a HELLO whose node id is not
canonical: 26 lowercase base32 characters that round-trip through 16 bytes (`Protocol.kt:210-212`). On its own dial it
closes the link and counts a `HANDSHAKE` failure, which bumps the backoff. As responder it just closes. This port
already refuses the same ids the same way, through `NodeId(_:)`: the dialer retires with a backoff
(`LinkManager+Admission.swift:188`), and the responder retires without one (`:202`). It only ever sends
`localId.string`, which is canonical.

### After link-up

Android runs these at link-up (`neighborPass`, `MeshManager.kt:3126`):

1. Ask for the blobs it wants, of the new neighbours among the rest.
2. Push its signed profile as a `FRAME`, plus its avatar as FILE records if this peer has not had that hash
   this session.
3. Send a `DIGEST` of every live custody id.
4. Send a `keyreq` for keys it lacks.
5. Resend owed delivery ticks, and unacked group seeds.

Every 60 s it runs them again for each linked neighbour, all but the profile (`reofferToNeighbors`, `:3035`).

On receiving a peer's `DIGEST`, Android pushes every live custody frame the list omits (`ForwardSync.kt:136`).
It never replies with a digest, so each side must send its own.

## Scanning, promotion and backoff

The pure policies port to Swift with their tests. The scan duty cycle does not, because iOS owns the
radio.

- **Presence** (`BlePresenceTracker`): RSSI EWMA with α = 0.35. A gap over 8 s resets dwell. Entries linger
  90 s. Identity is the node id, and the newest sighting's device wins, so address rotation is harmless.
- **Promotion** (`PromotionPolicy`): smoothed RSSI of at least −90 dBm and 12 s of dwell, strongest first.
  At most 6 links. Overflow sheds the weakest link that is at least 20 s old. At the budget, the weakest
  link is replaced only by a candidate 8 dB stronger. A link from a peer never sighted scores −127
  (`ABSENT_LINK_RSSI`), so it is shed first. Since A1 such a link scores −90, the floor. Since knit-next ADR
  2026-10.ryak the presence advert runs at full power and the floor has not moved, so a sighted link reads 8 dB
  stronger at the same spot than before. At the budget, an unsighted link, which an iPhone's often is, is now shed
  ahead of a sighted one more often. The connect loop also wakes when a candidate's dwell ends, between scan
  windows (knit-next ADR 2026-10.pj9w), as `LinkManager` already did.
- **A backgrounded iPhone's link scored −127 until AND-3's fix** (the interop audit's finding, knit-next
  `a03fe167`, in the pin). Android sighted the iPhone in front, by its GATT payload. Knit then
  left the front, iOS moved its UUID to the overflow area, and Android heard it no more. Ninety seconds later the
  iPhone left presence, and its live link scored `ABSENT_LINK_RSSI`, the first shed at the cap. Since the fix, a
  link whose HELLO carried `CAP_DOORBELL` scores the floor, −90, while its peer is out of presence, as a link
  Android never sighted does. That ranks it with an unsighted link, and a candidate 8 dB stronger than the floor
  still replaces it at the budget.
- **Backoff** (`ConnectBackoffPolicy`): 10 s × 2^(streak − 1), capped at 180 s, ±20 % jitter. A link that
  ends at EOF also bumps the streak, and success resets it. Since knit-next `9a68b225` (#205, `LinkDownOnce.kt`) a
  link's end bumps it once. The read and write loops both used to report it, so a single drop bumped the streak
  twice and the first redial came after about 20 s instead of 10. A link Android closes as silent (697m, below)
  never bumps it. This port's `retire` already acts once per link (`retire(_:backingOff:keepingCut:now:)` in
  `LinkManager+Channels.swift`).
- **Connect:** a 12 s watchdog around each dial (`CONNECT_TIMEOUT_MS`). No MTU request toward an iPhone, and no
  bonding.
  - **Every link's ACL gets an arm** (knit-next #142 and #150, its ADR 2026-10.b8yf; `8dc95c3e`, `d39759dc`): a GATT
    client that attaches and asks nothing, so the ACL idles out about 4 s after its last channel closes. On an
    iPhone's link the doorbell lookup is that arm. A refused or failed channel's ACL is armed 2 s after it closes, so
    that connection ends a few seconds later.
  - The Coded PHY (debug builds, and release since knit-next `713b29d6`) works only with a peer it hears on Coded. It dials that peer's Coded
    address with a 25 s watchdog, and switches the link's PHY over GATT. An iPhone is never heard on Coded, so its
    links stay on 1M.
  - After its last link drops, a phone searches at the 12 s scan gap for three minutes before relaxing (knit-next
    ADR 2026-09.w3xk).
  - The side that dials back hunts a Coded peer it lost at range, every other window Coded-only, for three minutes,
    or up to 30 while Knit is open, which also hunts on its own (knit-next ADR 2026-10.yvn6, amended `ab0d17aa`). Only
    a peer heard on Coded is hunted, so never an iPhone; a hunting window that is Coded-only is deaf to an iPhone's
    advert.
  - Since knit-next `752922da` (its ADR 2026-10.yvn6, amended 2026-10-20), on in release:
    - A 1M hit weaker than −90 dBm no longer resets a peer's 1M mark, so a peer that Coded hears well becomes
      `codedOnly` even while its faint 1M advert still gets through (`BlePresenceTracker.kt:183-186`).
    - A cold sighting starts a bounded hunt: an unlinked peer heard on Coded alone, with no drop behind it, at −90 or
      better. The larger id hunts, and only if promotion would dial the peer. The smaller id puts out a fast Coded
      advert instead (`CodedPhyPolicy.coldHunt`). Each peer gets one per 30 min, and each kind gets 3 min per 30 min
      across the phone (`ColdSightings.kt`).
    - A hunt shortens the scan gap to 12 s and makes every other window Coded-only.

    An iPhone is never heard on Coded, so it is never `codedOnly`, never far and never hunted, and it never gets a
    PHY handle, so `ba14a876`'s step-up backoff never acts on its links. Three costs reach an iPhone anyway, none
    of them measured yet (roadmap):
    - Any unlinked far peer turns on Coded-only windows, even on a phone that holds an iPhone link
      (`ScanPlan.codedWindows`), and those windows are deaf to the iPhone's advert.
    - A peer ripened by a hunt can shed an out-of-presence iPhone link at the budget. That link scores the −90 floor,
      so a candidate 8 dB stronger beats it, now on a phone with its screen off too.
    - A failed Coded dial holds the scan for up to 25 s (`CODED_CONNECT_TIMEOUT_MS`), against 12 s for a 1M dial.

## What this means for an iPhone

- **iOS cannot advertise service data**, only a local name and service UUIDs. Before A3, Android's scanner filter
  required service data, so Android never saw an iPhone. The iPhone can read Android's service data, so it
  sees Android.
- **So the iPhone dials Android, and Android's responder refuses it** unless the iPhone's id sorts higher.
  Companion change A1 accepts a dialer Android never sighted, so every pair links.
- **With companion change A3, Android sees a foreground iPhone** (knit-next ADR 2026-09.kwq2, merged in the pin; behind `BLE_GATT_PEERS`,
  on in release since knit-next `713b29d6`, ahead of its device trial). A second scan filter matches the `0xFE30` UUID. Android reads the GATT payload
  of an advert that lists only the UUID, on `GattPayloads`' rules, sights the iPhone with it, and dials it when its
  own id sorts higher. It reads nothing while one of its dials is in flight, and holds its dials while a read runs.
  Since #154 (`8246d2ec`, the 2026-10-11 amendment to kwq2) it charges at most 12 reads in any 10 minutes across every
  address, and a link whose HELLO names the payload's node refunds that read's charge. Once strangers, or an iPhone at
  the edge of range, have spent the budget, a foreground iPhone at a new address can wait up to 10 minutes to be
  read. Once it sets `FLAG_DIALS_GATT_PEERS`, an iPhone whose id sorts lower waits to be dialed, and Android refuses that
  iPhone's own dial as a sighted dialer below it. It still cannot see a backgrounded iPhone, whose UUID sits in the
  overflow area, and admits one unsighted under A1 when it dials.
- **Until AND-3's fix, that admission waited 90 s.** A backgrounded iPhone stays in Android's presence for the 90 s
  linger after Android last heard it, so a re-dial in that time met a sighted dialer's rule, and an Android phone
  above it refused it. Nothing on Android dialed it either, since it was no longer heard. Since the fix, a dialer
  whose HELLO carries `CAP_DOORBELL` counts as sighted only if Android heard it in the last 12 s, the promotion
  policy's silence limit. One heard that recently is in front, and Android dials it itself. Any other is admitted,
  and its refused or accepted line names `heardAgoMs` and `inPresence`. Android's scan is duty-cycled, so a
  foreground iPhone's dial is sometimes admitted too. Android also dials a backgrounded iPhone back from its presence
  while that lingers, which usually beats the iPhone's own seek dial (`linux-peer.md`, "What AND-3's trial showed").
- **A lonely Android phone may dial an iPhone above it** (#103), but it must sight the iPhone first, which means a
  foreground iPhone whose payload it has read. That iPhone has sighted the phone's advert too, so it refuses the
  dial and dials the phone itself.
- **An iPhone below a flagged phone gives it a head start, then dials it** (ADR 2026-10.6eyf, interop-audit finding
  AND-2). At the front, once the phone has dwelled 24 s (the ordinary 12 s plus 12 s), the iPhone dials it, one such
  dial at a time, strongest first. A phone that has sighted the iPhone within 90 s refuses that dial and dials the
  iPhone itself; one that has not admits it under A1. The iPhone is then the link's central, opened at 720 ms, and
  the HELLO's `CAP_DOORBELL` is what has Android ask for BALANCED's 5 s, so a radio that serves no doorbell gives
  no head start. Its log line is `link head start over for <id> (dwell=<ms>ms rssi=<dBm>dBm)`.
- **No one rediscovers a backgrounded iPhone.** An iOS app in the background loses its local name, and its
  service UUID moves to an overflow area that only an iOS scan for that UUID sees: not Android, not BlueZ, and not
  an iPhone at the front, which scans for every advert. Open L2CAP links survive backgrounding with the
  `bluetooth-central` and `bluetooth-peripheral` modes.
- **A locked iPhone can find peers, at a price.** iOS scans in the background only for named services. A scan
  filtered on `0xFE30` matches Android's advert, which carries the UUID only as service data, and a UUID list too
  (P8's scan-filter check, `.agents/context/linux-peer.md`). Locked, it found each new peer 30 to 120 s after the
  peer appeared, and each match woke Knit for about 10 s. Among five Android phones Knit ran three quarters of
  the time, where the unfiltered scan, which goes quiet in the background, let it sleep for 14 minutes. So Knit
  scans unfiltered, and filters only while it seeks: in the background, with no link, and at most eight wakes a
  spell (ADR 2026-10.mueg). Seeking dials a peer on its first sighting and whatever the order, since the peer that
  the order picks cannot see the iPhone.
- **A suspended app gets nothing on its links, until a peer rings.** Data arriving on an L2CAP channel does not
  wake a suspended Knit. It waits on the link, and arrives when Knit next comes to the front. A link held through
  14 minutes locked, and ten DMs arrived within a second of Knit opening (MVP item 9's wake test,
  `.agents/context/linux-peer.md`). A write to the doorbell beside the GATT payload does wake it, for about 9 s,
  and the link manager rings after the frames it writes (ADR 2026-09.khjj). The Linux peer rings, and an iPhone
  rings the peers it dialed. Android rings with A4, and the Pixel 3's rings woke a locked iPhone for every DM of a
  ten-minute test: the iPhone's HELLO asks for it with `CAP_DOORBELL`, and Android rings the links the iPhone
  dialed. With A3 it rings the links it dialed too, whose capabilities it takes from the iPhone's HELLO reply. A phone
  whose build predates A4 never rings, and its frames wait for the next foreground.
- **Address rotation is harmless**, because everything keys on node id.
- **Stale links block reconnects** until Android's link-supervision timeout notices the drop, because the
  responder refuses a peer it still thinks is linked. A1 lets an unsighted dialer replace its own stale
  link.
- **Android closes a silent link itself, but never an iPhone's** (knit-next ADR 2026-10.697m, `f8b5d544`,
  `b49f7f13`, `ec37724e`; `LinkSilence.kt`). On a link whose HELLO lacks `CAP_DOORBELL`, each side writes an
  announce `KEEPALIVE` at link-up, and one received marks the link as answering. With no byte in for 90 s, the first
  probe rides the next digest, frame or file this side queues, or goes alone once it has waited 120 s of uptime for
  one. A second probe follows 30 s after the first, and 30 s after that, with still no byte in, the link closes: about
  150 to 210 s after the last byte. Android also closes any such link whose write has stalled for 120 s. Toward a peer
  that never answered, it also closes a link that has been quiet for 90 s once its PHY handle's GATT client has seen
  the connection end. A link whose HELLO carries the bit is exempt from all of it (`LinkSilence.kt:39`), because iOS suspends Knit
  with its link up. That covers every CoreBluetooth link. The Linux peer's `android` profile lacks the bit, so Android
  announces to it, and because it never answers, Android never probes it. Only the write stall applies there. The
  iPhone's own links still last until the supervision timeout: Android would not answer an iPhone's probe, so this
  port has no silent-link rule (ADR 2026-09.6es2).
- **Nothing is encrypted at this layer.** Profiles, room posts and HELLOs are plaintext on the air, and DMs
  carry their own end-to-end encryption.

## In this port

`KnitMesh/Link/LinkManager.swift` applies these rules for every radio, and the radios only move bytes
(ADR 2026-09.6es2). It keeps Android's numbers: 12 s of dwell at −90 dBm or better, six links with an 8 dB
hysteresis and a 20 s hold, the 10 s × 2ⁿ backoff capped at 180 s, and the 5 s HELLO and 12 s connect
timeouts. Its admission rule is A1's, which Android 2.7 does not have: it admits a dialer it never sighted
whatever the order, lets such a dialer replace its own stale link once that link is 30 s old, scores a link
whose peer it has never sighted at −90 dBm (one sighted and then lost at −127), and keys links by channel, so
one channel's teardown never touches another's. Two promotion rules are its own (ADR 2026-09.6es2, amended
2026-09-29 and 2026-10-02): it never dials a peer quiet for more than 12 s, and it wakes when a candidate's dwell ends
instead of waiting for that peer's next advert.

The advert sets `FLAG_DIALS_GATT_PEERS` only when the radio reads the GATT payload of a UUID-only peer
(`Radio.dialsGattPeers`), since a peer that trusts the flag waits to be dialed. A node that cannot advertise
service data serves that payload as a read-only characteristic, `848eedcd-a2e3-4fb2-86f9-e2c80821a497`, in a
primary `0xFE30` service, with the digest cue zeroed (ADR 2026-09.xzpt). A radio that reads those payloads
paces itself by `GattPayloads`: one peer at a time, a failed read tried again after 30 s, and a device that serves
no payload left alone for ten minutes. A payload serves the address's adverts until a dial there fails before its
channel opens, a HELLO there names another node, or the address goes unheard for a minute of scanning while nothing
links it. Those three rules are shared law with A3 (ADR 2026-09.xzpt, amended 2026-09-29).

The HELLO adds `CAP_BLOB_HAVE` (`0x2000`) to this build's `0x15F` always, since every build answers a holder query
(knit-next ADR 2026-10.6e5t), reading `215f`. It adds `CAP_DOORBELL` (`0x1000`) too, reading `315f`, only when the
radio serves the doorbell (`Radio.servesDoorbell`): `KnitBLE`, and knit-peer's `ios` profile. The `android` profile,
like Android, serves no GATT and never sends it. The link manager rings after every frame it writes except `typing`,
`blobreq`, `blobhave`, `blobhas`, `blobprog`, `blobcancel` and `keyreq`, as Android does, so both platforms wake an
iPhone equally often (ADR 2026-09.khjj).

Files cross a link as Android's do (ADR 2026-10.h6zz).

- **Out:** a header, chunks, then an END, one file per link at a time (ADR 2026-10.xwjc).
  - A peer whose HELLO carries `CAP_BLOB_HAVE` is fed by `FeedWindow`, clocked by its `blobprog` reports. Any other
    peer, or a windowed one whose receiver is silent for 3 s or reports only every 2 s, is paced at one 4 KiB/s budget
    split among the links feeding at the pace. The window logs `link file window …` and the pace `link file pace …`.
  - Each chunk also waits until the radio reports the last one out of its `LinkOutbox`
    (`RadioEvent.wroteFileRecord`), so frames go out between chunks.
  - Our photo goes as kind AVATAR right behind our profile at each link-up. Anything served goes as kind ATTACHMENT.
- **In:** each link's records pass through a `FileIntake` under Android's receiving rules.
  - A peer's own AVATAR push is kept up to 1 MiB, and an ATTACHMENT only when the engine asked for its hash.
  - Partial files on all links together stay under 16 MiB.
  - A teardown cuts an ATTACHMENT that is streaming in and keeps its bytes as a prefix for the next ask to name. That
    covers a closed link, a stale link replaced, and a radio that goes off, resets or loses permission. A
    bad record and `LinkManager.stop()` drop the bytes instead. A new teardown path has to make the same choice (ADR
    2026-10.w6rn).
  - A whole file stays on its way, to the fetch and to a holder query, from its END until the engine has taken it
    (`MeshTransport.fileTaken`, knit-next #138), since a radio read runs all its records before the engine sees one.
  - The engine tells the sender how much of a kept file is in with a `blobprog`: on every chunk that brings 2 KiB, at
    least every 500 ms, and once more 500 ms after chunks no report carried (`RxReports`, ADR 2026-10.xwjc). Every
    2 s with `feedWindow` off. It goes to any neighbour whose HELLO carries `CAP_BLOB_HAVE`, an iPhone included
    (knit-next ADR 2026-10.nsr7, ADR 2026-10.ds45).
  - A `blobcancel` from the asker takes its copy off the link while that copy still waits behind another file. One
    already streaming goes on.
  - FILE records never ring a doorbell.

`KnitBLE` is the iPhone's radio. Its central scans every advert with duplicates, or the `0xFE30` UUID alone while
the link manager seeks (`Radio.seekPeers`, ADR 2026-10.mueg), takes
Android's `0xFE30` service data as a sighting, and reads the GATT payload of a peer that lists only the UUID,
in its service list or its overflow area. A dial connects the peripheral and opens an L2CAP channel on the
advertised PSM. Its peripheral publishes an insecure channel, serves the payload and advertises the UUID
alone, and connects the far side of each channel it accepts as a peripheral too, so that a suspended Knit hears that
link end through `didDisconnectPeripheral` (ADR 2026-10.mueg). A stop forgets the PSM at once, and a start
publishes only once the stop's unpublish is answered, or after 5 s without an answer (`ListenerPublication`).
Published while an unpublish was still unanswered, the iPhone 12 got 193 instead of 192, and the Pixels that dial it
failed on the PSM they had read until they read it again. With nothing outstanding, iOS hands back 192. An answer can
carry the next channel's PSM, so answers are matched by count, and one that comes after the 5 s is logged and
ignored. The payload is served only while the listener is published on its PSM, and a resetting manager counts as
off (`linux-peer.md`, "What the restart trial showed"). Each channel's streams run on one run-loop thread, read in
64 KiB gulps and written 8 KiB at a time.
The managers carry restoration identifiers. A restored connection is dropped, since its channels did not
survive, but only once the central is powered on: CoreBluetooth refuses the command earlier, and a connection
left up kept every dial to that phone waiting. It first ran on an iPhone 12 on 2026-09-26
(`.agents/context/linux-peer.md`, "What the iPhone showed").
