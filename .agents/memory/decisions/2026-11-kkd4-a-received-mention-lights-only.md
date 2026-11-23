---
id: "2026-11.kkd4"
slug: a-received-mention-lights-only
title: "A received mention lights only under the reader's label"
date: 2026-11-23
topics: [mentions, names]
---

# ADR 2026-11.kkd4 — A received mention lights only under the reader's label

Status: Accepted (2026-11-23)

**Context:** a received message carries a list of `Mention { nodeId, name }`, and the name is the sender's own text
(knit-next ADR 058). Since ADR 2026-10.nbhj a bubble lights every `"@" + name` its sender listed, as Android's
`mentionSpans` does. knit-ios #36 and knit-next #247 give the reason it has to change.

**Decision:** a bubble lights a received mention only under a name this phone gives that person, as knit-next ADR
2026-11.p6dk decides for Android. Android leads the paired change (knit-next #247), and no wire byte, stored column or
notification moves.

- **The rule** is `MentionText.vouched`. It judges each entry on its own, by the first step that applies:
  1. Our own message keeps every entry, because our composer wrote the names.
  2. In a group thread, an entry named exactly `everyone` is kept when its node id is in the group's current roster or
     is ours. Otherwise it's dropped, even when that id's label is "everyone": it never reaches step 3 in a group. In
     any other thread it goes on to step 3. Android's MeshCore room keeps every entry, and this port has no such room.
  3. Any other entry meets three bounds first, so that a long list or a long thread can't make a thread slow to draw
     (the contract's revisions 2 and 3). In a row outside its thread's window, the entry drops. A name longer than 512
     UTF-16 code units drops. Of the entries left, only those whose node id is
     among the first 16 distinct ids to reach this step, in list order, are judged, and the rest drop. Entries the
     steps above settled never count toward the 16. A judged entry is kept when the `NameKey` of its name equals the key
     of one of `PeerLabelIndex.mentionTexts(for:)`. Those texts are this phone's label for the node id, then that label
     grown by each further token of the id's own alias phrase, up to ten. An id outside the index gets the label
     `label(for:)` already gives it.

  Node ids and keys compare by their bytes, as Kotlin compares them.
- **The window** (`MentionWindow`) is a thread's newest 200 counted rows. A counted row is a stored row someone else
  sent, someone we haven't blocked, with a stored mention list that isn't empty. So our own rows and ordinary chatter
  never push a highlight out, and blocking a flooder brings the honest highlights back (the contract's revision 5). Newest is the display order: `sentAt` as stored, which the engine clamps to five minutes past
  our clock, then the message id by its UTF-16 code units. Arrival time isn't used, because a bulk of back-dated rows
  from a custody replay would take the window from current messages.
- **The span function doesn't change.** `MentionText.spans` runs over the kept entries alone, so a shorter kept token
  inside a dropped longer one is still lit.
- **Where it runs:** `ChatModel` lays the spans over each row (`ChatMessage.lit`), with the group's members and the
  session's label index, the content filter's presenter included. The composer's chips still call `spans` on the
  pending picks, unfiltered.
- **What it costs.** Judging an id costs its label and up to eleven name keys. `NameKey.of` costs about a microsecond a
  character on Linux, so the label texts, which are plain ASCII, take `NameKey.quick`: the same key by a byte map, held
  equal to `NameKey.of` by `NameKeyQuickTests`. One judge (`MentionVouch`) keeps each id's keys and each name's key for
  the rows a thread holds. `MentionLights` keeps each row's spans from one build to the next while the names the labels
  are made from, a group's roster and the window stand, so a rebuild that moved none of them judges no row again. When
  they move, the window bounds the work: at most 200 rows, each with at most 16 ids judged.
- **The demo** seeds what a composer writes: the label text, in the body and in the mention. The edge-cases scene's
  "@Sam" between two Sams now reads "@Sam (alias)", and stays lit.
- **What stays as it was:** decoding, `MessageMention.carried`, the stored list, "mentions me" and its notification,
  what a sender writes (ADR 058's label, ADR 2026-10.jwst's expansion) and the style.

This amends ADR 2026-10.nbhj in two places. A thread still lights the sender's own words, but only those this phone
vouches for. Relabelling a mention with this phone's label is still not built: the label decides what lights, and the
words stay the sender's. It amends ADR 2026-10.jwst too, since `@everyone` now lights only in a group, for a member.

The alternatives, and why not:

- **Judging at receive time and storing a verdict.** Labels move, so a stored verdict goes stale. The notification
  already reads the node id alone.
- **Rewriting the body with our label.** That changes the sender's words, which ADR 2026-10.nbhj keeps.
- **Accepting a bare alias for a named peer, or a name from before a rename.** Each is a name this phone's index
  doesn't produce, so it can't vouch for one.

**Consequences / limits:**

- **A genuine mention can draw plain.** It does when the sender saw no clash and this phone sees one: their "@Alice"
  against our "Alice (alias)". It also does when:
  - the person renamed;
  - this phone has no profile for them yet;
  - our content filter hides their name;
  - the sender wrote the bare alias because it lacked the name or hid it.

  Android's clash fades after a week (knit-next ADR 2026-10.k8ge). This port doesn't mirror that, so here a stranger's
  clash lasts as long as the stranger's row.
- **The rule reads the current labels.** A rename, a new clash or a content-filter toggle can turn an earlier
  message's highlight on or off. Our own messages are exempt.
- **A private name for a contact doesn't come into it,** because neither platform stores one.
- **A mixed fleet differs only in which highlights it draws.** A phone without this change still lights every entry.
- **Older mentions in a busy thread.** In a thread with more than 200 received messages that carry mentions, the older
  ones' mentions draw plain. A flood of such posts pushes honest highlights out of the window, as it already pushes
  honest rows out of retention. A message that arrives late through custody sits at its `sentAt`, and lights only if
  that puts it among the newest 200. A row counts by its stored list, and this port stores only the entries whose token
  is in the body (`MessageMention.carried`), where Android keeps the list as received. So for a crafted list whose
  tokens aren't in the body, the two platforms' windows can differ: Android counts that row and this port doesn't. That
  changes which highlights show, never what one shows.
- **More than 16 people in one message.** Past the first 16 distinct ids that reach the name rule, a received
  message's mentions draw plain. A group holds at most eight people, and the room's composer picks people one at a
  time. How long a stored list may be stays knit-ios #32's question.
- **The rule lights what the label index shows,** so it can't be stricter than the labels are. A gap in how the index
  grows a clash is knit-ios #61's, with knit-next #360 its twin.
- **The traps:**
  - filtering inside `MentionText.spans`, which the composer's chips also use;
  - reading a raw name from `Directory.peers` where the label shows the alias.
- **The guards:**
  - `MentionVouchTests`: every case of the paired contract, both bounds, and a name the content filter hides;
  - `PeerLabelsTests`' `mentionTexts` cases;
  - `MentionTests` and `MentionEveryoneTests`, through `ChatModel`, a rename and a member leaving among them;
  - `MentionLightsTests`: every build lights what a fresh judge would, across renames, the filter, the roster and a
    window that moves;
  - `MentionWindowTests`, and a 201-row thread in `MentionTests`;
  - `NameKeyQuickTests`;
  - `DemoTests+Mentions`;
  - `MentionVouchVectorTests`, over knit-next's `vectors/mention-vouch-v1.json`, which pins each label too.
