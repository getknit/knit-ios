---
id: "2026-10.nbhj"
slug: mentions-highlight-the-sender-s
title: "Mentions highlight the sender's words and alert apart"
date: 2026-10-14
topics: [messages, wire, interop, ui, notifications]
---

# ADR 2026-10.nbhj — Mentions highlight the sender's words and alert apart

Status: Accepted (2026-10-14)

**Context:** Knit for Android mentions people in every thread. The format is the same at the pin (`5f521cb9`) as on
knit-next's `main`:

- **On the wire:** `Mention { nodeId, name }` (`Wire.kt:394-400` at the pin).
  - A room post carries the list in the clear, in `ChatContent.mentions`.
  - A DM or a group message carries it sealed, in `MessageContent.mentions`. The cleartext shell beside the seal
    carries none.
  - `name` is the text that follows the "@" in the body: the sender's label for the person, "Name", or "Name (alias
    words)" when two people share the name (knit-next ADR 058). There are no offsets.
- **Receiving:**
  - The receiver lights every `"@"+name` in the body: longest token first, no overlaps, case-sensitive, and with no
    word boundary (`mentionSpans`).
  - "Mentions me" is a node-id match alone. A message that mentions us posts on a Mentions channel, under
    `mention:<conversation>`, in place of the ordinary alert, on first delivery, in an accepted thread
    (`InboundPipeline.kt`, `MessageNotifier.kt`).
- **The composer:**
  - The picker opens on an "@" at the start of the text or after whitespace, and offers the thread's senders and a
    group's members, minus us and the blocked. A query matches the label or the alias as a substring.
  - A pick inserts `"@" + label + " "`.
  - At Send, a pick goes only while `text.contains("@"+name)`. That's a substring test, so a pick whose chip was
    deleted still goes if its token survives inside a longer name.
  - Since `d47ad76c` (2026-10-07, after the pin, UI only), a picked name is a chip that backspace deletes whole.
    Since `eafb0721`, a mention's color reads 4.5:1 on its bubble.

This port decoded and re-encoded `Mention` with its goldens, but it sent every list empty and dropped every list it
took. So an Android user's mention of someone on an iPhone neither alerted them nor showed. ADR 2026-09.n393 kept
mentions out. On 2026-10-14 the maintainer asked for parity, with Signal for iOS as a second reference. They chose:

- a `UITextView` composer with chips;
- the sender's words as written;
- one extra, a notification of its own;
- a paired change so interop can check mentions both ways.

**Decision:** the iPhone sends, keeps, lights and alerts on mentions in every thread. Nothing on the wire changes.

- **The store.** Schema v14 adds a `mentions` column: the CBOR array the frame carries, or `NULL` for none. Bytes that
  don't read as a list read as nobody, as Android's `MentionStore` reads malformed JSON. `MessageRecord.mentions` holds
  `MessageMention`s whose node ids compare by their bytes (ADR 2026-09.jc2x). A column, not a child table: one read per
  row, and a deleted row takes its mentions with it, so the delete paths don't move.
- **One rule decides what a list keeps,** on sending and on taking (`MessageMention.carried`):
  - It keeps a mention only if its name isn't empty and its token occurs in the body, by UTF-16 code units, as
    Kotlin's `contains` compares them. Exact duplicates go.
  - It answers exactly as Android's `contains` does, so a stale pick inside a longer name is kept, in either order.
- **The bound sits on the body, not on a number of our own.**
  - A frame can list thousands of long names. Each token is looked up in a suffix automaton of the body, in time that
    grows with the token alone.
  - If the distinct tokens found add up to more than twice the body's units, no composer wrote the list and none of it
    is kept. Chips sit in places of their own, and a stale pick hides inside another name.
  - This bounds what a row stores and what a thread's highlight searches.
  - It's the crypto reviewer's finding on the first cut, a budget charged to every token checked. That cut dropped an
    Android stale pick and depended on the list's order.
- **Sending.** The engine's three sends take `mentions`, keep what `carried` keeps on the row, and send them in the
  clear for the room and sealed for a DM or a group. A message waiting for a key seals its list at the flush. The shell
  carries none, and a cleartext list beside a seal is ignored on arrival.
