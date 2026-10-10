---
id: "2026-10.7uyt"
slug: whitespace-is-what-art-says
title: "Whitespace is what ART says it is"
date: 2026-10-10
topics: [interop, wire, text]
---

# ADR 2026-10.7uyt — Whitespace is what ART says it is

Status: Accepted (2026-10-10)

**Context:** knit-next decides what counts as whitespace in two places. `normalizeSingleLine` (`TextLimits.kt:47`)
and `NameKey` (`PeerLabels.kt:270-272`) collapse runs of Java regex `\s`. `trim()` and `isBlank()` use Kotlin's
`Char.isWhitespace()`. The port's first commit modelled both on the desktop JVM: `\s` as ASCII
`[ \t\n\x0B\f\r]`, and `isWhitespace` as Java's separators plus `\t`–`\r` and `\u{1C}`–`\u{1F}`. No ADR made
that choice. Android's JVM unit tests run on the desktop JDK too, so nothing caught it.

The interop audit of 2026-10-09 (AND-13 = IOS-2) found that ART differs. Its `java.util.regex` is ICU, where `\s` is
Unicode White_Space (android-36.1 `Pattern.java:178-179`). So the platforms disagreed on what a name, status or
group name normalizes to, and on the "Name (Alias)" clash label for names holding U+0085, U+1680, U+2028 or U+2029.
The audit also read ART's `Character.isWhitespace` hard-coding U+180E (`Character.java:11812-11815`), though
Unicode moved U+180E into Cf in 6.3.

**Decision:** whitespace is what ART reports, pinned code point by code point. knit-next's instrumented test,
`app.getknit.knit.text.ArtTextSemanticsTest`, walks the BMP on an emulator and reads both sets:

- **Kotlin's `isWhitespace` on ART:** U+0009–U+000D, U+001C–U+0020, U+00A0, U+1680, U+2000–U+200A, U+2028,
  U+2029, U+202F, U+205F, U+3000.
- **Regex `\s` on ART:** U+0009–U+000D, U+0020, U+0085, U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029,
  U+202F, U+205F, U+3000.

U+180E is in neither. The test found that ART's answer for it follows the ART mainline module, not the API
level: whitespace up to API 36's module, and not from API 37's, as in Unicode 6.3 and the desktop JDK. An iPhone
can't know which module a phone runs, so the law takes ART's current answer.

So the `isWhitespace` set is the one the port already had, read from Swift's separator categories; only regex
`\s` widens. Both are now pinned lists.

`TextLimits.isKotlinWhitespace` and `isJavaRegexWhitespace` are those two lists as literal scalar ranges. They
don't read Swift's Unicode properties, so a newer Unicode table in Swift can't move them away from ART. The
obvious alternative was Swift's `properties.isWhitespace`, which is White_Space. That fits regex `\s` today, but
it isn't the `isWhitespace` set, and it would track Swift's Unicode version, not ART's.

The two sets differ, so order matters. `normalizeSingleLine` trims and then collapses, while `NameKey` collapses
and then trims, as each Kotlin function does. A U+0085 at the end of a name survives `normalizeSingleLine` as a
space but leaves the name key. `TextLimits.trimmed` and `collapsingWhitespaceRuns` are public so `NameKey` and
`Composer` can use them in Android's order.

**Consequences / limits:** no wire bytes change. A profile already stored keeps the text it was sent with, and
only names normalized from now on collapse the wider set. The desktop JDK still answers ASCII, so a Kotlin unit
test can't stand in for ART, and the device test is the source of truth. If a later ART module changes
either set, re-run it and move the lists here.

A phone on an ART module older than API 37's still trims a U+180E at either end of a name, and takes a rename
to U+180E alone as blank, so it keeps the old group name while an iPhone shows the new one. That residue is
accepted. `NameKey` drops U+180E as a format character on both sides, so the clash label agrees.

The tests that keep this true are `TextLimitsTests.everyCodePointIsWhitespaceExactlyWhereARTSaysSo`, which walks
every scalar against the pinned lists, the audit repros in `InteropAuditWireTests`
(`mongolianVowelSeparatorIsNotWhitespaceAsOnCurrentART` pins the U+180E ruling), and
`PeerLabelsTests.aNameKeyFoldsTheSpacesARTMatches`. Search screening (`WordFilter`, `GeoTokens`, the tokenizer)
and `Monogram` keep their own whitespace rules. They decide nothing another phone sees.

A lone surrogate is out of scope here. On ART, `toByteArray(UTF_8)` turns one into `?`. A Swift `String` can't
hold one, and the UTF-16 cut that could make one is the order `android-interop-hardening`.
