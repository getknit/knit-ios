---
id: "2026-10.vzem"
slug: a-request-s-photos-wait
title: "a request's photos wait for accept, and strangers' room photos are bounded"
date: 2026-10-27
topics: [mesh, blobs, security]
---

# ADR 2026-10.vzem — a request's photos wait for accept, and strangers' room photos are bounded

Status: Accepted (2026-10-27)

**Context:** knit-next's malicious-fork review of 2026-10-26 (`eccabcd72`, finding H7) found that a stranger's
attachments are fetched and kept before the user accepts the request, and a room post's are fetched whatever their type.
This port had the same paths (knit-ios #21, checked against `b2a495e`):

- **Message Requests changed only what the screen showed.** `announce` wanted every delivered row's photo, a request's
  included, and the 60 s re-want (`rewantMissingBlobs`) wanted it again. Every identity a fork mints can seal DMs naming
  8 MiB each, and DMs are not metered. The row named the blob, so it outlived restarts until the user deleted the
  request. `Conversations.isAccepted` called itself "a presentation decision only".
- **A room post's attachment was wanted whatever its type.** A modified client could post `audio/*` or any file, which
  nothing screens. knit-next `eccabcd72`, ahead of our pin `e63f15f4`, drops such an attachment on receipt
  (`RoomAttachments.refuses`, its ADR 2026-10.79j9).
- **Room photos had no byte bound.** Each is a want of our own, which a row names, so the 128 MiB echo budget (ADR
  2026-10.7kxj) never counts it. Room posts are metered at a burst of 240, then 30 a minute per link, and each can name
  8 MiB + 64 KiB. Android fetches every one.

Android has fixed none of this at knit-next `4408e0fca` except the room's types. The design passes found three traps:

- **Un-verifying would sweep a thread's photos.** Once acceptance decides what is kept, `setVerified(false)` turns a DM
  accepted only by verification back into a request, and the next sweep removes every photo in it.
- **Acceptance read outside a unit reads an error as "none".** A failed read in the sweep would then make every DM and
  group photo unnamed and remove it.
- **A request row could choose a contact's photo's author.** The re-want took the earliest row naming a hash as its
  author, and a fork's request with an earlier `sentAt` would win.

**Decision:** four local rules, none on the wire, in custody or in the digest.

1. **A photo is fetched only for a thread we may fetch for** (`mayFetch(for:)`).
   - **Fetching** reads acceptance with blocked senders left out of a group's known posters, the way the thread list
     does. So a group whose only known poster is blocked fetches nothing new.
   - **Naming**, which decides what is kept, reads it without subtracting blocks (`conversationsNamed`). So blocking
     someone never sweeps a thread's photos.
   - **Where it is read:** in `announce`, after the unit commits, never inside one. `notePlainHash` still runs for a
     held blob (ADR 2026-10.f3mv). `copyFromOwnStore` waits for the gate, and the want waits for it too.
   - **The re-want and a delivery's reach** read only rows in threads we fetch for (`rowsTaken(_:fetching:)`), before
     they choose the author and the deadline.
   - **`blobsTheRowsName()` names only rows in accepted threads,** inside the bound below, read fresh on every call
     inside the caller's store unit. A blob only a request names is held for others: it counts toward the echo budget
     and goes in the 600 s sweep.
   - **When a thread becomes accepted, its photos are wanted at once** (`wantAcceptedPhotos()`). That happens on accept,
     on verify and on a scan. A group that becomes accepted on a known sender's first post waits for the next 60 s
     re-offer.
   - **No basis for acceptance is removed before acceptance is written.** Un-verifying a peer first records the DM, and
     every group the peer posted in, as accepted (`keepAccepted`).
2. **The room's attachment types follow Android's `RoomAttachments`** (`RoomAttachments.kt:18-63`,
   `InboundPipeline.kt:1115-1124` at `4408e0fca`).
   - **Admitted:** no type, `image/*`, the link-preview card, and `video/*`, the last of which this build shows as a
     file (#9). The comparison is case-sensitive by bytes, on the type as the frame carries it.
   - **Anything else** is left off the row. A post that is nothing but such an attachment, its body blank by Kotlin's
     `isBlank()`, keeps no row and is still acknowledged.
   - **`carriedBlobs()` leaves a refused hash out.** The frame, custody and the relay are untouched, so every node
     decides this from the frame alone.
3. **Strangers' room photos are bounded** (`StrangerRoomPhotos`, the maintainer's call).
   - **The rule:** a stranger's room photo is fetched and named only while it is among that sender's newest 8
     (`perSender`) and, of those, among the newest 32 of all strangers (`overall`). That is about 256 MiB.
   - **Who is exempt:** us, a peer whose DM thread is accepted, a verified peer, and a peer we have written to
     (Android's `knownSenders`, `MeshManager.kt:3010`).
   - **"Newest"** is the stored `sentAt`, then the id by its bytes, so the engine, the screens and two phones holding
     the same rows agree. A `sentAt` dated ahead is clamped to five minutes on the way in.
   - **Readers:** the want gate, the re-want, the naming and `carriedBlobs()` read the same rule. A photo it leaves out
     is neither wanted nor named, so the sweep removes it. Live posts arrive oldest first, so each is its sender's newest
     as it lands and is wanted then. A want the bound has since pushed out is withdrawn, with a `blobcancel`, as the next
     photo arrives and at every re-want, unless its bytes are already streaming in.
   - **Not an eviction budget.** A blob evicted while a row names it is wanted again at the next re-offer, and that
     loops.
4. **The screens read the same rules** (a later change in #21): a request's tile waits for accept, and a room photo past
   the bound says it is not downloaded.

The alternatives the design pass turned down:

- **Want tiers**, which would rank strangers' photos below our accepted threads in a full want set. The room bound
  already caps a room flood's own wants at 32, so tiers wait for a follow-up.
- **Sharing the echo budget with room photos.** A fork's echoes would starve the room, and a room flood would starve
  every honest pull-through.

**Consequences / limits:**

- **An accepted request's photos may never load.** A request accepted more than 24 h after its latest row carries a
  pull-through deadline already past (ADR 2026-10.8hek), so only a neighbour holding the photo can serve it: the author,
  or a node that echoed it.
- **A reinstall loses the accepted set** with the database. Contacts' DMs re-served from custody come back as requests,
  and their photos wait for an accept. A thread we wrote in becomes accepted again as our own frames come back.
- **A room photo past the bound comes back only if the bound readmits it:** a newer row goes, by a delete or by
  retention, or its sender becomes known. It is then wanted again at the next re-offer, and fetched if a holder is in
  reach.
- **Un-verifying keeps a thread accepted.** A DM a scan verified, which nobody wrote in or accepted, stays a chat after
  un-verify, where Android turns it back into a request. Removing the acceptance would have swept its photos.
- **The bound limits what is wanted and kept, not what was already served.** Posts that trickle in slower than one
  photo crosses each land before newer ones push them out: each is fetched once, then swept. In a burst the wants are
  withdrawn before any ask stands, so nothing crosses for the photos pushed out.
- **A withdrawal drops a neighbour's pull-through on that photo.** The neighbour hears nothing, since a `blobreq` has no
  negative answer. It asks again at its floor, 45 s past its last ask, and is then served through an echo.
- **Each stranger's room photo reads every row naming a photo** once on arrival. Room ingress bounds how often, and the
  retention in #21's next change bounds the rows.
- **Peers' advertised photos are unchanged,** and still fetched for strangers: knit-ios #22.
- **When knit-next fixes H7,** read its rule against these, and re-align any that differ for a reason Android found.
- **Guards:** `MeshEngineRequestPhotoTests` and `MeshEngineRequestPhotoGroupTests` (the gate, the ratchet and group
  ratchet requests, the replays, the un-verify keep and the guarded releases); `LinkPipeRequestPhotoTests` (a request's
  photo crosses only once accepted, and then once); `RoomAttachmentsTests`, including two engines agreeing on `liveIds`;
  `StrangerRoomPhotosTests` (the rule, and wants withdrawn as newer posts arrive); `LinkPipeRoomBoundTests` (a burst of
  12 photos from one stranger crosses as 8 copies); and `MeshEnginePhotoTests`, with stranger DMs accepted first or
  asserting no want.
