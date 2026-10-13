---
id: "2026-10.mn29"
slug: replies-quote-in-every-thread
title: "Replies quote in every thread, screened with the reply"
date: 2026-10-13
topics: [messages, wire, interop, ui, moderation]
---

# ADR 2026-10.mn29 — Replies quote in every thread, screened with the reply

Status: Accepted (2026-10-13)

**Context:** Knit for Android has quoted replies in DMs, groups and Nearby since `b5bdb244` (2026-07-04), and the
format has not moved since; it is the same at the pin (`5f521cb9`) as on knit-next's `main`. A reply carries a snapshot
of what it quotes, `ReplyRef { messageId, authorId, author, snippet, hasAttachment = false }`:

- **Where it rides:** sealed in `MessageContent.replyTo` for a DM or a group, and in the clear in `ChatContent.replyTo`
  for a room post. A sealed frame's cleartext shell never carries one (`Wire.kt:212-215`), and a cleartext one beside
  `enc` is ignored on arrival (`InboundPipeline.kt:979-990`). `author` and `snippet` have no default, so they are always
  written, empty or not; a quote missing either fails the whole payload.
- **What the replier writes** (`ChatScreen.kt:1352-1388`, `buildReplySnippet`): the author's plain name, ours when we
  quote ourselves, never "You"; the words flattened to one line and cut at 120 UTF-16 units; nothing when the original's
  words are hidden by the content filter; a label for a GIF, a file or a voice note with no words, in the replier's
  language. A still photo sends no snippet and sets `hasAttachment`, and a link's card does not count as an attachment.
- **What the receiver does:** stores the first copy's quote (`saveIfAbsent`) and checks nothing: not that the original is
  held, nor in the same thread, nor by the named author. The quote draws from the snapshot. A tap scrolls to the original
  when it is loaded, flashes it, and does nothing when it is not. Notifications show the reply's own words. Reply is the
  first item in a bubble's long-press menu; there is no swipe.

This port decoded and re-encoded `ReplyRef` on both payloads, with the `replyRef` golden vector, and dropped it at
delivery, so an Android reply showed here as a plain message with its quote lost. ADR 2026-09.n393 kept replies out.
The maintainer asked for parity on 2026-10-13, and chose three things Android does differently.

**Decision:** the iPhone shows, sends and jumps to quotes in every thread, as Android does toward it. Nothing on the wire
changes, and Android needs no change.

- **The store.** Schema v13 adds Android's five columns (`replyToId`, `replyToAuthorId`, `replyToAuthor`,
  `replyToSnippet`, `replyToHasAttachment`), and `MessageRecord.replyTo` holds a `MessageReply`. A row is a reply when
  `replyToId` is set. The first copy of a frame sets its quote. `authorId` is kept unparsed and compares by its bytes
  (ADR 2026-09.jc2x).
- **The rule that writes one** is `MessageReply.quoting`, in `KnitStore`, so the app and knit-peer write the same quote.
  It cuts at 120 units without splitting a scalar, where Kotlin's `take` can split a surrogate pair.
- **Sending** puts the quote on the row, so a message waiting for a key keeps it. `content(of:)` seals it for a DM or a
  group, and a room post carries it in the clear.
- **Taking one** clips `author` and `snippet` to 256 UTF-16 units, as an attachment's text is clipped, and checks nothing
  else, as on Android.
- **Difference 1, a quote is screened with its reply.** This port shows nobody else's words before the content filter
  has read them (ADR 2026-10.e4kz), and a quote is the replier's copy of someone's words. Someone else's message waits
  for the filter when its body or its snippet has words, and the filter flags it when either is abusive. One verdict on
  one column covers both, so the reply's one tap shows both. A quote of someone blocked here shows no words. Android
  screens the body alone.
- **Difference 2, the quote names the author with this iPhone's label:** "You" for ours, the collision-aware label for
  a peer this phone has pinned, and the replier's name only for someone it does not know. Android shows the replier's
  name, which a replier is free to make up.
- **Difference 3, a swipe starts a reply** too, as in Messages and WhatsApp. Reply also leads the long-press menu, under
  the six reactions, and is a VoiceOver action. The swipe gives way to the navigation bar's back swipe and to scrolling.
- **The jump.** A quote is a button only when its original shows in the thread. A thread here holds every message it
  has, so there is no window to grow first, as Android's `revealMessage` grows one. The jump unpins the thread from its
  bottom edge before it scrolls (ADR 2026-10.pkbu), and moves VoiceOver to the original.

**Consequences / limits:**

- **A quote is a snapshot the replier controls.** Its words may not match the original, which may never have reached this
  phone. The label is ours; the words are theirs.
- **A room quote is as public as the room.** A DM's or a group's travels sealed with the message.
- **What may differ from Android:** a reply hidden by its quote; a quote showing a label where Android shows the name the
  replier sent; a snippet one unit shorter where Kotlin's cut splits an emoji.
- **Not built:** search of quotes (Android does not search them either), a quote in a notification's inline reply, and
  the v3 compact `ReplyRefV2`, since this port never opens a v3 DM.
- **The trap:** screening the body alone again, which shows a photo-only reply's quote unread, or making a quote a button
  for an original that is not shown, which gives VoiceOver a dead action.
- **The guards:**
  - `MessageReplyTests`, against both stores, with the quote rule's cases from `ReplyFormattingTest.kt`, and
    `SchemaTests`' v13 pin with `v13KeepsEveryMessageQuotingNothing`.
