---
id: "2026-10.ehe6"
slug: reactions
title: "Reactions: six to pick, any one emoji shown, sent in the clear"
date: 2026-10-04
topics: [messages, wire, interop, ui]
---

# ADR 2026-10.ehe6 — Reactions: six to pick, any one emoji shown, sent in the clear

Status: Accepted (2026-10-04)

**Context:** Knit for Android has had reactions since June (`5022dc0b`). They began as a fixed row of six,
👍 ❤️ 😂 😮 😢 🙏, and since 2026-09-01 take any emoji from a full picker (knit-next ADR 2026-09.v66c). The iPhone
verified, carried and relayed `reaction` frames and showed none, and ADR 2026-09.n393 listed reactions as out of
this port. The maintainer asked for them on 2026-10-04, picked from Android's original six to keep the design small.

The wire was already ported: `ReactionContent { messageId, emoji? }` with its goldens, the custodial `reaction` type,
`TextLimits.isValidReaction` and the `CAP_REACTIONS` bit. What Android does with them, at the pin:

- **Toward a peer without `CAP_RATCHET`,** which every iPhone is (ADR 2026-09.qsd9), `MeshManager.sendReaction`
  (`:2038-2063`) floods a signed cleartext `reaction` frame naming no recipient and no group. It never wraps a ctl
  payload in v1 (knit-next ADR 018). So every reaction between the platforms, in a DM or a group as much as in Nearby,
  shows anyone in range who reacted to which message id, and with what.
- **`InboundPipeline.handleReaction` (`:631-647`)** drops a blocked sender's, refuses an emoji that is blank or over
  32 UTF-16 units (`REACTION_REFUSED`), and otherwise applies `(messageId, reactor) → emoji?` last writer wins on the
  clamped `sentAt`, strictly newer. A retraction is a row with no emoji. It checks neither that the reactor belongs to
  the thread nor that the message is held. A reaction is never acknowledged or notified.
- **`ReactionRepository.deleteOrphans`** reaps, at start, a reaction over a day old whose message is not held.
- **`CAP_REACTIONS`** is read by nothing; Android advertises it for diagnostics.

**Decision:** the iPhone takes and sends reactions as Android does toward it, in every thread, with three local
differences. Nothing on the wire changes, and Android needs no change.

- **The store.** `MessageStore` holds them, schema v9's `reactions` table and the memory store's map, so a delete
  clears a message's reactions in its own transaction and the thread's read joins the messages held. Apply is one
  upsert whose update only a strictly newer clock passes. A reaction to an id remembered as deleted is refused there
  (ADR 2026-10.u7cq).
- **Sending** (`MeshEngine.react`) toggles as `sendReaction` does: our current emoji again sends a retraction, another
  replaces it. The row and the frame share one clock. Emoji compare by their bytes (ADR 2026-09.jc2x), since Swift's
  equality would send a retraction where Android sends a replacement.
- **Taking one** (`handleReaction`): a blocked sender's is dropped as `blocked`, and only that. `dropBlocked` would
  tick it, since it ticks any frame that names no recipient. An undecodable one counts `undecodable`. A change to a held
  ordinary message is announced as `MeshEvent.reacted`, and an orphan is not, so the many reactions a relay sees to
  other people's DMs don't rebuild the screens.
- **Difference 1, one emoji only.** A reaction must also be a single emoji (`TextLimits.isAcceptedReaction`): one
  grapheme cluster whose first scalar shows as emoji, or is made one by a selector, keycap, skin tone or joiner. A
  scalar newer than the standard library's tables passes when it lies in the emoji planes. Anything else counts
  `reactionRefused`. Android's picker only sends emoji, so this refuses only words a modified build could send, which
  every member of a thread would otherwise see on a chip.
- **Difference 2, who shows** (made in the app, not the engine). A DM shows reactions from its two people and a group
  from its founding roster; Nearby shows anyone's. A blocked person's are hidden, and come back on unblock as their
  messages do (ADR 2026-10.5wgg). The frame names no thread, so without this a stranger who saw a DM's frame id could
  put a chip in it.
- **Difference 3, the clock and the reaping.** Two taps in one millisecond stamp the second one past the first, never
  past five minutes ahead, so it still wins everywhere it lands. Orphans are reaped in every sweep, not only at start:
  a relay keeps every reaction it hears, and knit-peer may run for weeks.
- **The picker** offers the six in Android's order, ❤️ with its `U+FE0F` as Android spells it. Any emoji another phone
  sends still shows.
- **Custody never reads any of it.** The carry runs above the handler, so a refusal, a block or a delete changes what
  this node shows and never what it carries.

Sealing reactions was the alternative a reader reaches for first. It needs the ratchet: Android applies a ctl reaction
only from a v2 DM or the group ratchet, and a v1-wrapped one would be discarded here and shown as an empty bubble by an
old Android build. The maintainer also weighed reactions in Nearby only until the ratchet lands, and chose every thread,
with the copy saying plainly that reactions travel unencrypted.

**Consequences / limits:**

- **Reactions are not private.** In a DM or a group, every phone that carries a reaction can read who reacted to which
  message, and with what emoji, though not the message itself. The thread's encryption sheet and `SECURITY.md` say so.
  It ends when the ratchet lands and both sides seal them.
- **Counts can differ from Android's.** Android shows a stranger's reaction in a DM and a blocked person's anywhere;
  this port hides both, and refuses words.
- **Many orphans.** Every reaction to someone else's DM is kept for a day. Android keeps the same rows.
- **The trap:** reading a block, a refusal or a deleted id in `isCarriable` or anywhere custody reads, or reusing
  `dropBlocked` for a reaction.
- **The guards:**
  - `ReactionStoreTests`, against both stores, and `SchemaTests`' v9 pin with `v9HoldsNoReactionsAndKeepsEveryMessage`.
  - `MeshEngineReactionTests`: the frame Android sends, the toggle and the same-millisecond stamp, out-of-order
    convergence, the future clamp, orphans and their reaping, the block without a tick, refusals that are still
    carried, a deleted target, a parked reaction meeting a block, our own frames served back, and one digest whatever
    this node shows.
  - `IdentityCodecTests`' emoji cases.
