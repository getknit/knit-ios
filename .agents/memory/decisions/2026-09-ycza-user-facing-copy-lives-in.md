---
id: "2026-09.ycza"
slug: user-facing-copy-lives-in
title: "user-facing copy lives in one catalog in KnitAppCore"
date: 2026-09-26
topics: [copy, app]
---

# ADR 2026-09.ycza — user-facing copy lives in one catalog in KnitAppCore

Status: Accepted (2026-09-26)

**Context:** Knit's words carry claims that must stay true: what encryption covers, what the Nearby room
exposes, and that an iPhone finds new people only while Knit is open (`.agents/rules/copy.md`). Scattered
through SwiftUI views, a claim can drift in one screen and not another, and the product-language pass never
sees all of it. The views compile only for iOS, so a string there is out of reach of every Linux test. Spike
(d) found that Foundation on Linux has no `LocalizationValue`, so `String(localized:)` cannot build in
`KnitAppCore`.

**Decision:** every string a person reads lives in `Copy`, under `Sources/KnitAppCore/Copy/`, one nested enum
per screen: onboarding, the status line, the chat list, a thread, requests, profiles, Settings, About,
Diagnostics, notifications and the launch screen.

- **Each string is one literal `NSLocalizedString(_:bundle:value:comment:)` call**, so Xcode extracts it into a
  String Catalog unchanged, and the English is the `value`. A long value is a multi-line literal whose line
  breaks are escaped, still one literal to the extractor.
- **Counts are two keys, `.one` and `.other`,** picked in code. English needs no more, and a translation can move
  a pair to the catalog's plural rules.
- **Views read the catalog and never hold a literal.** View models build their text from it, which keeps a
  string's formatting under a Linux test.
- **Text outside Swift keeps a copy the tests hold equal.** `App/Info.plist`'s Bluetooth usage string matches
  `Copy.System.bluetoothUsage`, and About's component list matches `THIRD-PARTY-NOTICES.md`.
- **The catalog passed `product-language-editor`, then `humanizer`,** as `.agents/rules/copy.md` requires, and
  every edit to it does again. Android's `strings.xml` was the starting point, adapted to Bluetooth only.

The alternative, a `Localizable.xcstrings` file as the source, is Xcode's own format. It needs Xcode to edit
well, and nothing on Linux would read it.

**Consequences / limits:**

- **No translations yet.** The catalog uses `bundle: .main`, so a String Catalog added to the app target later
  takes effect without touching the code.
- **Plural rules beyond one and other** wait for the first language that needs them.
- **Guards:** `CopyTests.everyKeyInTheCatalogIsUsedOnce` (a repeated key would collapse in the catalog),
  `noViewTextLivesOutsideTheCatalog`, `infoPlistAsksForBluetoothInTheCatalogsWords` and
  `aboutListsWhatTheNoticesFileShips`; `CopyCatalogTests` reads every string and fails on a doubled space,
  a stray line break or an unfilled placeholder, which is what a slip in wrapping a literal leaves.
