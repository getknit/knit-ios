---
id: "2026-10.wcex"
slug: a-reinstalled-iphone-recognises-the
title: "A reinstalled iPhone recognises the inits it answered and resets at once"
date: 2026-10-18
topics: [crypto, custody]
---

# ADR 2026-10.wcex — A reinstalled iPhone recognises the inits it answered and resets at once

Status: Accepted (2026-10-18). Amends ADR 2026-10.5sk9's P3 amendment (prekeys live beside the identity in the Keychain)
and its reinstall rule, and ADR 2026-09.tkww's account of what a reinstall keeps.

**Context:** an iOS reinstall keeps the Keychain, and with it the identity and the ratchet's prekeys. It loses the
database, and with it every session (ADR 2026-09.tkww). Since P5d a sealed receipt purges nothing, so for custody's day
relays serve a reinstalled responder its peer's opener: the DM the peer's init rode, signed and against a prekey the
Keychain still holds. That opener broke the pair in every order it could come in (ADR 2026-10.5sk9's P5d and P5e
limits):

- **before the node's reset**, the node rebuilt the old root from it as a fresh responder and minted its first epoch
  again under a new key, so the peer dropped or failed the node's frames. DMs were lost before a heuristic reset healed
  the pair;
- **after the node's reset**, the opener raced that unanswered reset by node id, ahead of the stale-init check. When the
  peer's id was the smaller, the node took the old root back while the peer adopted the reset, and the pair split for
  two days. This ordering was seen live on 2026-10-18 (ADR 2026-10.5sk9's live-runs amendment);
- **with a room post between**, the node's sealed live tick started a session with a plain init before the opener
  landed. When the node's id was the larger, the peer's remnant guard refused that init, and the pair broke as above.

Kotlin never meets this. Its restore keeps the message rows, whose exists-gate stops the opener, and its clear-data
mints a new identity. Its own rule for an init it already resolved, the `peerInitEphPub` anchor
(`RatchetEngine.kt:575-578` at `4f3cd995`), dies with the session row here. `RatchetRestoreLabTests` pinned every
ordering as a known issue.

**Decision:** both halves of the fix the P5d crypto reviews proposed, with option (i) for the second half's guard. The
maintainer chose this on 2026-10-18 (`.agents/memory/roadmap.md`).

- **Kept ephemerals.** The identity's Keychain item keeps the ephemeral of each init a session of ours anchors, beside
  the prekeys, as a fourth key: `answered: [{peer, eph, at}]` (`PrekeyRing+Answered.swift`).
  - "Anchors" covers a responder's establish, an adopted replacement, and a race won or lost: every open after which the
    session's `peerInitEphPub` is the frame's init.
  - **Stored form.** It grows additively, as `prekeys` did. An older build reads its identity and prekeys by key, and
    its rotation writes every other entry back as it was stored.
  - **Writing.** A write reads the item, checks the identity in it byte for byte, replaces `answered` alone, writes and
    reads back. Only then does `PrekeyRing.answeredInits` change.
  - **When.** The write runs once the answering open's unit has committed, never inside it, since a rollback cannot undo
    the Keychain.
  - **Failure.** A write or read that fails changes nothing, so that init meets a reinstall as it did before this
    change. Loading reads the key in the same read as the prekeys, so before the first unlock it throws, as
    `IdentityKeys.load` does.
  - **Retention.** Entries are keyed by peer, as the node id's 16 bytes. Each is pruned 48 h after its answer. That is
    custody's day doubled, as `STRANDED_TAIL_MS` doubles it (knit-next ADR 026): custody expires a frame at
    `sentAt + 24 h` on its sender's clock, and `at` is on ours. The newest are kept, at most 8 per peer and 256 in all.
    A stored entry this build cannot read is dropped at the next write, since it is a hint, never a key.
- **What a kept ephemeral resolves.** In the open's unit, the facade checks (`isAnsweredBefore`) that the frame's init
  is kept, that the session held is not anchored on it, and that its era is not the session's draining previous root. If
  all three hold, the engine's `OpenContext.initAnsweredBefore` resolves the frame:
  - it establishes, races and replaces nothing, and reads under the roots held, as the start's replay does;
  - with no session held, it is `NO_SESSION`, whatever prekey it names;
  - a failure comes back as `Opening.stale`, which counts toward the heuristic only as `NO_SESSION`, so only while no
    session is held;
  - it is never answered, since the answer is what shifts our indexes at the peer (P5e). A copy that opens read-only
    comes back as `Opening.openedStale`, which skips `answerInit`;
  - at a signed first verdict, every stale frame lets one copy of its id past the router, as a counted failure does, so
    the peer's re-seal after either side's reset is not held for ten minutes.

  This is Kotlin's idempotence rule carried across the reinstall, keyed by the ephemeral as Kotlin's anchor is, never by
  a stamp. It needs no clock, no wire change and no paired change.
- **The previous-root carve-out.** An init whose root the held session still drains as `prevRoot` founded an era we left
  ourselves, by our own reset or by adopting the peer's, and did not lose. It keeps the rules this port has for it, the
  race included; the root is found as Kotlin's `derivesPrevRoot` finds it (`RatchetEngine.kt:642-656`). Without the
  carve-out, a peer that never heard our answer and kept sealing under the old root would never be raced into it after
  our own reset. With it, only an era a reinstall lost reads as stale. Kotlin at `4f3cd995` goes further: it pairs
  `derivesPrevRoot` with `predatesSession` to stop the race for a frame sealed before our session (`:590`, knit-next ADR
  2026-10.j67x, `6d9627b7`). This port has not followed that yet, so it races every such frame until it does (the
  roadmap's owed `6d9627b7`). As in Kotlin, such a frame is answered.
- **A flagged reset at once.** A frame resolved by a kept ephemeral proves the session was lost, which three
  `NO_SESSION`s only suggest. The node seals a flagged reset to the frame's sender at once, through `sendSessionReset`,
  its plan and its floors, under option (i)'s guard (`RatchetResetPolicy.resetsOnAnsweredInit`): while no session is
  held, or the one held is our own unanswered init and no reset has gone since it.
  - In the first state the plan re-roots. In the second it marks the init our frames ride (`decidedBy: .plainInit`).
  - The flag exempts the reset from the peer's remnant guard (`RatchetEngine.kt:605-615`), so the peer adopts it in
    either node-id order at its one-minute floor and re-seals its unacked DMs.
  - The persisted `lastResetSentAt` is the loop guard. In the "after the reset" ordering our reset has already gone, so
    no second one is sent.
  - It goes only at a signed frame's first verdict, as every counted failure does. If the reset declines, the frame
    counts as above.
- **Why option (i).** The tick's plain init is the state the room post leaves, and `plan` already answers it with the
  mark. Option (ii), sealing the reset when the peer's profile pins, is the reset sent at start timed at the pin: it
  fires for every peer a kept ephemeral names, whether or not the opener ever comes back.

**The alternatives, and why not:**

- **The first half alone:** it closes the race, and the lost DMs when the opener comes first. When the node's id is the
  larger, though, the node then starts a session with an unflagged init, which the peer's remnant guard refuses. The
  pair waits for the node's heuristic reset, and the peer's receipts for the node's DMs are lost, since nothing re-seals
  a ctl frame. The lab showed exactly that with the second half taken out.
- **Option (ii):** see "Why option (i)" above.
- **Holding era moves for frames from before the reinstall, by a stamp against our install time:** two clocks compared.
- **A flagged reset beating an unflagged init in the race:** a paired change. It needs the flag on every frame that
  carries a reset's init, and it closes only the second ordering.
- **A reset sent at start, on its own:** it is still unanswered when the opener lands, and a reinstall has no peer list.
  The kept ephemerals are the peer list, and the opener they resolve races nothing.
- **Dropping the prekeys from before the reinstall:** a genuine init against our old pinned prekey goes unanswered, and
  a smaller-id peer's then wins the race at the peer, which darkens that direction for its two-day drain.
- **Custody serving oldest first, holding pre-reinstall frames out of custody, or a cleartext receipt for the opener
  alone:** none promises an order. The second puts the install time into the carry gate, and the third only narrows the
  window, at a privacy cost.

**Consequences / limits:**

- **The cost:**
  - one Keychain write per new anchored init, read back, at most 256 entries of about 75 bytes;
  - one linear lookup per DM frame that carries an init;
  - one more X3DH respond in the open of a kept init while a previous root drains;
  - one flagged reset per reinstalled pair, sealed at once.
- **The opener goes unread when it resets the pair,** like every ratchet DM sealed to the lost session. The first
  install read it and its receipt went, so the peer re-seals nothing for it. A v1 DM still comes back from custody. One
  later copy can open: when our id is the smaller, once the peer has confirmed our re-root, our session is the remnant
  guard's state, so a re-serve of the opener past the router's ten minutes opens read-only under the old root as the
  late race loser's DM (#83). It is delivered and never answered, a sealed receipt for it goes under the new root, and
  nothing about the session moves (`RatchetRestoreLabTests.aLateReServeOfTheOpenerReadsReadOnlyAndMovesNothing`).
- **The start keeps what a keep missed.** Each start, with the switch on, keeps in one write every init a held session
  is anchored on that the item lacks (`keepAnchoredInits`), so a Keychain write that failed, or a process ended between
  an open's commit and its keep, is made good at the next start. An anchor is stamped at a start only when the item
  lacks it or it has lapsed past the 48 h window, so an init a held session is anchored on is kept again at each start
  and at each opened frame that still carries it, within the caps.
- **Not covered: an answer that never left.** If the node answered the opener and reinstalled before its answer reached
  the peer, for instance with the answer still only in its own custody, the peer is still that root's unconfirmed
  initiator. When the peer's id is the smaller, it wins the race against our reset and stays on the old root, which our
  side no longer races into. Our frames reach it read-only, and its frames fail at our side uncounted, until its
  read-only candidate drains after 48 h and its heuristic resets. A peer whose id is the larger adopts our reset.
  Telling the two peer states apart needs either a stamp or a paired change, both set aside above.
- **Unchanged: a reinstalled initiator.** Its peer's frames carry no init, so they recover through the heuristic as
  before (ADR 2026-10.5sk9).
- **One deliberate difference from Kotlin:** a kept init that is not the held session's anchor is never answered and
  never races, even outside a reinstall, unless its era is our draining previous root. That covers a re-served frame of
  an older era the peer has since replaced, which Kotlin judges stale by its stamp and still answers. Here it is read
  the same way and left unanswered.
- **Knit-next:** the rules are shared, and its restore should be checked against the same ordering.
- **The switch off** opens no ratchet frame, so nothing is kept or written, and the bytes on air are unchanged.
- **Guards:**
  - `RatchetRestoreLabTests`: every ordering as plain expectations, in both node-id orders. Each asserts exactly one
    flagged reset from the node and none from the peer, every receipt for the node's DMs read at the node, and the
    opener unread. The orderings are the opener first, the opener after the reset after a longer history, and a room
    post between.
  - `RatchetAnsweredInitLabTests`: the three-engine line with a carrier, in both orders, without the day's wait; a
    second DM on the opener's init re-sealed and read within the minute; the start keeping an anchor a refused write
    missed; and the switch-off frames against an engine with no ring.
  - `RatchetRestoreLabTests.aLateReServeOfTheOpenerReadsReadOnlyAndMovesNothing`: the read-only late copy, unanswered.
  - `RatchetSessionsAnsweredInitTests`: the facade's states and the previous-root carve-out.
  - `PrekeyRingAnsweredTests` and `PeerAnsweredInitsTests`: the stored form on the Keychain double and on knit-peer's
    file.
  - Checked by reverting: with either half taken out, the lab's pins fail as the roadmap predicted.
