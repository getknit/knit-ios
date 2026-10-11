---
id: "2026-10.nwt2"
slug: knit-takes-the-exempt-export
title: "Knit takes the exempt export answer because its encryption is CryptoKit"
date: 2026-10-11
topics: [store, crypto, build]
---

# ADR 2026-10.nwt2 — Knit takes the exempt export answer because its encryption is CryptoKit

Status: Accepted (2026-10-11)

**Context:** ADR 2026-10.8cy5 set `ITSAppUsesNonExemptEncryption` = YES, reasoning that Knit seals messages with
its own scheme beyond what iOS provides. The first upload of 1.0.0 (build 1) failed on 2026-10-11 with "Invalid
Export Compliance Code": with YES, App Store Connect wants an `ITSEncryptionExportComplianceCode` that matches
approved export documentation. Its questionnaire, answered the same day, said Knit needs no documentation. Apple
requires documentation only for algorithms that are proprietary or non-standard, or for standard algorithms used
instead of, or beside, the encryption in Apple's operating system, and tells an app that needs none to say so in
Info.plist. The archived app showed why Knit needs none: its binary links `CryptoKit.framework`, makes 60 calls
into it, and holds no BoringSSL symbols. On Apple platforms swift-crypto's `Crypto` re-exports CryptoKit (`@_exported
import CryptoKit`), and Knit imports only `Crypto`, never `_CryptoExtras`, which is compiled from BoringSSL. 8cy5
mistook "Knit's own protocol" for "Knit's own encryption": the protocol is Knit's, but every primitive runs in iOS.

**Decision:** `App/Info.plist` sets `ITSAppUsesNonExemptEncryption` = NO, the answer for an app exempt from
documentation. The alternative, keeping YES and filing documentation for a code, files paperwork Apple says this app
does not need, and Apple would not issue a code for it. Deleting the key instead would make App Store Connect ask the
same questions for every build.

**Consequences / limits:** the key covers only what Apple needs. Whether US export rules still want something from
us, such as a yearly self-classification report to the Bureau of Industry and Security, is a separate question for
the export lawyer. The answer holds only while all of Knit's cryptography goes through CryptoKit: importing
`_CryptoExtras`, or vendoring a crypto library, puts non-OS standard algorithms in the binary and makes YES and
documentation the right answer again. `StoreDeclarationTests.theExportAnswerSaysKnitNeedsNoDocumentation` and
`check.sh release` (`check_release_app`) keep the key at NO; neither notices a new crypto import, so a change to
`KnitCrypto`'s imports or to `Package.swift`'s swift-crypto products comes back here.
