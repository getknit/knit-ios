---
id: "2026-10.e4kz"
slug: messages-from-others-are-screened
title: "Messages from others are screened as they arrive, by Android's Detoxify model in Core ML"
date: 2026-10-04
topics: [moderation, store, app, build]
---

# ADR 2026-10.e4kz — Messages from others are screened as they arrive, by Android's Detoxify model in Core ML

Status: Accepted (2026-10-04)

**Context:** ADR 2026-10.rpmq screened photos and left words for later. App Store guideline 1.2 asks for both.
Knit for Android screens words like this (knit-next `docs/CONTENT_MODERATION.md` §2 and §4, `MlTextModerator.kt`,
`ScopedTextModerator.kt`, `LexicalTextFilter.kt`):

- **The model:** Detoxify's `unbiased-small`, an ALBERT base v2 trained on Jigsaw's Unintended Bias data, as a
  dynamic int8 TFLite. Its 16 sigmoid outputs are seven toxicity labels and nine identity topics. A message blocks
  when `severe_toxicity` or `identity_attack` reaches 0.85, `sexual_explicit` 0.8, or `threat` 0.9. Rudeness
  (`toxicity`, `insult`, `obscene`) and the topics never block.
- **The room** runs a word list first (`profanity_en.txt`), which sees through leetspeak, stretched letters and
  spaced-out letters. DMs and groups run the model alone. A shared `geo:` position comes out of the words first.
- **Sending:** `MeshManager.sendChat` refuses a flagged message whatever the toggle says, and the draft stays.
- **Receiving:** `InboundPipeline.inboundModeration` classifies a message on its first delivery and stores the verdict
  on its row (`MessageEntity.moderation`). With Content filtering on, the bubble collapses behind a tap, search leaves
  the message out, and a reply quote does not show it. Notifications and the chat list show the words.

The maintainer chose on 2026-10-04 to screen each message as it arrives, store the verdict, and hide flagged words
everywhere they show, notifications and lists included. That goes further than Android.

**Decision:** the iPhone screens words with the same model, the same lines and the same word list.

- **The model:**
  - `tools/models/toxicity/` downloads the checkpoint, pinned by the SHA-256 detoxify-mobile also records, and
    rebuilds it in PyTorch.
  - Converted to a float16 ML program, it is `App/Models/Toxicity.mlpackage`, 23 MB, since ALBERT's twelve layers share
    one set of weights and the package keeps it once.
  - The mask adds -10000 where transformers adds the lowest float32, which float16 cannot hold. `convert.py` checks
    that the change scores what transformers does.
  - `convert.py --check` rebuilds the package byte for byte. It drops the conversion date coremltools stamps and
    writes the spec's maps in key order. `tools/models/nsfw/convert.py` does the same now: its package carried the
    date, and its check would have failed on any later day.
- **Float16 against the checkpoint,** measured on 2026-10-04 over 45 messages (`parity.py`): every enforced label within
  0.004 on the Neural Engine and 0.011 on the CPU. Float32 matched exactly, at 45 MB. Int8 weights came to 12 MB, but
  were off by 0.027 and turned one verdict at a line. Android's own int8 TFLite is off by up to 0.12 and turns two
  verdicts near the threat line, so the two phones can disagree about a message close to a line.
- **The tokenizer and the word list** are Android's files, byte for byte, `App/Models/ToxicityTokenizer.json` and
  `App/Models/Profanity.txt`, copied into the app. `ModelAssetTests` pins both hashes.
  - `SentencePieceTokenizer` in KnitAppCore follows the file rather than Kotlin's port of it. It runs the normalizer
    twice, as the file lists it, drops every combining mark, and walks Unicode scalars. Kotlin walks UTF-16 units.
  - `SentencePieceTokenizerTests` holds it to the ids Hugging Face's own library makes from the file, over 50 texts:
    Android's goldens and the corners.
  - Neither port picks out a special token such as `[SEP]` typed in a message, which Hugging Face's library would.
- **The policy** is KnitAppCore's, tested on Linux:
  - `AbusiveText` holds the lines, `WordFilter` ports `LexicalTextFilter`, and `GeoTokens` ports `GeoUri.strip`.
  - `TextScreening` runs them in Android's order. Words the model cannot read pass, as Android's do.
- **The store:** schema v7 adds `messages.moderation`.
  - 0 means clear and 1 flagged, Android's codes. 2 means waiting, a code of this port's own.
  - A partial index finds the waiting rows. Every row stored before v7 reads as clear.
- **The engine** stores someone else's new message with words as waiting, and never classifies anything itself.
  - Its delivery path is synchronous inside its actor (ADR 2026-09.gq84). Waiting on the model there would let a
    re-served frame slip past the insert gate while the first copy is still being classified.
  - Custody and the relay never read the column (ADR 2026-10.5wgg).
