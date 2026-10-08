---
id: "2026-10.5u39"
slug: store-screenshots-come-from-a
title: "Store screenshots come from a UI-test walk in the Simulator"
date: 2026-10-07
topics: [testing, store, ui]
---

# ADR 2026-10.5u39 — Store screenshots come from a UI-test walk in the Simulator

Status: Accepted (2026-10-07)

**Context:** the App Store wants 6.9-inch iPhone screenshots, and the release checklist said only "use
`-demoScene marketing`". The commands for one shot were in `commands.md`: boot a Simulator, install, launch with the
demo's flags, `simctl io screenshot`, pull. That is one screen. Everything past the chat list sits behind taps, and
the app takes no deep links. knit-next opens its screens by deep-link route and captures them with `adb`, from a
script in its private overlay. Here that overlay never reaches the Mac: `scripts/mac.sh` mirrors tracked files only,
and the Mac is the only place the app runs.

**Decision:** a UI-test target, `KnitShots`, that only the `KnitShots` scheme runs, and a gate,
`scripts/check.sh shots`, that runs it on the Mac.

- **The walk:** one test per screen the listing shows, on `-seedDemo -demoScene marketing`. Each launches the app,
  taps through to its screen, waits for it to hold still, and keeps the whole screen as an attachment named
  `<light|dark>_<shot>`. It reuses `Walking.swift` and `AccessibilityID`, the same as the device
  tests do.
- **The gate:** the Simulator is "Knit shots", an iPhone 18 Pro Max, whose 1320x2868 screenshots are the size App
  Store Connect takes, so nothing is scaled. Before the run it freezes the status bar at 9:41, with a full battery and
  no cellular or Wi-Fi bars: Knit needs neither. It runs the walk once in light and once in dark, then exports the attachments with `xcresulttool export
  attachments` and names each PNG after its attachment, in `.build-xcode/shots/`. If a shot fails, the gate still
  exports the rest, then fails.
- **What stays private:** pulling the PNGs, framing them with captions, and the captions themselves, in
  `.private/scripts/`, as in knit-next.

The alternative a reader reaches for first is knit-next's: deep links, or a debug-only `-demoOpen <screen>` flag,
then `simctl io screenshot` from a shell script. That would mean new debug-only surface in the app for
`check.sh release` to police, and a second way to reach every screen next to the UI tests' taps. A UI-test walk
already knows the way there. The other is fastlane's `snapshot`, which is the same XCUITest walk with Ruby and a
dependency on top.

**Consequences / limits:**

- **It checks nothing.** No CI job runs it, and a screen that changes still photographs. A screen that never
  appears fails its test, and that is the only signal.
- **The shots are only as good as the scene.** New content for a shot goes in `DemoCast.marketing`, which the
  photo, scrolling and content-filter walks also run on.
- **It takes the Mac for about five minutes:** 13 shots, run once in light and once in dark, took 4.7 minutes of testing
  on 2026-10-07, once the app was built, on a Mac shared with both repos' CI runners. "Knit shots" is its own
  Simulator, so it never takes CI's or a local `uitest` run's, but it competes with them for CPU.
- **The gate sets the appearance, not the test.** The first runs set `XCUIDevice.appearance` from the test, as
  `KnitUITests` does. The Simulator then reported dark and drew light, Apple's Settings app included, and all 13 dark
  shots came out byte for byte the light ones. The same call draws dark in `KnitUITests`' dark walk, in "Knit local",
  and the difference was not found. `simctl ui <device> appearance` is drawn at once, so the gate boots the
  Simulator afresh, builds the walk once, and runs it once per appearance with `simctl ui` between, telling the walk
  which in `KNIT_SHOT_MODE`. If a dark set ever matches the light one, look at the appearance first.
- **Not covered:** the scanner (the Simulator has no camera), the system's notification banner, and video. App
  previews need footage of the app moving, which a walk of still screens does not give.
- **The guards:** `check.sh xcode` builds the `KnitShots` scheme for testing, so `build:ios:xcode` fails when the walk
  stops compiling. Each test throws `Missing` when its screen never appears.
