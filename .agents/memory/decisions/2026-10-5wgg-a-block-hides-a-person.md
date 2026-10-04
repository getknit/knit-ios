---
id: "2026-10.5wgg"
slug: a-block-hides-a-person
title: "A block hides a person and changes nothing the mesh sees"
date: 2026-10-03
topics: [moderation, privacy, custody, ui]
---

# ADR 2026-10.5wgg — A block hides a person and changes nothing the mesh sees

Status: Accepted (2026-10-03)

**Context:** the iPhone could not block anyone, and App Store rule 1.2 wants block before a store build
(`.agents/memory/roadmap.md`). Knit for Android has blocked since ADR 010 there, and its ADR 2026-09.bts9 took the
block list out of everything but delivery:

- **A block hides; it does not refuse.** `InboundPipeline.handleChat` (`:662-676`) checks the sender before it
  decodes anything. For a blocked sender it stores nothing, notifies nothing and reconciles no roster. It still ticks
  a room post, and a group post in a group it holds and has not left (`ackBlockedRoomChat`, `:819-842`). That tick
  goes point to point and nobody carries it, so the blocker may be the sender's only acker, and withholding it would
  both strand their ✓✓ and tell them. A DM gets no receipt, because a DM receipt floods and purges every carrier's
  copy.
- **Custody never reads it.** bts9 found Android refusing to carry a blocked sender's frames. A neighbour re-served
  them at every digest exchange, and the blocker's fingerprint never matched anyone's for as long as the block
  stood. The block is now read on the delivery path only, and a DM sent during a block stays unseen after the
  unblock: the blocker holds it in custody, so nobody serves it again.
- **The rest is presentation.** The DAO's read filters hide what a blocked person wrote before the block and bring it
  back on unblock. Their DM leaves the chat list, their requests leave the inbox, and they leave the contacts. Group
  rosters keep them. A device tag in each profile blocks the same phone under new keys
  (`applyDeviceTagBlockContinuity`, `:3258-3273`).

**Decision:** the same rule here, read in the same places.

- **The store:** `BlockStore` in KnitStore holds node ids and device tags, with tags compared by their bytes (ADR
  2026-09.jc2x). `SQLBlockStore` keeps them in schema v6's `blocked_nodes` and `blocked_device_tags`, two `STRICT`
  tables beside `accepted_conversations`. Android keeps the set in DataStore, but the engine here reads only
  `MeshStores`, and the database already has the protection the list needs. A block keeps the device tag the
  person's profile carried, as Android's Block buttons pass it.
- **The gate:** the first lines of `MeshEngine.handleChat`, before the group dispatch, so a parked frame and the
  start-up group replay meet it too. `dropBlocked` ticks as `ackBlockedRoomChat` does and counts the frame under
  `DropReason.blocked`. Beyond the gate, `reconcile` refuses a blocked sender's roster and the first frame of a group
  a blocked person made (`groupFrameRefused`), and `handleGroupLeave` ignores a blocked member's leave.
- **Device tags:** `handleProfile` runs `continueBlock` after the upsert and before the waiting DMs go out and the
  parked frames land, so a re-keyed phone's early frames meet the block. `flushPending` holds a DM to someone
  blocked, as `flushPendingFor` does.
- **Untouched:** `isCarriable`, the custody carry, key requests, receipts, the relay and profiles. A blocked person's
  key still pins and their photo is still fetched, and only their messages' photos are not.
- **The screens:** `ThreadTable` reads thread heads without blocked senders (`threadHeads(excludingSenders:)`), drops
  a blocked person's DM, and leaves blocked senders out of the group-accept rule. `ChatModel` hides their rows, and
  New message leaves them out. Block is on the profile, a DM request's row (a swipe) and its thread's request bar.
  The list of blocked people is in Settings, where iOS keeps it. Android's sits in the chat list's menu. Block asks
  first every time, in an alert; Android asks only on a request. A confirmation dialog was tried first: iOS 27 drew
  it as a popover too narrow for its message and still growing when the audit read it. Unblock never asks. Blocking withdraws the DM's notification,
  and the requests notification once no request is left.
- **One divergence:** a blocked person's DM shows Unblock in the composer's place. Android keeps the composer, and a
  DM sent there to someone blocked would wait for their key here, so the bar says what to do instead.
- **Control:** `block` and `unblock` (`peer`), a `blocked` field on `peers` and on `profile` events, and `status`'s
  `dropped.blocked`. `interop.py iphone-block` drives them against an Android phone.

**Consequences / limits:**

- **A group message can surface after an unblock.** Our own custody holds a group message sent during the block for
  up to 24 hours, and `replayCustodiedGroupChats` delivers it at the next start after the unblock. Android replays the
  same way at start-up and at heal (`MeshManager.kt:1622-1654`), so the two agree, though bts9's corollary speaks only
  of DMs. A DM or a room post never comes back. The copy therefore promises nothing about what was sent during a
  block: the confirmation says what stops while it stands, and the list says an unblock brings back what came before
  it.
- **A DM to a blocker never ticks.** Its sender's copy waits in every carrier's custody until its TTL, as on Android.
- **No report.** Android has none either, despite `docs/IOS_PORT_REVIEW.md` there. Rule 1.2 still wants one.
- **Blocked people stay in groups:** on the roster and in the faces, sealed to like everyone else.
- **The trap:** a per-node input in `isCarriable` or anything custody reads (a block, a setting, a verdict) makes this
  node's digest differ from everyone's for as long as the input stands, as bts9 found. A local decision belongs on
  the delivery path.
- **The guards:**
  - `MeshEngineBlockTests`: the tick rule, carrying and relaying, the roster door, device tags, a DM that stays
    unseen after an unblock, and the group message the start-up replay delivers after one.
  - `BlockStoreTests`, and `RepositoryTests`' `aThreadsHeadSkipsWhatBlockedPeopleWrote`, against both stores.
  - `SchemaTests`' v6 pin and `v6BlocksNobody`.
  - `BlockTests` in KnitAppCore, `MeshControlTests`' `peersAndProfilesSayWhoIsBlocked`, `KnitUITests`' two block
    walks, and `interop.py iphone-block` on the phones.
