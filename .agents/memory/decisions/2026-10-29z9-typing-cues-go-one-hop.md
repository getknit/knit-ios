---
id: "2026-10.29z9"
slug: typing-cues-go-one-hop
title: "Typing cues go one hop, unencrypted, and show at a thread's foot"
date: 2026-10-13
topics: [messages, wire, interop, ui]
---

# ADR 2026-10.29z9 — Typing cues go one hop, unencrypted, and show at a thread's foot

Status: Accepted (2026-10-13)

**Context:** Knit for Android has shown typing cues since `c4fcdabc` (2026-07-04), and its numbers haven't moved since.
The iPhone verified each `typing` frame, then dropped it without a word, sent none, and listed typing indicators under
the roadmap's "Deferred by design". The maintainer asked for them on 2026-10-13, with no Settings switch, since Android
has none, and in the thread alone, Android's one surface. What Android does at the pin (`5f521cb9`):

- **The frame** (`MeshManager.sendTyping`, `:2297-2319`) is a signed, cleartext `RelayEnvelope` of type `typing`, with
  `relay = false` and a fresh id each time, so no seen set swallows the next one. It names its thread as a chat does: a
  DM by `recipientId`, a group by `TypingContent.groupId` alone, never the `group` roster, and the room by naming neither.
  A room or DM cue's payload is `{}`, `a0`. Nothing says a sender stopped.
- **It goes one hop:** a DM's to its addressee's own link, the room's and a group's to every linked neighbour. No relay
  forwards it, custody never holds it, nothing parks it, and it rings no doorbell (ADR 2026-09.khjj).
- **Sending** (`ChatViewModel.onUserTyping`, `:2504-2542`): a keystroke that leaves words in the composer, while the
  thread is in front, at most once every 8 s a thread, the first at once. A message sent doesn't restart the 8 s.
- **Taking one** (`InboundPipeline.handleTyping`, `:472-486`, and `TypingTracker`): our own is ignored, a group's needs
  the group held, and a DM's must name us. A sender's cue holds 12 s, each cue pushes that out, and their delivered
  message in the thread ends it at once. At most 64 (thread, sender) pairs are held. It checks no roster, block or
  `sentAt`. After the pin, `03c4c3b1` counts a payload that won't decode and drops it, where it used to read as the room.
- **The row** (`TypingIndicatorRow`, `ChatScreen.kt:3464-3495`) sits under the newest message: up to three faces beside a
  received bubble holding the three-stitch sweep, with no words. Its label is "Sam is typing", or "Sam and others are
  typing" for two or more, without self or anyone blocked, in name order. It comes into view only for a reader at the
  bottom (`e402ac35`), and an empty thread says nothing of being empty while it shows.

**Decision:** the iPhone sends and shows typing cues as Android does, in every thread. Nothing on the wire changes, and
Android needs no change.

- **The engine** sends (`MeshEngine.noteTyping`) and takes them (`handleTyping`). It throttles each thread on the
  monotonic clock and keeps who is typing in `TypingBoard`, a deadline joined to `nextDeadline` (ADR 2026-09.gq84). It
  announces the whole picture as `MeshEvent.typing` whenever it changes: a new sender, a lapse, a delivered message, or
  the mesh stopping. A cue to a thread we can't write in, a group we left or someone we blocked, never goes.
- **The app** keeps the picture beside the links, outside `revision`, and lays it over `ChatModel.state` as it lays
  `isLinked`. The composer's `draft` setter sends a cue for each change that leaves words, only while Knit is in front and
  only where the composer can send.
- **The row** is `TypingRow`, the last item in `ThreadCollection` (ADR 2026-10.pkbu). The pinned layout brings it into
  view only for a reader on the bottom edge, as Android's scroll does. VoiceOver reads it as one element and is never told
  of it: Android announces nothing, and a cue every few seconds would talk over what is being read.
- **The control line** gains `typing` and an event of the same name, and `status` carries the picture in the shape of
  Android's `STATE.typing`, for `interop.py iphone-typing`.

Three local differences:

1. **Who shows** is reactions' rule (ADR 2026-10.ehe6): a DM shows its peer, a group its roster, and the room anyone.
   The engine also refuses a group cue from off the roster. Android shows anyone in a held group.
2. **A blocked sender's cue** is dropped as `blocked` with plain `drop`, never `dropBlocked`, which would tick it. The
   app hides one that landed just before the block.
3. **One that doesn't decode** counts `undecodable`, as `03c4c3b1` does, ahead of the pin.

The throttle is the engine's rather than the screen's, so tests drive it with a manual clock. The control line's
`typing` goes through it too, where Android's bridge skips its own.

Sealing cues was the alternative a reader reaches for first. Android seals none and would read a sealed one as nothing,
and a v1-sealed control payload is discarded here (ADR 2026-09.qsd9). A Settings switch was the other, and the maintainer
declined it to match Android.

**Consequences / limits:**

- **Cues aren't private.** A DM's goes only to the other phone's link; a group's goes to every phone linked to ours and
  names the group; the room's goes to all of them. The Bluetooth link isn't encrypted, so a listener in range can read
  each. The encryption sheet and `SECURITY.md` say so.
- **A suspended iPhone can show a stale cue.** It reads queued cues when a phone wakes it, and shows one for up to 12 s.
  Android checks no `sentAt` either, and phones' clocks disagree too much for one.
- **A cue behind a file waits for it.** A link writes in order, so a cue queued behind a photo's chunks lands late, or
  after it would have lapsed.
- **The encryption sheet says it in the reactions point.** A sixth point of its own made a group's sheet tall enough
  that the audit reported text on the screen it could not place, and the group walk failed every run. The shared point
  costs about a line.
- **The row has no contrast to audit.** Its only marks are faces and the stitches, which rest dim between sweeps, so its
  darkest pixel depends on the moment of the screenshot. `AuditPolicy` exempts it from Knit's pixel check and runs every
  other check on it (ADR 2026-09.jcdx, amended).
- **The trap:** sending a cue through `originate`, which would sign it as relayable and carry it for a day, or reading a
  block in custody. Another is filling `TypingBoard` from anywhere but a verified frame.
- **The guards:**
  - `MeshEngineTypingTests`: the frames Android sends in each thread, the 12 s lapse and its refresh, a message ending a
    cue, our own, someone else's DM, an unknown or left group, off the roster, a block without a tick, an undecodable
    payload, a missing key asking for nothing, the cap of 64, our frames' shape, the 8 s throttle, and no cue where
    we can't write.
  - `MeshTests+Typing`: a lapse wakes the timer with no frame, and a stop forgets.
  - `CBORTests.aTypingCueWithNoGroupIsTheEmptyMapAndroidReads`.
  - `MeshControlTypingTests` and `PeerNodeTests+Typing`.
  - `TypingTests` in KnitAppCore (the composer's cue and where it stays quiet, the overlay without a rebuild, each
    thread's audience and a block), `DemoTests`' typists through a real `Mesh`, and `KnitUITests+Typing`. The edge-cases
    scene holds three typists, Jonas among them behind his block, so every walk of the room and the group audits the row.
  - `interop.py iphone-typing`, both ways in every thread against a phone. It has yet to run.
