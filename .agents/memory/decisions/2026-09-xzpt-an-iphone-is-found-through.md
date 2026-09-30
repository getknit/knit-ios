---
id: "2026-09.xzpt"
slug: an-iphone-is-found-through
title: "an iPhone is found through a read-only GATT payload under 0xFE30"
date: 2026-09-25
topics: [ble, wire, interop]
---

# ADR 2026-09.xzpt — an iPhone is found through a read-only GATT payload under 0xFE30

Status: Accepted (2026-09-25)

**Context:** iOS advertises only a local name and service UUIDs, never service data, so an iPhone cannot carry
Android's 24-byte `0xFE30` advert payload. Something must carry the node id, the PSM and the flags for a peer
to dial it. That peer is another iPhone, a `--radio-profile ios` Linux peer, or, once companion change A3
lands, Android. Nothing in knit-next defines one yet, and the Linux peer's `ios` profile needed it first.

**Decision:** a node that cannot advertise service data does three things:

- **Advertises** the 16-bit `0xFE30` UUID with no local name.
- **Serves** a primary GATT service `0000fe30-0000-1000-8000-00805f9b34fb` with one read-only characteristic,
  `848eedcd-a2e3-4fb2-86f9-e2c80821a497`, minted for Knit on 2026-09-25.
- **Reads as** `AdvertPayload.gattValue`: the same 24 bytes, with the digest cue set to 0.

Nothing on Bluetooth reads the cue, so a zeroed cue lets the value change only with the PSM, and a reader never
sees it churn. A read at an offset returns the rest of the value, as BlueZ asks when 24 bytes outgrow one ATT
read.

`FLAG_DIALS_GATT_PEERS` means "I read this payload, so I can find you". A radio sets it only when it does
(`Radio.dialsGattPeers`). A peer that trusts the flag waits to be dialed, so a false one would strand it.

The alternative was the payload in a local name or a manufacturer-data field. iOS drops both from a backgrounded
advert, and a name is visible in every scanner's list.

**Amended 2026-09-26, when `KnitBlueZ` learned to read the payload:** the rules for reading live in `KnitMesh`'s
`GattPayloads`, so KnitBLE reads on the same ones in P6. A radio reads a peer once, then sights it with that
payload on every advert, until a dial to it fails; then it reads it again, in case the peer restarted on a new
PSM. It reads one peer at a time and gives each read 12 s, Android's connect watchdog. A failed read is tried
again after 30 s. A peer that answers but serves no Knit payload waits ten minutes, since `0xFE30` is not
Knit's alone. BlueZ links the peer for the read, and the radio drops that link afterwards unless a channel uses
it. Only the `ios` profile reads. Neither Android 2.7 nor A1 does, so the `android` profile leaves the flag
clear, and an iPhone treats it exactly as it treats Android. `knit-peer scan` reads whatever it advertises, so
it lists iPhones. `GattPayloadsTests`, `BlueZGattReadTests` (`aUUIDOnlyDeviceOfHci0IsNeverRead` among them), `BlueZGattRetryTests`
and `BlueZModelTests`' `eachProfileFindsPeersAsItsPlatformDoes` guard it. So far only the fake BlueZ has served
this reader a payload; the first real one will be the Mac's (P7) or the iPhone's (P8).

**Amended 2026-09-26, when `KnitBLE` was written:** the CoreBluetooth radio serves the characteristic as a
static value, read-only, and replaces the service only when the value changes, which is only with the PSM. It
advertises the `0xFE30` UUID and nothing else. It reads a UUID-only peer on `GattPayloads`' rules: connect,
discover the service and the characteristic, read, then drop the connection unless a dial came to use it. It
counts the UUID in the overflow area too, where a backgrounded iPhone's advert keeps it, and sets the flag.
Nothing in it has run on hardware yet; the Mac's checklist M (P7) is its first radio.

**Amended 2026-09-26, when `KnitBLE` first ran on an iPhone** (an iPhone 12 on iOS 27.0): it dialed the Linux
peer and the lab's Android phones within seconds and carried the room both ways. Two things changed. The app
links with `-ObjC`, because only the Objective-C runtime reaches the delegates and the linker left their file
out. `BLERadio.foregrounded()` starts the scan again when Knit comes to the front, because a central restored
in the background reports a scan that finds nobody. For MVP item 8 the Linux peer's `ios` profile and the
iPhone then read each other's payloads, the first reads of a real device's on either side, and linked in both
orders. A read no longer forgets the payload when the radio drops its own connection afterwards; only a failed
dial does, as the rule above says. A relaunch's restored connections are cancelled once the central is powered
on, not in `willRestoreState`, where CoreBluetooth refused the command and a connection left up kept every dial
to that phone waiting.

**Amended 2026-09-27:** the service holds a second characteristic, a writable doorbell that wakes a suspended
iPhone (ADR 2026-09.khjj). The payload characteristic is unchanged, and a reader that looks it up by UUID skips the
doorbell.

**Amended 2026-09-29, after companion change A3's first device gate:** a payload no longer lasts until a dial fails,
and nothing else. On `hci1`, every knit-peer has the adapter's one public address. A phone that had read a peer whose
id sorted above its own never dialed it, so its payload never went. Each later peer at that address was then sighted
as the old one and never read, on both the Pixel 7 and the Pixel 3, until Knit restarted. The maintainer made three
rules shared law with knit-next (its ADR 2026-09.kwq2). A radio forgets an address's payload, and any wait, when:

1. a dial to it fails before its channel opens, as before;
2. a HELLO on a link to it names another node, whether the HELLO of a peer that dialed us or the reply to our own
   dial (`Radio.heardHello`, which `LinkManager` calls for every HELLO it reads). A refusal carries no HELLO, and
   keeps the payload;
3. it holds a payload and goes unheard (no advert, and no read or link) for 60 000 ms of scanning while no link, dial
   or read holds it. Only time the scan runs counts, since a stopped scan hears nothing. A stranger keeps its ten
   minutes. `GattPayloads` keeps the constant and the scan clock, and both radios check at
   each UUID-only advert, before that advert can be sighted with a stale payload. KnitBlueZ also sweeps every 30 s, and
   keeps forgetting a device BlueZ forgets.

One case stays open: a node that changes identity at an address that never goes quiet, where the old node sorts above
a flagged phone and the new one below it. Nobody dials, so it lasts until the address rotates or goes quiet.
`GattPayloadsTests` (the rules and the clock), `LinkAdmissionTests`' two HELLO tests and `BlueZGattLifetimeTests`
guard it. The CoreBluetooth radio keys an accepted link by its central's identifier, taking it to be the one the same device
has as a peripheral. On 2026-09-29 the iPhone 12 bore that out: a new identity that dialed in at a reused address
forgot the payload read under the same identifier (`interop.py iphone-forgets`, `.agents/context/linux-peer.md`).
KnitBLE checks for quiet only at the next UUID-only advert, so its forget is logged then; the payload is never used
stale.

**Consequences / limits:**

- **Cross-platform law.** The UUID is law once A3 ships. Change it only together with knit-next.
- **What reads it today.** The Linux peer serves the payload, but no radio reads it yet. `KnitBLE` will (P6), and
  `KnitBlueZ` should before P8, so both dial orders of MVP item 8 work. Until then the Linux peer's advert
  leaves the flag clear.
- **Guards.** `LinkTests`' `theGATTIdentifiersArePinned` and `theGATTValueIsThePayloadWithItsCueZeroed`,
  `LinkManagerTests`' `aRadioThatCannotReadGATTPayloadsLeavesTheFlagClear`, and `BlueZAdvertTests`.
