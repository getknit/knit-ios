---
id: "2026-09.vcdk"
slug: the-mac-peer-is-knit
title: "The Mac peer is knit-peer on CoreBluetooth, run in the desktop session"
date: 2026-09-28
topics: [interop, testing, toolchain, ble]
---

# ADR 2026-09.vcdk — The Mac peer is knit-peer on CoreBluetooth, run in the desktop session

Status: Accepted (2026-09-28)

**Context:** checklist M wants checklist L's first two groups with the Mac's CoreBluetooth as the radio, and
P7 a native Mac radio run. Checklist L runs `knit-peer` on BlueZ, driven by `scripts/interop.py` over its JSON
lines. KnitBLE, the iPhone's radio, already compiled for macOS but had never run on hardware anywhere but the
iPhone. A test binary on the Mac (2026-09-28) showed where it can run: started from ssh, CoreBluetooth reported
it unauthorized at once; started as a launchd job in the desktop session, it waited on the Bluetooth prompt. macOS
keeps a grant for a code signature, and an ad-hoc signature changes with every build.

**Decision:** `knit-peer` runs on a Mac, on `BLERadio`.

- **The peer:** each platform supplies a `PeerHost` behind `PeerRadioHost`, `BlueZHost` on Linux and
  `CoreBluetoothHost` on a Mac. The Mac's always runs the `ios` profile, since it cannot advertise service data
  either, and refuses the MTU knobs. `--radio-profile` now defaults to the radio's own profile. The binary carries
  an Info.plist in `__TEXT,__info_plist` with the Bluetooth usage string.
- **The session:** `scripts/mac-peer.sh build` builds it and signs it in the desktop session with the team's Apple
  Development certificate under the fixed identifier `app.getknit.knit-peer`, so one Allow at the Mac lasts across
  builds. `scripts/mac-peer.sh run` starts it through `scripts/mac-desktop.sh --stdio`, which feeds the job's
  standard input through a FIFO and keeps its standard error apart.
- **The driver:** `scripts/interop.py check --mac` and `soak --mac` run the peer there over ssh, with everything
  else unchanged: keygen on the Mac, the scan for nodes to refuse on `hci1`, and the phone through knit-next's
  bridge.

The alternative a reader reaches for first is the Knit app itself on the Mac, as a "Designed for iPad" build, with
its debug bridge. That tests the app's screens as well, but needs the Mac registered for the free team, a second
signed app and a loopback tunnel, and checklist L's scenarios would all need an app-shaped driver. A TCP control
port on `knit-peer` would also have worked; the FIFO needed no new code in the peer.

**Consequences / limits:**

- **Someone clicks Allow once,** at the Mac, on the first run after the signing identity changes. A new
  certificate means a new prompt.
- **The runner's account can use Bluetooth** as `knit-peer`, as it can already sign as the team (ADR 2026-09.zawh).
- **Rebuilding re-signs the binary in place,** which ends a peer that is running from it; `interop.py --mac`
  builds before it starts, so two runs must not overlap.
- **`scan` stays on Linux,** since it drives BlueZ directly.
- **The guards:** `interop.py check --mac` in both orders, and `soak --mac`. Nothing in CI runs a radio.
