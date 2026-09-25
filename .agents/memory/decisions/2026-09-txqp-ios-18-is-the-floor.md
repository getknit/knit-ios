---
id: "2026-09.txqp"
slug: ios-18-is-the-floor
title: "iOS 18 is the floor and the bundle id is app.getknit.knit"
date: 2026-09-25
topics: [platform, build]
---

# ADR 2026-09.txqp — iOS 18 is the floor and the bundle id is app.getknit.knit

Status: Accepted (2026-09-25)

**Context:** the knit-next review suggested iOS 17, the release that brought HPKE to CryptoKit. iOS 18 runs on
the same iPhones as 17 (the XS and XR and later) and adds `Synchronization.Mutex` and `Atomic` and newer
SwiftUI. iOS 26 drops the XS and XR. Android's floor is API 29, chosen for reach.

**Decision:** `platforms: [.iOS(.v18), .macOS(.v15)]`, which xtool turns into `MinimumOSVersion`. The bundle id is
`app.getknit.knit`, the same string as Android's application id, in Apple's separate namespace.
Xcode-signed development builds use `app.getknit.knit.dev`.

**Consequences / limits:** anything newer than iOS 18 needs an availability check. xtool installs development
builds under an `XTL-<team>.` prefix, so a Keychain identity made by an xtool install does not carry over to
an Xcode-signed build. `Package.swift` and `xtool.yml` hold the values; the built `Info.plist` shows them.
