---
id: "2026-10.6cas"
slug: a-photo-in-a-chat
title: "A photo in a chat is sealed in DMs and groups and public in Nearby"
date: 2026-10-03
topics: [blobs, crypto, app]
---

# ADR 2026-10.6cas — A photo in a chat is sealed in DMs and groups and public in Nearby

Status: Accepted (2026-10-03)

**Context:** after Phases 1 and 2 of ADR 2026-10.nh55 the iPhone moved blobs and showed faces. A photo in a chat
still arrived as an empty bubble, and the iPhone had no way to send one. Android sends photos in all three kinds of
thread (`MeshManager.kt:995-1128`, `AttachmentCrypto.kt`, `AttachmentStore.kt`):

- **Nearby:** the cleartext `ChatContent` carries the body, `attachmentHash` and `attachmentMime`. The blob is the
  photo itself, under its own hash.
- **DMs and groups:** the photo is sealed with AES-256-GCM under a fresh 32-byte key and a 12-byte nonce, with no
  AAD. The blob is `nonce ‖ ciphertext ‖ tag`, and its hash is the SHA-256 of the blob. The sealed `MessageContent`
  carries the hash, the type and the key in padded base64. Beside the envelope, the cleartext repeats only the hash,
  so a carrier blind to the sealed fields can still pull the blob (`MeshManager.kt:1112-1128`).
- **A caption is optional,** and a photo is at most 1280 pixels on its long side, a JPEG at quality 85, and 8 MiB.

**Decision:** the iPhone sends and shows photos the same way, in all three.

- **Sealing** is `AttachmentCrypto` in KnitCrypto. Its key and nonce come from the system's secure generator, not
  the injected one: a seeded generator in a test must never reach a real key (`Digest.swift`). A known answer at a
  fixed key and nonce pins the layout.
- **Sending:**
  - `postToRoom`, `sendDirectMessage` and `sendGroupMessage` take an `OutgoingPhoto`. A message may be a photo and no
    words, and a photo past 8 MiB sends nothing.
  - A room post keeps its photo as it is. A DM or group message keeps the ciphertext, and the key stays in the
    message's row.
  - A message that waits for a key keeps its photo, and is sealed with it once the key pins.
- **The store:** schema v5 adds `attachmentHash`, `attachmentMime`, `attachmentKey`, `attachmentName` and
  `attachmentSize` to `messages`, with a partial index on the hash. A message names its blob, so the sweep keeps the
  blob while the message stays, and every re-offer wants it while its bytes are missing (knit-next ADR 2026-09.ptv8).
- **Receiving:**
  - A hash that is not 64 lowercase hex digits names nothing, so the message carries no photo.
  - The type, the key and a file's name are each cut to 256 UTF-16 units, since a peer's frame bounds nothing on
    its own.
  - In a sealed message, the sealed fields win over the cleartext.
  - The blob is wanted the moment the message lands, and `MeshEvent.attachmentArrived` redraws the thread when its
    bytes do.
- **What a message carries** follows Android's `attachmentKindOf`: a file by its name, a voice message by an
  `audio/` type, a link's card by its type, and a photo for any image or no type at all.
  - A voice message or a file shows a tile with its name and a line saying this build can't open it.
  - A link's card shows nothing the link in the text doesn't already show.
  - A list's or a notification's line for a message with no words says what it carries, as Android's does:
    "📷 Photo", "🎞️ GIF", "🎤 Voice message", or "📎" and the file's name.
- **Preparing a photo** (`ImageCodec.chatPhoto`):
  - ImageIO decodes it upright, at most 1280 pixels on its long side.
  - CoreGraphics draws it into sRGB and encodes it afresh: a JPEG at quality 85, or a PNG when it has transparency.
    Android writes WebP for those, and ImageIO cannot. Nothing of the picked file's metadata is carried over.
  - A GIF of at most 8 MiB and 25 megapixels goes as it is, so Android plays it. Any other GIF goes as a still.
- **The thread:**
  - The composer's button adds a photo while there is nothing to send, and sends otherwise (`SendAction`). The photo
    it holds shows above the field, with a button that takes it out.
  - A photo is 220 points wide in its bubble and at most 260 tall. Until its bytes arrive, a spinner and "Photo
    appears once a phone that has it is in range" hold its place, and after 30 seconds the spinner settles to an
    hourglass. A spinner that never stops keeps the screen redrawing (`WaitingIndicator.kt`, knit-next #72).
  - Bytes that don't decode read "Can't show this photo". That covers a wrong key, a damaged blob, and a type this
    build can't read.
  - A sealed photo is opened in memory each time it is decoded. Only the decoded image is cached, keyed by the hash,
    the size and the key, so two messages that name one blob with different keys never share a decode.
  - A message stays one element for VoiceOver, and its photo opens with a View photo action. A photo made an element
    of its own left the author's name one too, a hit area the accessibility audit fails.
  - Tapping a photo opens the viewer. Its Save adds the bytes as they were sent to Photos, asking only to add
    (`NSPhotoLibraryAddUsageDescription`), since the picker already shares what is picked without a permission.
    `Photos` joins the `seam_images` fence.
- **Copy:** the room's notice says its posts and photos are public. The DM and group encryption sheets say photos
  are sealed like messages, and that the forward-secrecy limit covers them too.
- **The demo:** the `marketing` scene's post by the fire carries a painted photo, and `-demoPhoto` hands Add photo
  the cropper's painted picture.
- **Control lines:** `room`, `dm` and `group-send` take a base64 `photo` and an optional `mime`. A reply names the
  `attachmentHash`, a message line adds `attachmentHash`, `attachmentMime` and `attachmentHeld`, and an `attachment`
  event says when a photo's bytes land. A debug build's bridge also answers `photos`: whether each photo in a thread
  decodes, as `interop.py iphone-photos` checks.

**Consequences / limits:**

- **What a carrier sees:** a DM's or a group's photo blob is ciphertext, but its hash, its size and the fact that a
  message carries a photo travel in the clear. A Nearby photo is as public as the post.
- **A GIF shows its first frame here;** Android animates it.
- **A transparent photo goes as PNG,** which weighs more than Android's WebP.
- **A file or a voice message** from Android is named here and can't be opened.
- **Save keeps the sender's file as it is,** metadata and all. Android strips metadata from what it sends, but a
  modified peer might not.
- **The iPhone doesn't pull the photo of a frame it only carries** until Phase 4 of ADR 2026-10.nh55. Until then, a
  photo it carries for others reaches them from whoever holds it.
- **Guards:**
  - `AttachmentCryptoTests`: the known answer, a wrong key, a bad tag, a short blob, and a fresh key each time.
  - `MessageAttachmentTests` and `SchemaTests` (v5) for the store.
  - `MeshEnginePhotoTests`: sending in all three threads, a pending photo's reseal, receiving, the hash and length
    checks, and the sweep.
  - `ChatPhotoTests` and `CopyTests` for the app's state, the lines, and the plist's words.
  - `MeshControlPhotoTests` for the control lines, and `KnitUITests`' photo walk for the composer, the bubble and the
    viewer at both text sizes. The walk's picked picture stands upright, so the photo it sends grows a hundred points
    as it decodes, and the walk checks that the thread follows it down, its stamp above the composer. The thread rests
    on its bottom edge (`ScrollPosition`), which a growing row keeps it on; scrolled to the newest message's id, it
    left the stamp under the composer.
