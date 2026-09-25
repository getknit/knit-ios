---
id: "2026-09.5phg"
slug: knit-for-ios-is-gpl
title: "Knit for iOS is GPL-3.0-or-later with an App Store exception"
date: 2026-09-25
topics: [license, legal]
---

# ADR 2026-09.5phg — Knit for iOS is GPL-3.0-or-later with an App Store exception

Status: Accepted (2026-09-25)

**Context:** Knit is GPL-3.0-or-later, and contributions come in under the DCO with no CLA. The FSF's
position is that App Store terms add restrictions the GPL forbids; VLC was pulled from the store in 2011 on
that ground. Without a CLA the maintainer cannot relicense other people's contributions later, so any
permission has to exist before the first outside contribution.

**Decision:** GPL-3.0-or-later plus an additional permission under GPLv3 section 7, in `APP-STORE-EXCEPTION.md`.
It allows conveying the program through an app store, subject to that store's terms, on the condition that
the Corresponding Source of each version is available free of charge without the store. `COPYING` stays
the verbatim license, and contributions are accepted under both. Plain GPL, the other option, keeps the
maintainer's own code shippable but lets any accepted contribution block a store build. A CLA would work
too, and asks more of every contributor.

**Consequences / limits:** section 7 lets a recipient remove the permission from their copy, and a fork
without it cannot ship to the store. This is not legal advice: a lawyer reads the exception before the
first outside contribution. `RepoConventionTests.LicenseTests` pins `COPYING` to the FSF text and checks that
the exception names section 7, and the merge request template asks every contributor to confirm the terms.
