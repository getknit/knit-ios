---
id: "2026-10.kedu"
slug: knit-ships-for-iphone-only
title: "Knit ships for iPhone only"
date: 2026-10-03
topics: [platform, store]
---

# ADR 2026-10.kedu — Knit ships for iPhone only

Status: Accepted (2026-10-03)

**Context:** `App/project.yml` has set `TARGETED_DEVICE_FAMILY` to `"1,2"` since XcodeGen first generated the
project (ADR 2026-09.de8f), which made Knit an iPad app too. Nobody built it for an iPad or looked at it on one: the
accessibility audit runs on an iPhone 18 Pro (ADR 2026-09.jcdx), the device tests run on the iPhone 12, and the iPad
orientation key allowed landscape, which no screen was laid out for. A universal app gets reviewed on an iPad, and its
listing needs 13" iPad screenshots. The choice is also one-way: App Store Connect refuses a build that drops a device
family an earlier version supported, while a later version can add one.

**Decision:** iPhone only. `TARGETED_DEVICE_FAMILY` is `"1"` for the app and for both UI test bundles, and the iPad
orientation key is gone. An iPad still runs Knit, in iPhone compatibility mode: scaled up and in portrait. Keeping
`"1,2"` would have meant an iPad layout pass, an iPad in the audit and a second set of screenshots, all for a device
nobody has asked for, and it could not be taken back after launch.

**Consequences / limits:**

- **An iPad can still install Knit** and join the mesh in compatibility mode, and App Review may try it there. The
  7th-generation iPad still cannot scan a code (ADR 2026-10.65xx).
- **Macs with Apple silicon** list iPhone apps in the Mac App Store unless the app's availability in App Store Connect
  opts out. That is a listing choice, not a build setting.
- **Adding the iPad later** means `"1,2"` again, the iPad orientations, an iPad run of the audit and the screenshots,
  and a new ADR that supersedes this one.
- **The guard:** `scripts/check.sh release` fails when the built app's `UIDeviceFamily` is anything but `[1]` (ADR
  2026-10.8cy5), and CI's `build:ios:release` runs it on every pipeline.