- **The composer** follows Android's rules, ported in `MentionText` over UTF-16 offsets with every case of
  `MentionTextTest`:
  - the "@" word, ending at ART's whitespace (ADR 2026-10.7uyt);
  - the filter, by label or alias, spaces taken out;
  - the insertion;
  - `keepChipsWhole` and `snapOutOfChips`.

  `MentionCandidate.offered` is Android's list: senders and a group's members, without us or the blocked, sorted by
  label. A pick writes the clash-aware label as the name, where a reply's quote writes the plain name. `ChatModel`
  holds the picks and the field's selection, and Send carries the picks the words still hold.
- **The field is a `UITextView`** (`ComposerTextView`), because SwiftUI's `TextField` styles no range and reports an
  edit only as the text after it.
  - `shouldChangeTextIn` hands the model the exact range, and a widened edit is applied whole.
  - The keyboard's own composing, marked text, is left alone until it commits.
  - A chip is the body's font, semibold, in the label color on `systemGray4`, which reads in light, dark and with
    Increase Contrast.
  - The field grows a line at a time to six, then scrolls. That replaces the hidden `Text` that measured iOS 27's
    multiline `TextField`.
- **The picker** (`MentionPicker`) sits above the field, in the composer's panel:
  - every match, where Android cuts at five;
  - four and a half rows and a scroll past five, as Signal shows them;
  - a light haptic as it opens;
  - VoiceOver hears how many people it offers, since the keyboard keeps the focus.
- **A thread lights the sender's words.** A bubble sets each span semibold: in `Swatches.mention` on someone else's
  bubble, and in the bubble's own color on ours. `Swatches.mention` is the tint deepened in light, where the accent
  reads 4.4:1 on the gray. The name stays the sender's text, as on Android (knit-next ADR k8ge). A mention is no button,
  and VoiceOver reads the words as written.
- **The difference: a mention of us alerts apart.**
  - The notification goes under `mention:<conversation>`, in place of the thread's usual one, with the same words.
  - Later chatter in the thread replaces only the ordinary one, and opening the thread withdraws both, since they share
    its thread identifier.
  - Android's own entry has its own channel and importance. iOS has no channels, so the id carries the difference.
- **The control lines.** `room`, `dm` and `group-send` take `mentions`, a list of node ids named by the session's
  labels, or by stored names for knit-peer, and message lines carry them.
- **Companion change A8** gives knit-next's debug bridge `SEND --es mentions` and reports each message's mentions in
  `STATE`, debug code only, so `interop.py iphone-mention` checks every thread both ways.

**Consequences / limits:**

- **A room mention is as public as the room.** It also names the mentioned person's node id to everyone in range
  (`SECURITY.md`). A DM's or a group's travels sealed.
- **Where this may differ from Android:**
  - A crafted list alerts there and not here: a mention without its token, a token past our 2000-unit cut, or a list
    whose tokens found pass twice the body.
  - An honest list could pass the bound only if one name hid several stale picks at once.
  - A mention with an empty name goes here. Android's `contains("@")` keeps one whenever the body has an "@", and only
    a crafted list carries one.
  - Exact duplicates are dropped here and kept there. That changes how a message looks, never whom it mentions.
- **Not built:**
  - a "you" style, a mention that opens a profile, and Signal's "@" button, which needs unread state this port lacks;
  - relabelling a mention with this phone's label;
  - moving through the picker with a hardware keyboard;
  - mentions in drafts, since there are no drafts;
  - a mention in a reply from a notification, which Android doesn't write either.
- **The traps:**
  - Reaching for a budget or a count cap again. It drops honest lists, and an order-dependent rule tells two phones
    different things.
  - Reading `.mentions` off the cleartext shell of a sealed message.
  - Mutating the text view's text while marked text is up, which breaks a kana run.
- **The guards:**
  - `MentionWireTests`, where a sealed list sits after `body`;
  - `MessageMentionTests` and `SubstringIndexTests` against both stores;
  - `SchemaTests`' v14 pin with `v14KeepsEveryMessageMentioningNobody` and `aRowsMentionsAreTheFramesOwnBytes`;
  - `MeshEngineMentionTests`: Android's lists kept in each thread, a stale pick in either order, the clear list beside
    a seal ignored, ours in the clear or sealed and never in the shell, the flush, and two engines;
  - `MentionTextTests`, from `MentionTextTest.kt`;
  - `MentionTests`: candidates, picks, chips, Send and the alert apart;
  - `SwatchContrastTests`' mention pair;
  - `CopyCatalogTests+Mentions`;
  - `MeshControlMentionTests`;
  - `KnitUITests.walkMentions`, audited at both sizes and in dark mode.
