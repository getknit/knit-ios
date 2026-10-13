---
id: "2026-10.mn29"
slug: replies-quote-in-every-thread
title: "Replies quote in every thread, screened with the reply"
date: 2026-10-13
topics: [messages, wire, interop, ui, moderation]
---

# ADR 2026-10.mn29 — Replies quote in every thread, screened with the reply

Status: Accepted (2026-10-13)

**Context:** Knit for Android has had quoted replies in DMs, groups and Nearby since `b5bdb244` (2026-07-04). The
format hasn't changed since, and it's the same at the pin (`5f521cb9`) as on knit-next's `main`. A reply carries a
snapshot of what it quotes, `ReplyRef { messageId, authorId, author, snippet, hasAttachment = false }`:

- **Where it rides:** sealed in `MessageContent.replyTo` for a DM or a group, and in the clear in `ChatContent.replyTo`
  for a room post. A sealed frame's cleartext shell never carries one (`Wire.kt:212-215`), and on arrival a cleartext
  one beside `enc` is ignored (`InboundPipeline.kt:979-990`). `author` and `snippet` have no default, so they're always
  written, empty or not, and a quote missing either fails the whole payload.
- **What the replier writes** (`ChatScreen.kt:1352-1388`, `buildReplySnippet`):
  - the author's plain name, ours when we quote ourselves, never "You";
  - the words flattened to one line and cut at 120 UTF-16 units, or nothing when the content filter hides them;
  - with no words, a label for a GIF, a file or a voice note, in the replier's language.

  A still photo sends no snippet and sets `hasAttachment`. A link's card doesn't count as an attachment.
- **What the receiver does:** it stores the first copy's quote (`saveIfAbsent`) and checks nothing. It doesn't check
  that the original is held, that it's in the same thread, or who wrote it. The quote draws from the snapshot. A tap
  scrolls to the original when it's loaded and flashes it, and does nothing when it isn't. Notifications show the
  reply's own words. Reply is the first item in a bubble's long-press menu, and there's no swipe.

This port already decoded and re-encoded `ReplyRef` on both payloads, with the `replyRef` golden vector, but it dropped
the quote at delivery. An Android reply showed here as a plain message, its quote gone. ADR 2026-09.n393 kept replies
out. On 2026-10-13 the maintainer asked for parity, and chose three things to do differently from Android.

**Decision:** the iPhone shows, sends and jumps to quotes in every thread, as Android does toward it. Nothing on the
wire changes, and Android needs no change.

- **The store.** Schema v13 adds Android's five columns: `replyToId`, `replyToAuthorId`, `replyToAuthor`,
  `replyToSnippet` and `replyToHasAttachment`. `MessageRecord.replyTo` holds a `MessageReply`, and a row is a reply
  when `replyToId` is set. The first copy of a frame sets its quote. `authorId` is kept unparsed and compares by its
  bytes (ADR 2026-09.jc2x).
- **The rule that writes one** is `MessageReply.quoting`. `AppSession.quote(of:)` feeds it the app's names, filter and
  labels, for the composer and the bridge. Without a session, `MeshControl` writes knit-peer's quotes with stored names,
  no labels and no filter. The rule cuts at 120 units without splitting a scalar, which Kotlin's `take` can do to a
  surrogate pair.
- **Sending** puts the quote on the row, so a message waiting for a key keeps it. `content(of:)` seals it for a DM or a
  group, and a room post carries it in the clear.
- **Taking one** clips `author` and `snippet` to 256 UTF-16 units, as an attachment's text is clipped, and checks
  nothing else, as on Android.
- **Difference 1: a quote is screened with its reply.** Nobody else's words show here before the content filter has
  read them (ADR 2026-10.e4kz), and a quote is the replier's copy of someone's words. Someone else's message waits for
  the filter when its body or its snippet has words, and is flagged when either is abusive. One verdict on one
  column covers both, and the reply's one tap shows both. A quote of someone blocked here shows no words. Android
  screens only the body.
- **Difference 2: the quote names the author with this iPhone's label.** That's "You" for us, the collision-aware
  label for a peer this phone has pinned, and the replier's name only for someone it doesn't know. Android shows the
  replier's name, which a replier is free to make up.
- **Difference 3: a swipe starts a reply too,** as in Messages and WhatsApp. Reply also leads the long-press menu,
  under the six reactions, and is a VoiceOver action. The swipe gives way to the navigation bar's back swipe and to
  scrolling (ADR 2026-10.pkbu, amended).
- **The quote** sits above the reply's photo and words, in its bubble's colors, with an accent bar, the author on one
  line and the snippet on two. A photo quoted without words reads "📷 Photo". The composer holds a quote above the field
  until Send or Cancel reply, and the field takes focus.
- **The jump.** A quote is a button only when its original shows in the thread. A thread here holds every message, so
  there's no window to grow first, as Android's `revealMessage` grows one. The original is tinted for 1.2 seconds, and
  the tint fades unless Reduce Motion is on.
- **The control lines.** `room`, `dm` and `group-send` take a `replyTo` id, and message lines carry `replyTo`.
  `interop.py iphone-reply` checks quotes both ways in every thread.

**Consequences / limits:**

- **A quote is a snapshot the replier controls.** Its words may not match the original, and the original may never have
  reached this phone. The label is ours, but the words are the replier's.
- **A room quote is as public as the room.** A DM's or a group's travels sealed with the message.
- **What may differ from Android:**
  - a reply hidden because of its quote;
  - a quote under our label where Android shows the replier's name;
  - a snippet one unit shorter where Kotlin's cut splits an emoji;
  - a shared `geo:` position quoted as its words, since this build draws no map, where Android writes "📍 Location".
- **Not built:**
  - search of quotes, which Android doesn't search either;
  - a quote in a notification's inline reply, which Android doesn't write either;
  - the v3 compact `ReplyRefV2`, since this port never opens a v3 DM.
- **The trap:** screening the body alone again, which would show a photo-only reply's quote unread. Another is making a
  quote a button for an original that isn't shown, which gives VoiceOver a dead action.
- **The guards:**
  - `MessageReplyTests`, against both stores, with the quote rule's cases from `ReplyFormattingTest.kt`, and
    `SchemaTests`' v13 pin with `v13KeepsEveryMessageQuotingNothing`.
  - `ReplyWireTests`: a room reply encodes as `commonsPostFull`'s chat, and a sealed quote sits between the attachment
    and the control fields.
  - `MeshEngineReplyTests`:
    - Android's room, DM and group replies are kept;
    - a cleartext quote beside a seal is ignored;
    - ours go in the clear or sealed, and never in the shell;
    - a reply waiting for a key keeps its quote;
    - oversized quotes are clipped;
    - a photo-only reply with a quote waits for the filter.
  - `ReplyTests` in KnitAppCore:
    - the quote the composer writes;
    - the composer's Send and Cancel;
    - where no reply starts;
    - the author's label;
    - the photo's label;
    - a blocked author's words;
    - when a quote jumps;
    - a flagged quote;
    - a report's quote.

    `DemoTests` seeds two replies, and `CopyCatalogTests` reads the strings.
  - `MeshControlReplyTests`, and `KnitUITests.walkReplies`, audited with every screen at both sizes and in dark mode.
