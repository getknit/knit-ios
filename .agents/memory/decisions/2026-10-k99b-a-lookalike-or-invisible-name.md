---
id: "2026-10.k99b"
slug: a-lookalike-or-invisible-name
title: "A lookalike or invisible name gets a discriminator, and received names are cleaned"
date: 2026-10-29
topics: [interop, text]
---

# ADR 2026-10.k99b — A lookalike or invisible name gets a discriminator, and received names are cleaned

Status: Accepted (2026-10-29)

**Context:** a label shows a name alone, and adds the alias as `Name (Alias)` only when another identity this
phone knows has the same `NameKey`. The key was NFKC, lower-cased, format characters dropped and whitespace
collapsed. It folded no lookalikes, and a test recorded that as a limit. So a stranger in Nearby could call itself
"Alice" with a Cyrillic е, a Greek ο, a capital I for the l, a variation selector, U+034F, a Hangul filler or the
Braille blank. It then read as a plain "Alice" beside a contact of that name, with no suffix on either. A name made
only of those characters wasn't blank to `TextLimits.isBlank`, so it showed as nothing instead of the alias. A
received name or status was only cut to length, so a line break, a control or a bidi override reached every header
that showed it. This is H8 and the "names" item of knit-next's malicious-fork review (knit-next #228, knit-ios #30).

**Decision:** both ports take one contract, paired change `name-confusables`, and Android leads with knit-next ADR
2026-10.2kfr. No wire byte moves. The key is never stored or sent, and each port computes its own.

- **`NameKey.of`** moves down to `KnitWire/Identity/NameKey.swift`, so `Alias` in KnitCrypto can call it. It runs
  NFKC, then folds 73 lookalikes on the case-preserved string, then lower-cases and folds ς to σ and l to i, then drops
  Cf, Mn, Me, Unicode 15.1's Default_Ignorable_Code_Point ranges and U+2800, then collapses and trims whitespace.
  The fold is every UTS #39 15.1.0 `confusables.txt` entry from one Latin, Greek or Cyrillic code point to one
  ASCII letter. It runs before lower-casing because UTS #39 is case-sensitive. The ς step makes Java's Final_Sigma
  and Swift's lack of it agree. The l step is contract revision 3: the table's own capital I → l had stopped
  "ALICE" keying with "Alice", so I, i, l and their lookalikes now share one letter, and all three key `aiice`.
- **The fold and the drop ranges are literal constants**, as ADR 2026-10.7uyt made the whitespace sets. Swift's
  Unicode tables follow the OS, and Android's follow ART's ICU module, so a derived table would drift between the
  two. Cf, Mn and Me still come from `generalCategory`. A code point assigned after the older side's Unicode version
  may be categorised differently there, a residue accepted as U+180E's was.
- **`NameKey.isBlankName`**, null or an empty key, decides whether a person shows the alias and a group its member
  title: `Alias.displayName`, `PeerLabelIndex.tokensInName` and `GroupNaming`. The first two must flip together, or
  a U+3164 name renders `Alias (Alias)`. What a group frame carries, and every composer gate, still follow
  `TextLimits.isBlank`, so a U+3164 group name is still a name on the wire.
- **`TextLimits.cleanReceived(_:limit:)`** strips the C0 and C1 controls outside regex `\s` and the bidi
  controls, runs `normalizeSingleLine`, cuts to the limit and trims both ends again (contract revision 1). A
  received profile's name and status are cleaned when stored, in `profileRecord` and `applySealedPresentation`. The
  signed profile frame kept as proof of key stays byte-exact.
- **A group name is cleaned at display, never at store.** Both ports sign the stored name into their own group
  frames, so cleaning it at store would change what we author and spread the cleaned name last-writer-wins. That is
  a convergence change and out of scope. `GroupNaming.title` and the rename notice in `GroupNaming.notice` clean it,
  then test `isBlankName` on the cleaned name (contract revision 2). A name of controls alone has a key but cleans to
  nothing, and it takes the member title like an unnamed group.

The obvious alternative is UTS #39's full skeleton, as ICU's spoof checker computes it. It folds across every script
and into multi-character sequences, so it joins real names far more often. It also follows the platform's Unicode
version, which an iPhone and a Pixel rarely share, and Swift has no API for it on Linux.

**Consequences / limits:** a collision only costs a suffix, so the key folds generously. Two real names that fold
together, such as a Hindi name with and without a vowel sign, both show their alias words. Nothing is merged,
hidden or refused. Names that differ only by i and l, such as "Eli" and "Ell", share a key. Rows stored before this build keep their raw name until that peer's next profile, and there
is no migration. Multi-character lookalikes (`rn` for `m`) and digits (`0` for `O`) aren't folded. Names shown
outside the label index aren't cleaned: a heard Meshtastic `longName`, a mention highlight's name, a quote author
and a relay invite's room. Neither is a contact link's card name, which `MeshEngine+Contacts` stores after
`normalizeSingleLine` alone. Each of those is a follow-up issue.

The tests that keep this true are `NameKeyVectorTests`, which hold the fold table, the drop ranges and every case
against knit-next's `vectors/name-key-v1.json`. Alongside them, `NameKeyTests`, `TextLimitsTests.cleaningIsIdempotent`
and `theStripSetIsTheContracts`, `PeerLabelsTests.aLookalikeOfAContactsNameDiscriminatesBoth` and
`anInvisibleNameShowsTheAliasAlone`, `GroupListTests.aGroupNameIsCleanedWhereItIsShown`, and the two profile tests,
`MeshEngineProfileTests.aReceivedProfileStoresACleanedNameAndKeepsItsFrame` and
`MeshEngineRatchetProfileTests.aSealedProfileStoresACleanedNameAndStatus`.
