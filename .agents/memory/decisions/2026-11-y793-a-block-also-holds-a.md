---
id: "2026-11.y793"
slug: a-block-also-holds-a
title: "A block also holds a person's profile and photo"
date: 2026-11-01
topics: [moderation, privacy, ui]
---

# ADR 2026-11.y793 — A block also holds a person's profile and photo

Status: Accepted (2026-11-01). Mirrors knit-next ADR 2026-11.nsbf (knit-next #249, option 1; `c112277ce`, merged to
its `main` from `fix/block-hides-profile` and mirrored ahead of the pin), a paired change (`block-hides-profile`,
knit-ios #37) led by Android. Amends ADR 2026-10.5wgg, whose "Untouched" list named profiles, and ADR 2026-10.r88m
and ADR 2026-10.nh55, which said a block left peers' photos alone.

**Context:** a block hid a person's messages, and their profile kept updating. Their new name, status and photo
showed wherever their row is drawn: their profile, group member lists, mentions and quotes, and the Blocked list.
The iPhone also fetched and kept their photo. knit-next #234's profile door cap (knit-next ADR 2026-10.jgeg, ADR
2026-10.r88m here) left blocking out as a product decision. The maintainer chose #249's option 1: hold the
presentation, keep everything the mesh relies on. Option 2, which also stops our own profile and photo going to
them, was turned down, because the blocked person would notice (knit-next ADR 010).

**Decision:** from the moment of a block, the phone keeps the person's name and status as they were, shows no photo
for them, and fetches and keeps none. Nothing changes on the wire. Nodes with the change and nodes without it carry,
serve and relay the same frames, so custody converges as before (ADR 2026-10.5wgg's trap).

- **When a profile counts as blocked.** A cleartext profile counts when its sender's node id is blocked or its device
  tag is. `handleProfile` runs `continueBlock` before the row is written, not after, so a re-keyed phone that
  continuity catches presents nothing, not even on its first profile. Continuity's conditions are unchanged.
- **What a blocked profile still does.** It pins, and a key change is still refused. It is kept as the proof of key
  (`recordProfileFrame`), cached and served by `KeyExchange`, carried in custody and relayed. Its device tag,
  protocol version, capabilities, prekey and the prekey's watermark move. So does `updatedAt`, the presentation's
  watermark, which lets the unblock's re-apply pass the version check. The flushes, `onProfilePinned`,
  `answerOwedInit` and the parked release run as before. A blocked profile is no drop, so it counts nothing.
- **What it no longer does.** It writes no name, status, `openToChat`, `advertisedAvatarHash` or `avatarHash`
  (`profileRecord(…, blocked:)`, whose presentation goes through one helper, `presentation(of:onto:)`). It adopts no
  held bytes, wants no photo and lets no replaced photo go. The sealed `CTL_PROFILE` already dies at `handleChat`'s
  gate on every route.
- **On block** (`hideBlockedPhotos(of:)`), from `block`, from a continuity block and from the sweep:
  - the row's shown photo is cleared, so their face is their initial. `advertisedAvatarHash` stays, unread while they
    are blocked, as the record of the photo the unblock brings back;
  - a want of ours made only for that photo is withdrawn, unless an unblocked row advertises the same hash, an
    attachment or an asker holds the want (a neighbour pulling it through us included), or its bytes are already
    arriving. The 60 s re-offer and the sweep withdraw it again once they are not. The rows and the block list are read in
    one store unit;
  - the bytes are left to the sweep of unnamed blobs, which checks `isBlobInUse`. `releaseBlob` does not.
- **While blocked:** `followAdvertisedPhoto`, `rewantMissingBlobs` and `adoptAvatar` skip them. A photo they push is
  refused unless a want of any kind or something the rows name covers its bytes (an echo, an attachment, another
  unblocked person advertising the same hash, our own photo). Then it is kept as those bytes, never shown as their
  face.
  `blobsTheRowsName` names no hash from their row. So the echo budget counts their held photo until the sweep takes
  it, `Deletes.release` no longer keeps it for them, and an unwanted copy streamed to us is refused.
- **Our own profile and photo still go to a blocked neighbour,** pushed and sealed as to anyone.
- **On unblock** (`unblock`, `addContact(.link, unblock: true)`), and only for a peer who was blocked by node id or by
  the row's tag:
  - `reapplyHeldProfile(of:)` re-applies the presentation of the profile frame held in `peer_profiles`, with the
    normal ordering: an equal version applies, an older one nothing. It goes through no `deliver`, so nothing is
    carried, cached, counted, flushed or released;
  - then, whatever the re-apply decided, the face comes back from the row's kept `advertisedAvatarHash` (contract
    revision 1). Bytes held and inside the photo's ceiling are adopted at once. Otherwise the photo is wanted with
    the photo's ceiling from any holder, the person too when linked, since their push memo already holds the hash
    and they will not push it again. That includes a row whose `avatarHash` equals the hash with the bytes gone. A
    photo refused this session stays refused. The restore holds without a memo (contract revision 2): the row keeps
    the hash, and every 60 s re-offer and every start want it from anyone, the linked person too, until the face
    shows, a newer profile names another photo, or the block returns. An unblock while the mesh is stopped re-applies
    at once, and its photo is wanted at the start;
  - `addContact` reads the row again after the unblock, so its write keeps the re-applied presentation.