- **The session screens it.**
  - `AppSession.handle` scores a waiting message as it hears `.received`, stores the verdict, and only then moves
    `revision` and posts the notification, so neither shows words the filter has not read.
  - `listen` first sweeps whatever a stopped app left waiting.
- **Hiding:** with the filter on, someone else's words that are flagged or still waiting are hidden.
  - The thread shows "Message hidden. Tap to show." for flagged words, and "Checking message…" in the moment before
    the filter has read new ones.
  - The chat list, requests and notifications say "Message hidden by content filtering".
  - A tap shows everything the filter hid of that message, words and photo, while the thread is open.
  - VoiceOver hears the hidden state in the message's value and gets a Show message action.
  - Because verdicts are stored, turning the filter on hides at once.
- **The toggle** is the session's now (`AppSession.filtersContent`), one for photos and words, and `PhotoScreening`
  reads it there.
- **Sending:** `ChatModel.send` checks the words whatever the toggle says. A refused message stays in the composer
  with its photo, and an alert says why, in the room's words or a DM's.
- **The app:** `DeviceTextClassifier`, in `Sources/Knit/Moderation/` beside the photo model (`seam_coreml`).
  - It runs on the CPU and the Neural Engine, never the GPU. It loads on the first message, foreground or background.
  - It lets go ten minutes after its last message at the front (Android's `ModelLease`), five seconds after it in
    the background, and at once when memory runs low.
  - A model or tokenizer that fails to load stays failed until the next launch, and every message passes.
- **Checks on the iPhone:** the debug bridge's `screen-text` returns the model's scores for a text, which
  `tools/models/toxicity/score.py` scores too. A control message line carries `moderation` when the filter flagged a
  message or has yet to screen it.
- **The demo:** `-demoSensitive` makes every message from someone else abusive too. The seeded words wait, and the
  session's sweep screens them.

The alternatives:

- **Screening when shown, in memory, as photos are (ADR 2026-10.rpmq).** The plan started there. A message's words
  appear in its notification and the chat list before any bubble draws them, so that would have left the lock screen
  unscreened.
- **Classifying inside the engine,** as Android's `InboundPipeline` does. Ruled out by the re-served frame above.
- **Shipping LiteRT** to run Android's file. Ruled out for the reasons in ADR 2026-10.rpmq.

**Consequences / limits:**

- **Differences from Android, on purpose:**
  - Notifications, the chat list and requests hide flagged words. Android shows them.
  - Words wait, hidden, for the moment the filter takes to read them. Android classifies before it stores.
  - A tap shows the words and the photo of one message together.
  - The tokenizer follows Hugging Face where Kotlin differs, and the model is float16 where Android's is int8.
- **What is not built yet:** search and reply quotes. When either comes, it must read the column as Android's does.
- **Cost:** the model loads in the background when a message lands there, 23 MB for a few seconds. Messages stored
  before v7 are never screened.
- **What it is not:**
  - English-centric, and a model: it misses some messages and flags some fine ones. "die in a fire loser" scores threat
    0.77 and passes. The harmless "my brother is gay and my mum is muslim" scores identity_attack 0.75, under its line.
  - No CSAM detection.
  - Sender-side checks are good citizenship. Hiding on the recipient's phone is the protection.
- **The traps:**
  - Reading the verdict anywhere the mesh decides what to carry, refuse or serve (ADR 2026-10.5wgg).
  - Android's `tokenizer.json` pads and truncates to 128 by itself. A tool that leaves that on gets padded ids, and a
    mask built from their count is all ones. That moves scores far: one threat fell from 0.96 to 0.63, which made
    Android's own test look wrong for a while. `common.tokenizer` turns both off.
- **Guards:**
  - `SentencePieceTokenizerTests`, `WordFilterTests` and `TextScreeningTests` for the policy, arrival, notifications,
    the thread, the lists and sending. `DemoTests` for the demo's sweep.
  - `MessageModerationTests` against both stores, `SchemaTests` for the v7 pin and `v7ShowsEveryMessageAsItWas`.
  - `MeshEngineModerationTests` for what waits, and `MeshControlPhotoTests` for the control line.
  - `ModelAssetTests` on Linux, and `check.sh xcode` and `release`, which fail without a whole `Toxicity.mlmodelc` and
    both of Android's files in the app.
  - `KnitUITests.walkContentFilter` under `-demoSensitive`: a hidden message shows on a tap, and words sent to the room
    are refused and stay in the composer.
  - `convert.py --check` and `parity.py --coreml`, whenever the model or a pin moves.
