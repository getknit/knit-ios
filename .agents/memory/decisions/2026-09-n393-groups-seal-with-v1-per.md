---
id: "2026-09.n393"
slug: groups-seal-with-v1-per
title: "Groups seal with v1 per-member wraps until the ratchet lands"
date: 2026-09-30
topics: [crypto, groups, interop]
---

# ADR 2026-09.n393 — Groups seal with v1 per-member wraps until the ratchet lands

Status: Accepted (2026-09-30)

**Context:** knit-next seals a group message in one of two forms (`docs/GROUP_FORWARD_SECRECY.md` §1 and §5):

- **v1:** a fresh AES-256-GCM key for each message, wrapped with HPKE to each member's static key.
- **The group ratchet:** sender-key epochs whose seeds ride v2 DMs.

Android chooses the form message by message. It uses the ratchet only when every other member's pinned profile
carries `CAP_RATCHET` and a prekey (`MeshManager.kt:1191-1225`). A single member without both puts that whole
message on v1.

This port advertises `0x9` and publishes no prekey (ADR 2026-09.qsd9). Every Android sender therefore already
seals v1 to any group with an iPhone in it, and every knit-next build opens v1. Until now the port carried and
relayed group frames but showed none (`MeshEngine+Inbound.swift`, ADR 2026-09.p6nb). The maintainer asked for
groups on 2026-09-30, without forward secrecy.

**Decision:**

- **Groups are v1 only.** The port seals and opens v1 group messages. It carries, relays and drops the ratchet
  form, as it does v2 DMs. Capabilities move from `0x9` to `0xB`, adding `CAP_GROUPS` to end-to-end and
  store-and-forward. Android reads that bit for nothing but diagnostics (`Protocol.kt:151-154`), so the air
  carries the same frames either way.
- **The roster rules are Android's.** They are ported from `InboundPipeline.kt` into `GroupRoster`, each with its
  citation:
  - a group's id is the hash of its founding roster (`Conversations.groupIdFor`);
  - the founding set never grows;
  - only a member's own signed `groupleave` shrinks the effective roster;
  - a member who left comes back only through a frame of their own, newer than the leave;
  - a name is last-writer-wins on the frame's clamped clock.
- **Status lines are message rows** with a new `kind`, using Android's codes and ids (`StatusNotices.kt`), so a
  thread reads them in order. Leave and rejoin clocks live in the group store, not in those rows as they do on
  Android. A crash between two writes cannot then separate a departure from its clock.
- **Where this port differs from Android.** Each difference is local and adds no frame type or field.
  - A group message that no member can open yet waits as `pendingKey`, and is sealed once a member's key pins.
    Android saves it as Sent and never sends it (`MeshManager.kt:1088-1096`). It was never signed, so its id is
    still signed only once.
  - Sending asks for the keys of members we lack (`keyreq`). Android skips those members silently.
  - A group chat in the clear is dropped, as a cleartext DM already is. Android shows it.
  - An inbound status line never names us, unless the frame is ours. On Android, a stranger who sets `createdBy`
    to our id makes the `created` row count as ours (`MessageDao.kt:294`). Their group then skips the request
    inbox and notifies.
  - A new photo hash is stored at once. Android keeps the old hash at the new clock until the bytes land
    (`InboundPipeline.kt:2334`). This port never fetches the bytes, so copying that would re-assert the old hash
    on every frame it sent and revert the photo for everyone else.
  - Once nobody else is left in the group, the composer is disabled.
  - There is no photo status line, because photos are out of scope.
- **Mirrored on purpose,** so both platforms agree on a group's state:
  - a member who missed a rename can revert it with their next message;
  - `createdBy` follows the latest frame;
  - a leave that arrives before its group is lost;
  - after a wipe, a sender cannot re-read its own v1 group messages.
- **A5 pins the bytes.** Companion change A5 adds keyed group vectors to knit-next. Until it lands, the group id
  goldens are computed in Python from the Kotlin, the way the device tag's were.

Left out, and why:

- **Group photos:** the iPhone keeps no blobs.
- **Reactions, typing, mentions and replies in groups:** they are out everywhere in this port.
- **Delete chat:** DMs lack it too.
- **"Delivered to N of M":** no screen shows per-member receipts.
- **Retention for request threads.**

**Consequences / limits:**

- **No forward secrecy.** Whoever later takes a member's X25519 key can open every v1 group message sent to it.
- **What travels in the clear.** A group's roster and name ride on every group message, and its ticks are
  cleartext. `SECURITY.md` says so.
- **Every group with an iPhone in it stays on v1.** It does so for every member until the ratchet lands here.
  Android's group info says "Legacy encryption until <name> updates Knit".
- **Missing keys.** A sender skips members whose key it has not pinned, on both platforms. This port asks for the
  missing keys when it sends, and Android does not.
- **The A6 fixes.** A6 should take both Android fixes above, the `createdBy` request bypass and the photo race,
  as a paired change. Until then the two platforms keep their differences.
- **Guards:**
  - `GroupIdTests`, for the goldens;
  - `GroupRosterTests`, for the roster rules;
  - `MeshEngineGroupTests`, for sealing, delivery, notices and the differences above;
  - `GroupStoreTests`, over both stores;
  - `SchemaTests`, for v3;
  - `LinkTests`, which pins `0xB`;
  - A5's vectors, once they land.

**Amended 2026-10-03, when group photos came into scope (ADR 2026-10.nh55):** both A6 fixes are now on knit-next's
`main`: `cb8bc4b5`, and `f46770a9` with its ADR 2026-09.nxcq.

- **How Android now handles a photo.** It stores the decided hash at once, as this port already did, and shows the
  new photo only once its bytes land.
- **Ties.** A tie now goes to the incoming photo only while nothing is held (`photoWins`, `InboundPipeline.kt:2378`).
  Here a tie used to go to the frame; it now follows `photoWins` (`GroupRoster.photoWins`, knit-ios#1).
  `GroupRosterTests.aTieKeepsTheHeldPhotoAndTakesOneOnlyWhenNoneIsHeld` pins it.
- **Photos are in scope.** The iPhone will fetch and show a group's photo, but never set one.
- **The `createdBy` rule stays this port's own.** It also checks that the creator is a founding member, which Android
  does not.

**Amended 2026-10-04, when reactions came into scope (ADR 2026-10.ehe6):** reactions are no longer out. The iPhone
takes and sends them in groups as in DMs and Nearby, as the cleartext `reaction` frame Android floods toward a member
without the ratchet, so a group's reactions travel unencrypted, as its ticks do. A group shows reactions only from its
founding roster. Typing, mentions and replies stay out.

**Amended 2026-10-13, when replies came into scope (ADR 2026-10.mn29):** replies are no longer out. A group's reply
carries its quote sealed inside `MessageContent`, as a DM's does, and quotes any message the group shows. Typing and
mentions stay out.