- **Settled at once:** `Mesh.block` and `Mesh.unblock` settle, so the screens hear of the cleared face.

**Consequences / limits:**

- The name a blocked person had at the block stays visible: in groups, on their profile, in the Blocked list, and in
  mentions and quotes. Only their changes are held. Hiding the name itself would be a separate decision.
- Their face becomes their initial at the block, even if they never change their photo.
- They get no notice for anything they changed while blocked. The iPhone writes no rename or new-photo lines anyway.
- An unblock with no frame held, or with a frame older than the row's presentation, keeps the name and status the row
  had until their next profile. Honest phones republish theirs every 12 hours: the iPhone from `republishIfStale`
  (`MeshEngine+Profiles.swift`), Android from `PROFILE_REPUBLISH_MS` (`MeshManager.kt:5140` at knit-next `c112277ce`,
  checked from its heal and its heartbeat).
- Two edge cases differ from Android on unblock, both because Android keeps no durable advertised hash: its
  `advertisedAvatars` is in memory, and it restores the face from the held frame's hash instead.
  - With no frame held, the iPhone restores the face from before the block; Android shows the monogram until their
    next profile.
  - When a sealed profile from before the block carried a different photo from their last cleartext frame, the
    iPhone restores the sealed one and Android the cleartext one, until their next profile.

  Neither touches an honest person in the common case: a frame is held once they have sent any cleartext profile,
  and their two profiles carry the same photo.
- Two differences from Android while blocked, both because the iPhone tells a photo's bytes apart from whose face they
  are:
  - Android's `onAvatarReceived` refuses a blocked neighbour's push before it stores the bytes. The iPhone keeps the
    bytes when another want or row needs them, so the copy already on the link is not fetched again elsewhere; it
    is still never their face.
  - Android has no way to take back a want, so its photo ask for them simply lapses. The iPhone withdraws its own
    photo-only want with a `blobcancel`, as it does for a room photo past the room's bound, so a holder stops
    streaming bytes nobody will show.

  Neither changes custody, the digest or anything a carrier relays.
- A photo transfer already running at the block may finish. It is never adopted as their face, and its bytes go by
  the sweep. `carriedBlobs` can keep a blocked person's photo bytes for up to 24 hours while custody carries their
  sealed profile, as a carried frame's hint; that never shows it.
- An existing quirk stays: unblock removes the row's current device tag, so a tag that changed during the block stays
  in the blocked set, on both phones.
- Out of scope: hiding the name or drawing a blocked person as "Blocked", stopping our own profile to them, and the
  `.link` contact card writing its name into a blank row for a blocked id, which is the user's own scan.
- **The guards:** `MeshEngineBlockProfileTests` (what a blocked profile moves and holds, continuity's first profile,
  the re-apply's ordering, keys and cleaning), `MeshEngineBlockPhotoTests` (the push, adoption, the withdrawal and
  the sweep), `MeshEngineUnblockPhotoTests` (the unblock's face, `addContact`, and two engines asking the person for
  the photo they pushed during the block), `MeshEngineUnblockFaceTests` and `MeshTests+Unblock` (the restore holds
  past a lapsed want, a restart and an unblock while stopped, and ends when the face shows, a newer profile takes
  over or the block returns), `MeshEngineBlockPhotoEdgeTests`, `MeshEngineBlockTests`'
  `aBlockedSendersPhotoIsNotFetchedNorTheirProfilePhoto`, `MeshEngineRatchetInboundTests`'
  `aBlockedPeersSealedProfileDiesAtTheBlockedGate`, and
  KnitAppCore's `BlockTests`' `aBlockKeepsTheirNameAndShowsTheirInitial`.
