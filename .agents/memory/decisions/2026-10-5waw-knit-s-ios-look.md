---
id: "2026-10.5waw"
slug: knit-s-ios-look
title: "Knit's iOS look: the HIG and Liquid Glass, Signal's layout, Android's coral and stitch"
date: 2026-10-04
topics: [ui, accessibility, brand]
---

# ADR 2026-10.5waw — Knit's iOS look: the HIG and Liquid Glass, Signal's layout, Android's coral and stitch

Status: Accepted (2026-10-04)

**Context:** the screens passed the accessibility audit (ADR 2026-09.jcdx), but they were stock SwiftUI with a blue
tint, `#0A5CC7`, that nothing else in Knit wears. Android's brand is coral: `Color.kt` seeds its theme from `#E55E4C`
and uses `#BD4030` as the light primary (its ADR 2026-09.m9h8). The rest of the brand is a slate `#454551`, a fixed
green for healthy states, and a "K" drawn as stitched dashes, which is the launcher icon, the room's face and the
notification icon. The maintainer asked for four things:

- Signal's layout wherever it fits.
- A light Knit flourish.
- An app that follows Apple's Human Interface Guidelines and uses Liquid Glass, the look iOS 26 brought in and iOS
  27 refined.
- Every accessibility guarantee kept.

Two facts constrain this:

- **The brand coral cannot carry text.** `#E55E4C` reads 3.5:1 under white.
- **Glass already failed the audit once.** It let the thread show through the composer and the request bar, which
  is why ADR 2026-09.jcdx made every bar under text opaque. iOS 18 is the floor (ADR 2026-09.txqp), and it has no
  glass API at all.

**Decision:**

- **Coral is the tint.** Light uses `#BD4030`, the same value as Android's light primary: white on it reads 5.33:1,
  and it reads 4.78:1 as text on `#F2F2F7`. Dark uses `#FF8A73`: 6.06:1 on `#2C2C2E`, under black labels.
- **Bubbles follow Signal.** Our own bubble is solid coral under white text: `#BD4030`, or `#A8392A` in dark, where
  white reads 6.40:1. Other people's bubbles are an opaque gray.
- **Swatches are tested where they live.** Every swatch is a value in KnitAppCore's `Swatches`.
  `SwatchContrastTests` measures each text color on Linux against every system surface text sits on:
  - in light, `#FFFFFF` and `#F2F2F7`;
  - in dark, `#000000`, `#1C1C1E` and `#2C2C2E`.

  Text must reach 4.5:1, and 7:1 with Increase Contrast on, which `Palette` reads from the trait collection. Views
  take their colors from `Palette` and nowhere else.
- **The mark is Android's.** `KnitMarkPath` keeps the path data from `ic_launcher_monochrome.xml` exactly as it is
  and parses it, arcs included. `KnitMark` draws it. It is the Nearby room's face, coral under the white mark, as
  `ic_knit_room` draws it.
- **Glass goes on controls and navigation, never under text.**
  - The system bars and sheets take it from the SDK.
  - `prominentButton()` is `.glassProminent` from iOS 26, and `.borderedProminent` before.
  - Text sits on an opaque fill even inside a glass container. Custom glass falls back to opaque on iOS 18 to 25,
    and whenever Reduce Transparency is on.
- **The layout is Signal's, in one `NavigationStack`.**
  - On the chat list, your face at the top left opens Settings and compose sits at the top right, with a small
    title between them.
  - In a thread, the title opens the profile or group info. Bubbles cluster, with tight corners where they join.
  - Profiles get a centered header.
  - The thread keeps its lock button. That is where Knit departs from Signal, because the button says exactly what
    is encrypted.
- **Search will be a `.searchable` on that stack.** iOS 26 puts its field at the bottom on the iPhone, and its results
  will follow Android's sections: Chats, People and Messages.
- **The audit walks in dark mode too.** `testEveryScreenInDarkMode` walks every screen at the default size.

The alternative a reader reaches for first is Signal's tab bar. Signal has three sections (Chats, Calls and Stories);
Knit has one, and Android has no bottom bar for the same reason. Two tabs, Chats and Settings, would add a bar to hold a
button the chat list already has. The other alternatives:

- **Keep the blue.** That would make the two apps look like different products.
- **Use `#E55E4C` as it is.** It fails contrast wherever it labels anything.
- **Glass under the composer's words.** It is the defect ADR 2026-09.jcdx fixed.

**Consequences / limits:**

- **iOS 18 to 25 get no glass.** The same screens draw opaque bars and bordered buttons there.
- **Increase Contrast is measured on paper, not on screen.** The audit runs only with it off. The 7:1 values are
  for that setting alone, and the default ones stay at Android's.
- **The dark walk costs as much as the default walks.** On 2026-10-04 it took 547 seconds, and the whole
  `test:ios:simulator` run took 30 minutes, on a runner that takes one job at a time. The job sets no timeout of its
  own, so the project's applies.
- **The mark follows Android only when someone copies it.** A change to Android's icon means pasting its new path
  data into `KnitMarkPath`; nothing syncs it. `KnitMarkPathTests` checks that it still parses into seven stitches
  that fill the unit square.
- **The trap:** a color written straight into a view, such as `.red`, a system gray, or the brand's `#E55E4C`. It
  skips `SwatchContrastTests`, and the audit catches it only in light or dark at the default size, never with
  Increase Contrast on.
- **The guards:** `SwatchContrastTests`, `KnitMarkPathTests`, `KnitUITests`' `testEveryScreenInDarkMode`, and the
  audit's `AuditPolicy`, which carries no exemption for glass under text.
