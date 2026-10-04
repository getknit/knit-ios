---
id: "2026-10.nh55"
slug: profile-photos-and-photos-in
title: "Profile photos and photos in chats come to the iPhone, carried as Android carries them"
date: 2026-10-03
topics: [scope, blobs, interop]
---

# ADR 2026-10.nh55 — Profile photos and photos in chats come to the iPhone, carried as Android carries them

Status: Accepted (2026-10-03)

**Context:** Knit for Android moves bytes as well as frames, in three ways:

- **Its own profile photo.** At link-up it pushes the photo as FILE records: a 256-pixel JPEG, under the hash its
  signed profile advertises (`MeshManager.kt:2556-2622`).
- **A photo in a chat** travels as a hash in the frame. The bytes are fetched one hop at a time with the unsigned
  `blobreq` frame, which any node holding them answers (`BlobExchange.kt`).
- **Carried frames.** A carrier pulls the bytes of the frames it carries, up to 128 MiB (`FrameFanout.kt:76`).

The MVP left all of it out (`.agents/specs/mvp.md`):

- `LinkManager` discards FILE records;
- `blobreq` is ignored;
- a peer's `avatarHash` is dropped;
- a photo from Android shows as an empty bubble.

The roadmap listed avatars and attachments as deferred by design. Checklist L counted what passed by. Android sends
its photo as three records at each link-up, and the both-ways soak on 2026-09-26 discarded the three records its
photos carried (`.agents/context/linux-peer.md`).

**Decision:** on 2026-10-03 the maintainer asked for all of it, in this order:

1. **Blob transfer and profile photos,** as one milestone: FILE records both ways, `blobreq` both asked and
   answered, our own photo published and pushed, and every peer's photo shown wherever that person appears.
2. **Photos in chats, both ways,** in Nearby, DMs and groups. They are sealed in DMs and groups as Android seals
   them (`AttachmentCrypto.kt`), and travel in the clear in Nearby, as Android sends them there.
3. **Group photos shown, never set,** with Android's split between the decided photo and the shown one (knit-next
   ADR 2026-09.nxcq).
4. **Carrying blobs as Android does:** serve every blob the iPhone holds, fetch one on an asker's behalf, and pull
   the blobs of carried frames, within Android's 128 MiB.

   This is ADR 2026-09.p6nb's reasoning, carried over to bytes. Serving only what it shows was the cheaper
   alternative, but it would make an iPhone in a line the place where a photo stops, while its caption crosses.

Files and voice notes stay out, and so does `CAP_FILES` (`0x200`).

- **No paired change is needed.** Android gates only arbitrary files on `CAP_FILES`, and images on no bit at all
  (knit-next ADR 2026-09.qq2r). So `Capabilities.local` stays `0xB`, and Carol's emitted profile does not move.
- **Shared vectors** for the FILE records, `blobreq` and a sealed photo are companion change A7, which this port
  leads.

Two choices differ from Android's on purpose:

- **A pushed photo must match the signed profile.** A push is adopted only when its hash is the one the peer's
  signed profile advertises.
  - Android adopts a push at once and credits it to whoever the link's HELLO names. That HELLO is
    unauthenticated (ADR 2026-09.6es2), so a phone claiming someone else's node id could set their photo.
  - Android writes the profile ahead of the push on the same link (`MeshManager.kt:2562-2563`), so an honest push
    always matches.
- **A `blobreq` is never flooded,** even one marked `relay = true`, and its hash must be 64 lowercase hex
  characters. No build sends anything else.

**Consequences / limits:**

- **Photos are not screened.** Strangers' profile photos and Nearby photos show as Android shows them with its filter
  off. Screening (`docs/CONTENT_MODERATION.md` in knit-next) comes with moderation, which App Store rule 1.2 requires
  before any store build (`.agents/memory/roadmap.md`).
  (Amended 2026-10-04: photos from others are screened now, with Android's model and policy, when they are first
  shown; ADR 2026-10.rpmq.)
- **What is public:**
  - A profile photo and a Nearby photo are readable by every node in range, like the name and the post.
  - A DM or group photo is sealed under a fresh key that only the sealed message carries. A carrier sees an opaque
    blob and its size.
- **Air time and storage.** The iPhone spends air time on other people's photos, and up to 128 MiB of storage, as
  every Android phone does. A file streams at 28 KiB/s at most, and each link carries one file each way at a time.
- **Each phase records its own decisions:** the FILE feed, the blob exchange, profile photos and sealed photos, each
  as an ADR in the change that builds it. Step 0 also mirrors `photoWins` (ADR 2026-09.n393, amended).
- **Guards:**
  - `LinkTests`, which pins `0xB`;
  - `EmittedVectorTests`, which keeps Carol's profile;
  - the tests each phase's ADR names.
