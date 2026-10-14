---
id: "2026-10.2c6c"
slug: wi-fi-aware-on-the
title: "Wi-Fi Aware on the iPhone can only be a paired file lane, and waits on a spike"
date: 2026-10-13
topics: [scope, transport, wifi-aware]
---

# ADR 2026-10.2c6c — Wi-Fi Aware on the iPhone can only be a paired file lane, and waits on a spike

Status: Accepted (2026-10-13). Reaffirms ADR 2026-09.zwdp for the mesh.

**Context:** ADR 2026-09.zwdp kept Wi-Fi Aware off the iPhone because of knit-next's July review
(`docs/IOS_PORT_REVIEW.md` §1.2). It found that iOS 26 needs a pairing ceremony for every pair of devices, sends no
follow-up messages, cannot take knit-next's pre-shared data-path key and could not declare the old service name. We
looked again on 2026-10-13, against Apple's documentation as it stood that day, Espressif's August 2026 guide to
pairing an ESP32 with an iPhone, and the lab's Pixels.

- **Every connection still needs a paired device.** A `NetworkBrowser` or `NetworkListener` over Wi-Fi Aware takes
  only paired devices: `allPairedDevices`, `selected(_:)`, `matching(_:)` or `userSpecifiedDevices`. Pairing goes
  through DeviceDiscoveryUI's `DevicePicker` and `DevicePairingView`, where one person picks the other's phone and
  types a six-digit PIN, or through AccessorySetupKit, which is for accessories. Espressif found no open data path and
  no password security: iOS "always uses Wi-Fi Aware Pairing".
- **iOS 26.4 and iOS 27 left pairing alone.** 26.4 added `WASharedSecret`
  (`WAConnection.deriveSharedSecret(for:method:context:)`), a secret unique to one connection that an app can use to
  secure its own protocol, derived the way Wi-Fi Aware 5.0 specifies. 27.0 added `WAPerformanceForecast`, a
  throughput estimate.
- **Two of the review's objections no longer hold.** knit-next's service name is now `_knitmesh1._tcp`, which meets
  Apple's rules: a name of at most 15 letters, digits and hyphens, then `._tcp`. And Apple lets an app connect to a
  paired device "in both foreground and background states" whenever it has runtime, which Knit gets when CoreBluetooth
  wakes it.
- **Apple's license sets limits of its own.** Section 3.3.7(G) of the developer agreement forbids keeping a connection
  up while the paired devices are idle, requires what crosses it to be end-to-end encrypted, and forbids using it to
  track location. Apple grants the `com.apple.developer.wifi-aware` entitlement on request.
- **Most of the lab's Pixels cannot pair at all.** On 2026-10-13 `dumpsys wifiaware` read
  `isNanPairingSupported=true` on the Pixel 9 Pro XL and `false` on the Pixel 7 and Pixel 8, all on Android 17. The
  Pixel 3 was not read. knit-next links unpaired phones under one app-wide key (`setPmk` in `WifiAwareTransport`),
  which an iPhone cannot join. Apple's developer support says it is rare to find Android hardware and software that
  follow all of Apple's Wi-Fi Aware guidelines. A developer forum thread reports an Android pairing that completes
  but that iOS never saves.

**Decision:** the iPhone's mesh stays on Bluetooth LE, as zwdp says. A mesh of strangers cannot run on an API that
connects only devices people have paired by hand. The one shape left open is a lane for files between paired phones,
and it is not built. If someone wants it, a spike comes first. It pairs the lab's iPhone 12 with the Pixel 9 Pro XL,
using Apple's "Building peer-to-peer apps" sample on the iPhone and an Android test app that publishes
`_knitmesh1._tcp` with pairing on. It answers four questions:

1. Does the iPhone list the Pixel in `DevicePicker`?
2. Does the pairing last, showing under Settings → Privacy & Security → Paired Devices?
3. Does a data path come up?
4. How fast is it next to L2CAP?

We set two alternatives aside. Porting `WifiAwareTransport` as a second mesh plane needs unpaired discovery and
follow-up messages, and iOS offers neither. AWDL, through the Network framework's peer-to-peer option, links
strangers without pairing, but only Apple devices, and its future is unclear under the EU's interoperability decision.

**Consequences / limits:**

- **The mesh does not change.** Every frame to or from an iPhone still crosses L2CAP, and the iPhone advertises no
  fast-plane bit (`CAP_FAST_COMPACT`, `CAP_FRAME_TRANSCODE`, `CAP_DIRECT_TRANSFER`).
- **If the lane is built, it moves files and nothing else.** Discovery, cues, digests and custody stay on Bluetooth.
  Knit opens a Wi-Fi Aware connection to a paired peer for one transfer, speaks the same link records over it as
  over L2CAP, and closes it after, which keeps to the idle rule.
- **Pairing would be a second ceremony.** The natural moment is when two people already stand together to scan each
  other's code (ADR 2026-10.65xx), but Apple's PIN can't stand in for Knit's code, so they would do both.
- **Pairing proves the device, not the person.** The two-way HELLO maps a `WAPairedDevice.ID` to a node id, and it
  has to be bound to the connection's `WASharedSecret` with a signature from the identity key, or a paired phone
  could claim any node id.
- **Android would need a paired change.** It needs a second Wi-Fi Aware mode, with pairing, beside its keyed one,
  gated on `isNanPairingSupported` and on a new capability bit. iPhone to iPhone needs none of that, but the lab has
  only one iPhone.
- **Only Apple can reopen the mesh question**, by letting apps connect to unpaired devices. The EU's interoperability
  decision requires Wi-Fi Aware 5.0 once that specification is out, and access as effective as Apple's own. Whether
  that ever forces an unpaired mode is a guess; nothing has been announced.
- **The trap** is reading "iOS has Wi-Fi Aware" and starting a port of `WifiAwareTransport`. AccessorySetupKit is no
  way around pairing either: it is meant for accessories, and someone still taps each device.
- **The guards are zwdp's:** the "Advertise only what is implemented" rule in `.agents/rules/interop.md`, and
  `LinkTests.helloCarriesOurCapabilitiesAsLowercaseHex`, which pins `Capabilities.local` at `f`. Nothing keeps the
  WiFiAware framework or its entitlement out of the app, so a change that adds either comes back here.
- **Every reading above is from 2026-10-13:** Apple's documentation, the license and the Pixels' capabilities.
