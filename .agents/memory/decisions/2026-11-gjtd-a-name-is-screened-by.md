---
id: "2026-11.gjtd"
slug: a-name-is-screened-by
title: "A name is screened by the word lists when it is set and when it is drawn"
date: 2026-11-14
topics: [moderation, interop, text]
---

# ADR 2026-11.gjtd — A name is screened by the word lists when it is set and when it is drawn

Status: Accepted (2026-11-14)

**Context:** knit-next ADR 2026-11.y4pc screens names with the word lists. It shipped in `ec44d865a`, which is
`4e782849e` rebased onto `main` with the same patch. Your own name and status are refused when you set them, against
the room's rules: slurs and profanity, whatever the Content filtering toggle says. While the toggle is on, someone
else's flagged name draws as if it were blank, so their alias shows, and a flagged status shows nothing. A group's name
is read against the slur list alone, except on the Message Requests list, where a stranger made the group and both lists
apply. Nothing is stored and no wire byte moves.

The iPhone screened none of this (knit-ios #54). Its one word screen, `WordFilter`, read messages alone. An iPhone user
could set any name, and the iPhone drew every received name in full. It also carried the bug knit-next `df7d33012`
fixed (`4e47bc5` before the same rebase). `Profanity.txt` has `xxx`, which collapses to `x`, and `WordFilter` tested
every word's collapsed form, so a lone "x" was blocked in the room.

y4pc measured why names need a matcher of their own. The toxicity model caught about one offensive name in a hundred,
and whole words miss most usernames (`BigD1ck69`, `xXslurXx`).

**Decision:** the iPhone takes Android's rules and its lists, and draws a hidden name through the same alias path.

- **The lone x:** a word meets the collapsed set only when collapsing changed it, as `LexicalTextFilter.isBlocked`
  does now.
- **The matcher:** `NameScreen` in `KnitAppCore/Moderation/` ports `NameScreen.kt` line for line. It reads a name as
  written, camel-split and with digit runs as spaces. It looks inside words for the embeddable terms alone, after
  cutting at the exclusions, and reads a digit as a leet letter there only between two letters. A real name in plain
  letters passes, and a slur never does.
  - It reads text as `java.util.regex` does on ART, which runs ICU. The classes go per code point by general category,
    and `\s` is White_Space (`TextLimits.isJavaRegexWhitespace`). The digit rule walks UTF-16 units, as Kotlin's `Char`
    does, so `big𝐩1𝐤𝐞𝐲boy` passes on both phones.
  - These are hand-written scanners. Swift's `Regex` and `NSRegularExpression` differ from ICU on Linux (`ICUText`
    says how).
  - knit-next's compiled `NameScreen`, run on the JDK over the shipped lists on 2026-11-14, gave every verdict
    `NameScreenTests` holds for the corners the vectors leave out.
- **The lists:** knit-next's `name_embeddable_en.txt`, `name_exclusions_en.txt` and `name_allowed_en.txt`, copied byte
  for byte as `App/Models/NameEmbeddable.txt`, `NameExclusions.txt` and `NameAllowed.txt`. knit-next's
  `scripts/gen-name-screen-lists.py` generates them, and nobody edits them by hand.
- **The contract:** knit-next's `vectors/name-screen-v1.json` is mirrored ahead of the pin, from `2c32655b`, which
  holds it as `ec44d865a` made it. `sync-vectors.py` takes it as an optional file.
- **When it is set:** `OwnProfileModel.save` and the name page's `OnboardingModel.next` screen with the room's rules,
  whatever the toggle says.
  - A flagged value publishes nothing, the photo included. What was typed stays, and a note under the field says why
    until the field changes.
  - It is a note and not an alert, for the reason ADR 2026-10.spcy gave for the photo. VoiceOver hears it as an
    announcement, since Save no longer closes the screen.
  - A session with no screen refuses nothing, as Android's fails open, and a modified client can skip it.
- **When it is drawn:** with the filter on, `AppSession.directory` hands `Directory` its `ShownNames`.
  - `PeerLabelIndex` presents every peer's stored name, then writes ours as it is, so our own name never hides.
    `label(for:storedName:)` presents a raw name a caller holds, so a contact card's name and an id outside the index
    read as the index's own would.
  - `NameKey.isBlankName` then does what it does for a name of invisible characters. `Alias.displayName`, in
    crypto-gated KnitCrypto, does not change.
  - The profile draws a hidden status as nothing.
  - `GroupNaming` reads a group's name with the slur list, and `RequestsModel` with both.
- **What the screen reads:** the cleaned group name, the one that is drawn. Android screens a group's stored name
  and cleans it only to draw it. So a bidi control inside a slur, `pi\u{202E}key club`, splits the word for Android's
  screen, then goes, and the slur draws. People's names are stored cleaned on both phones, so only group names differ.
  The upstream issue is knit/knit-next#323.
- **The cache:** `ShownNames` keeps 8,192 verdicts, as `ShownNames.kt` does, in two generations rather than one LRU
  list.
  - Neither generation outgrows half the bound, a move from the older one included, so a table read on every rebuild
    cannot grow it.
  - A text is keyed by its UTF-8 bytes, because Swift's string equality would make a composed "Díck" and a decomposed
    one a single key, and the screen reads them apart.
- **Reports keep what they report** (ADR 2026-10.f6kf). This part is iPhone-only. A report carries the name a person
  set when the filter showed their alias, as "Name they set", and their status as received. A report from a group
  names the group as it named itself.

The alternatives:

- **Running names through `TextScreening`,** the message pipeline. y4pc's table shows why that fails: whole words miss
  half the shapes a username takes, and the model catches almost nothing.
- **A stored verdict column.** It would need a migration and a backfill whenever the lists move, and a stale column
  would keep hiding a name the new lists allow.
- **Screening in `Alias.displayName`.** That would put moderation inside KnitCrypto, which every frame's label and the
  control lines also read raw.

**Consequences / limits:**

- **Cost:** the first directory over 2,000 names the screen has not seen took about 140 ms more in a release build on
  Linux, about 70 µs a name. A rebuild that hits the cache costs what one without the screen does.
- **Not on the iPhone,** so not screened: calls, conversation shortcuts, a person's rename and photo notices, and
  Meshtastic names. The iPhone has none of them.
- **Left as on Android:**
  - A quote's author name and a mention's name follow the label, so a hidden name is quoted and mentioned as the
    alias.
  - Names typed into a message's words are screened as words.
  - A notification already posted keeps its title when the toggle turns on.
  - The recall hole y4pc names: a run-together lowercase handle built on a term a real word holds, such as `bigshit`,
    passes.
- **The trap** is a surface that reads `PeerRecord.name`, `PeerRecord.status` or `GroupRecord.name` straight from the
  store. It draws a flagged name in full. Every surface goes through `Directory`'s labels, `Directory.shown` or
  `GroupNaming`. A report is the exception, and it reads the stored values on purpose.
- **The guards:**
  - `NameScreenTests`, `NameListsTests` and `NameScreenVectorTests` for the matcher, the lists and the contract.
  - `ShownNamesTests` for the cache.
  - `NameScreeningTests` for labels, statuses, group names, requests, notifications, contact links, reports and both
    refusals.
  - `WordFilterTests.aTermThatCollapsesToOneLetterMatchesOnlyWhenWrittenOrStretched` for the lone x.
  - `ModelAssetTests.theNameListsAreAndroids` and `check.sh xcode`'s bundle check for the files.
  - `KnitUITests.walkContentFilter` for the profile's note.
