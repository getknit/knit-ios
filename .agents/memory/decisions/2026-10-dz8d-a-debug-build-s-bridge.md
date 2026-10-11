---
id: "2026-10.dz8d"
slug: a-debug-build-s-bridge
title: "a debug build's bridge also listens on Wi-Fi, on a router pinned over USB"
date: 2026-10-01
topics: [interop, testing, app]
---

# ADR 2026-10.dz8d — a debug build's bridge also listens on Wi-Fi, on a router pinned over USB

Status: Accepted (2026-10-01)

**Context:** the bridge (ADR 2026-09.kwa8) listened only on the phone's loopback, so every run kept the iPhone
on the Linux machine's USB cable. That rules out range and relay runs with the phone in another room.
Android's bridge already works over Wi-Fi, because adb does. Loopback was also the bridge's only lock: the
protocol reads every thread's plaintext and sends as the user, and on Wi-Fi anyone on the network could
connect. The maintainer's network is private and secured, so what needs locking out is every other network the
phone joins, such as a café's or a hotspot.

**Decision:** a debug build also listens on Wi-Fi, on port 5648, but only while the phone is on a network pinned
over USB. `interop.py --host ADDRESS` connects there in place of `iproxy`.

- **The pin is the router, not the SSID.** `{"cmd":"wifi-pin"}` records the network's subnet, its IPv4 gateway
  and its IPv6 router's link-local address, read from `NWPath` and `getifaddrs` (`RouterPin`, `WiFiGate`). That
  address usually comes from the router's MAC, so it tells routers apart where `192.168.1.1/24` does not. A network
  matches when every recorded value is equal. Mesh access points and both bands share a gateway, so roaming at
  home keeps the match.
- **Pins change over USB only.** `wifi-pin` and `wifi-unpin` refuse a connection that came over Wi-Fi, so Wi-Fi
  can never widen where the bridge listens. The pins live in the app's defaults, never in the repository.
- **Off a pinned network, nothing listens on Wi-Fi.** A path monitor re-checks at every change and every
  foreground, and closes the Wi-Fi listener and its connections when the network stops matching. The listener is
  bound to the phone's Wi-Fi IPv4 address, and lets in only addresses from the pinned subnet.
- **No permission, entitlement or Info.plist key.** Accepting incoming TCP needs no Local Network permission
  (Apple's TN3179), and the router's values need none either.

The SSID and BSSID were the obvious pin. iOS gives them only to an app with the Access Wi-Fi Information
entitlement and precise location, and nobody has confirmed that the free Personal Team can get that entitlement.
A token, or TLS keyed by one, would keep out other devices on the pinned network, and the maintainer trusts
those. Bonjour would find the phone, and the phone could dial the computer, but both bring the Local Network
prompt.

**Consequences / limits:**

- **Nothing is encrypted on the pinned network.** Message text and every command cross it in the clear, and
  anyone on it can drive the phone, so pin only a network you would trust with the cable.
- **The pin can be copied.** A hostile network with the same subnet, gateway and router address would match.
  Without IPv6, or with a router at the generic `fe80::1`, the pin rests on the IPv4 values alone, and `wifi-pin`
  says so in its `warnings`. Then an uncommon home subnet is the remaining guard.
- **Only the bridge moves.** `idevicesyslog`, `idevicecrashreport` and a restart still need the cable, and
  `interop.py` says so when a Wi-Fi run reaches one of those steps. Suspension still closes every connection, as
  over USB.
- **Wi-Fi shares the radio.** The iPhone's Wi-Fi and Bluetooth share 2.4 GHz, so runs that time the BLE link
  should keep the phone on 5 GHz.
- **Release builds have none of it.** The listener, the gate and their imports are `#if os(iOS) && DEBUG`, and
  `seam_network` keeps `import Network` in `Sources/Knit/Debug/`.
- **Guards.** `RouterPinTests` covers the pin and its matching, and `WiFiCommandTests` the commands, the
  USB-only rule and the replies. The listener and the path monitor have no test, and are checked on the iPhone.
  On 2026-10-01 the iPhone 12 pinned a network whose router address came from its MAC, and nothing listened on
  Wi-Fi before the pin. After it, `interop.py --host` drove the bridge, and the bridge refused pin changes from
  Wi-Fi. Unpinning over USB dropped the open Wi-Fi connection and refused new ones, and the pin outlived an
  install. A command took 6.8 ms over Wi-Fi against 4.1 ms over USB (medians of 20). Moving the phone to another
  network has not been tried yet.
