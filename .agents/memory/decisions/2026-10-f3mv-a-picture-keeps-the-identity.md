---
id: "2026-10.f3mv"
slug: a-picture-keeps-the-identity
title: "A picture keeps the identity it arrived under"
date: 2026-10-08
topics: [blobs, crypto, privacy]
---

# ADR 2026-10.f3mv — A picture keeps the identity it arrived under

Status: Accepted (2026-10-08). No wire change and no paired change. Schema v12 adds two local-only `messages`
columns.

**Context:** the iPhone sealed every DM and group photo under a fresh key (`sealPhoto`), so the same picture sent N
times became N unrelated blobs, and every recipient pulled each one, including a recipient that already held the
picture. Android carriers paid for each copy out of their 128 MiB. Knit for Android stopped doing this in
`01b2fd5d` (knit-next ADR 2026-10.mptm, with `5f521cb9` and `3a6f5d08` after it): a phone seals a given plaintext
once. This port already received what that sends: a sealed message naming a room picture by its plaintext hash
with no key, and one blob named by many messages. It never reused anything itself (ADR 2026-10.m4ah's limits).

**Decision:** mirror mptm, with the differences below.

- **A pick that this phone already holds goes out as that blob** (`MeshEngine.heldPhoto(picked:)`, a port of
  `AttachmentStore.reused` and `AttachmentIdentities.plaintextOf`).
  - `ChatModel.choosePhoto` asks before the codec, so a hit is never decoded: a forwarded GIF keeps its frames and a
    forwarded photo loses nothing. The room's pick-time screen still runs on it (ADR 2026-10.spcy).
  - The picked bytes' hash is matched against a sealed row's plaintext name, a send's picked bytes, or a room row's
    own hash (`MessageStore.identities(matching:)`, `MessageDao.identityFor`). A room post wins, since its public name
    is the one most phones nearby hold, then a moving picture, then the earliest.
  - Only a row whose blob is still held counts, and a source match must open to the plaintext its row names.
  - `sealPhoto` sends `OutgoingPhoto.identity`'s hash and key when that blob is still here, and seals afresh from the
    bytes in hand when it went between the pick and the send. A room picture goes into a DM or a group with no key.
  - A sealed picture posted to the room goes under its plaintext's hash, as any room post does.
- **Where the plaintext's name comes from** (`attachmentPlainHash`):
  - our sealed send writes it;
  - an arrival writes it once its blob is here, from `receiveFile` or from `deliverChat` when the blob was already
    held (`notePlainHash`, `notePlain`);
  - Save writes it, from the bytes it opened (`AppSession.attachmentToSave`, `ChatViewModel.saveAttachment`).
  `attachmentSourceHash` keeps the picker's bytes for one of our sends whose preparing changed them, so the same
  original picked again is found.
- **A key-less frame from someone already in the chain is shown from our own copy** (`copyFromOwnStore`,
  `InboundPipeline.copyFromOwnStore`). A key-less picture that is neither held nor arriving is opened out of a sealed
  copy with that plaintext name, checked against the hash, and held under it. That happens only when the frame's
  author is the copy's sender, the DM's other side, or a member of its group (`MessageDao.sealedHolding`). Then
  `.attachmentArrived` redraws the thread.
- **The picker asks for `.current` encoding,** so Photos hands back the file Knit saved rather than a transcode.
  Save already wrote the bytes as they were sent (ADR 2026-10.6cas). Without this, a saved picture picked again would
  match nothing.
- **The control lines** `room`, `dm` and `group-send` look for a held picture first, so the bridge and `knit-peer`
  behave as a pick does. The reply adds `reused`.
- **The encryption sheet** says that a photo first posted in Nearby stays public when shared in a DM or group.

**What differs from Android:**

- **Screening.** Android screens a local copy as it lands (`MeshBlobStore.ingest`). This port screens photos when they
  are drawn (ADR 2026-10.rpmq), so a copy needs nothing more.
- **One door for the local copy.** Android also copies in `onCarriedFrame`. This port pulls no carried frame's picture
  yet (ADR 2026-10.nh55, Phase 4). That door belongs beside the carrier pull when it lands, with the same author test.
- **No guard against a source that moves.** Android refuses a still found by a source that animates, which was a send
  flattened before its #133. Here a source hash exists only since v12, after GIFs went as moving pictures (ADR
  2026-10.m4ah), so none was ever flattened.
- **A plaintext name on arrival.** Android learns one in `describeHeldAttachment` too. Here `receiveFile` opens a
  sealed blob once more to name it, when a row wants the name.

**Rejected:**

- **Convergent encryption** (the key derived from the file): anyone holding a file could then scan carried frames
  for who passes it to whom.
- **A sealed plaintext hash on the wire:** it saves only a recipient's last hop, and needs both apps to change.

**Consequences / limits:** these are mptm's, here too.

- **Carriers see equality.** Two frames that name one hash carry one picture, and the envelope says between whom.
  Anyone who received the key can recognise the blob on any later frame.
- **A Nearby picture forwarded into a DM or a group names the room's hash,** so every phone that holds the post can
  see that the chat carries it. The chat's words stay sealed.
- **Independent sources stay separate,** and a stranger's room post of a picture we hold only sealed is pulled.
  A post that lands before its sealed twin learns its name is pulled too.
- **A forward carries the bytes as they arrived,** metadata a peer's phone left in them included.
- **No backfill.** A row stored before v12 learns its name only when it is saved.
- **The trap:** the copy hangs on `deliverChat` alone. Hung on `wantBlob`, `handleBlobRequest` (a `blobreq`, signed
  by nobody) or the re-want, it would let anyone holding a file post it and watch who answers unasked: a confirmation
  oracle. The sealed row with no plaintext name must never answer `identities(matching:)`, or its ciphertext's hash
  would stand in for the plaintext's.
- **Guards:**
  - `AttachmentIdentityStoreTests` (both stores): the order, the source match, the trap's guard, and a save that keeps
    the names.
  - `SchemaTests` (v12).
  - `MeshEngineIdentityTests`: a forward under its identity, a room picture's key-less name, a gone blob sealed fresh,
    our original found again, the DM peer and the group member copied locally,
    `aStrangerPostingTheFileLearnsNothingFromUs`, and `aBlobRequestNeverOpensOurSealedCopy`.
  - `ChatPhotoTests`: a held pick skips the codec, a fresh pick remembers its source, and Save names the plaintext.
  - `PhotoScreeningTests`: the room refuses an explicit held pick.
  - `MeshControlPhotoTests`: the `reused` reply.
