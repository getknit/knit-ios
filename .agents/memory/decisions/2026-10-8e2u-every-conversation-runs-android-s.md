---
id: "2026-10.8e2u"
slug: every-conversation-runs-android-s
title: "Every conversation runs Android's slur list before the model"
date: 2026-10-07
topics: [moderation, privacy]
---

# ADR 2026-10.8e2u — Every conversation runs Android's slur list before the model

Status: Accepted (2026-10-07)

**Context:** knit-next ADR 2026-10.d62w measured why a slur sent in a DM passed: Detoxify scores a slur aimed at a
person as `insult`, a label neither phone holds against a message, and `identity_attack` stays near 0.06. On iOS a
DM or a group ran the model alone (ADR 2026-10.e4kz), so the iPhone let the same slurs through, on sending and on
arrival. Knit for Android fixed this the same day with a second generated word list, `slurs_en.txt`, which runs first
in every scope. App Review tests the content filter for guideline 1.2, and a slur in a DM is an obvious test.

**Decision:** the same list, run in the same place.

- **The list** is knit-next's `app/src/main/assets/moderation/slurs_en.txt` at `3a6f5d08`, byte for byte, bundled as
  `App/Models/Slurs.txt`. `ModelAssetTests` and `tools/models/toxicity/common.py` pin its hash beside
  `Profanity.txt`'s. knit-next's `scripts/gen-profanity-list.py` generates it from the same dsojevic corpus: the
  `racial` and `religious` tags at severity 3 or more, three hand-picked slurs against gay and trans people, and
  plurals. It leaves out in-group and everyday words (`nigga`, `coon`, `fag`, `queer`, `negro` and more). Never edit it
  here: change the generator's dials in knit-next, regenerate, and copy it again.
- **The order** (`TextScreening.isAbusive`): the slur list in every conversation, then the profanity list in the
  Nearby room, then the model. This is `ScopedTextModerator`'s chain. The same `WordFilter` matcher reads both lists,
  so leetspeak and stretched or spaced-out letters are caught alike.
- **Where it applies:** wherever the iPhone screens words: someone else's message on arrival, in every conversation,
  hidden behind Content filtering, and our own on sending, in Nearby only since ADR 2026-10.spcy.
- **Wiring:** `TextScreening.bundled` loads both lists from the app. A missing list is logged and skipped, as
  `Profanity.txt` was before. About lists the file under the same MIT notice.

**Consequences / limits:**

- **A DM that quotes or discusses a slur is hidden on arrival**, behind tap-to-show. Known false
  positives are the ones d62w names: `faggot` as a British dish and `tranny` as slang for a gearbox. It is English only.
- **Screening on sending** in DMs and groups ended the same day: ADR 2026-10.spcy mirrors knit-next ADR 2026-10.9rh6.
- **The aliases** come from the same word lists as Android's, byte for byte (`AliasTests`). knit-next's `AliasTest`
  checks them against both word lists, so the iPhone relies on that check rather than repeating it.
- **The guards:** `SlurListTests` (knit-next's `SlurListTest`: the slurs the model misses and their plurals, the
  in-group and everyday words left out, the evasions caught, and ordinary private speech passing),
  `TextScreeningTests.everyConversationRunsTheSlurListBeforeTheModel`, `ModelAssetTests`' pin, the notices test, and
  `check.sh release`, whose build carries the file.
