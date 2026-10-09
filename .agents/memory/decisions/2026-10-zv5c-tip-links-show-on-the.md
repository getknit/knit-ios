---
id: "2026-10.zv5c"
slug: tip-links-show-on-the
title: "Tip links show on the US storefront only"
date: 2026-10-09
topics: [app, store, copy]
---

# ADR 2026-10.zv5c — Tip links show on the US storefront only

Status: Accepted (2026-10-09)
**Context:** Knit for Android has a Support Knit screen (`ui/donate/DonateScreen.kt`) with links out to Ko-fi,
Liberapay and GitHub Sponsors, then Rate Knit and Share Knit. App Store guideline 3.1.1 asks for in-app purchase when
an app takes money for its developer, and 3.1.3 bars buttons and links to other ways to pay. Since the court order of
30 April 2025, guideline 3.1.1(a) lets an app on the US storefront link out to pay without in-app purchase. Other
storefronts still reject such a link, or want a paid entitlement (the EU's StoreKit External Purchase Link).

**Decision:** the iPhone's Support Knit shows the three tip links only when StoreKit's `Storefront.current` says
`USA`. Everywhere else, and when StoreKit has no storefront (the Simulator, no Apple Account), the screen shows a
blurb that asks for a rating or a word to a friend, then Rate Knit and Share Knit. Rate opens the App Store page
with `action=write-review`; Share sends the App Store page (Apple id `6820348510`) with a line about Knit.
`SupportLinks.showsTips` holds the rule, and `SupportTests` checks it.

The alternatives were links everywhere, as Android has them, which App Review would reject outside the US; no tip
links at all, which gives up the one storefront that allows them; and an in-app purchase tip jar, which costs
products in App Store Connect, a purchase flow and Apple's commission, for what Android takes free of charge.

**Consequences / limits:** StoreKit joins the app target, in `Sources/Knit/Platform/` alone (`seam_storekit` in
`.swiftlint.yml`). A US user who moves storefront sees the links go, which is the point. Rate and Share point at a
page that only resolves once Knit is released. If Apple widens 3.1.1(a) to other storefronts, the change is one
line in `showsTips`; if it narrows it again, the same line goes to `false`.
