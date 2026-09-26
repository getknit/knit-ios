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

**Consequences / limits:**

- **Cross-platform law.** The UUID is law once A3 ships. Change it only together with knit-next.
- **What reads it today.** The Linux peer serves the payload, but no radio reads it yet. `KnitBLE` will (P6), and
  `KnitBlueZ` should before P8, so both dial orders of MVP item 8 work. Until then the Linux peer's advert
  leaves the flag clear.
- **Guards.** `LinkTests`' `theGATTIdentifiersArePinned` and `theGATTValueIsThePayloadWithItsCueZeroed`,
  `LinkManagerTests`' `aRadioThatCannotReadGATTPayloadsLeavesTheFlagClear`, and `BlueZAdvertTests`.
