---
id: "2026-10.ytvx"
slug: a-moving-photo-plays-in
title: "A moving photo plays in a chat"
date: 2026-10-08
topics: [blobs, app, ui]
---

# ADR 2026-10.ytvx — A moving photo plays in a chat

Status: Accepted (2026-10-08)

**Context:** a GIF in a chat showed only its first frame on the iPhone, as ADR 2026-10.6cas recorded among its
limits. The bytes were already here: every surface decoded through `PhotoDecoder.thumbnail`, which reads frame 0 and
nothing else. What Android sends matters more than GIF itself:

- **knit-next shrinks every GIF into an animated WebP** (480 pixels, 15 frames a second, quality 70;
  `AttachmentStore.kt`), and keeps the GIF only when the WebP comes out larger.
- **It sends a small animated WebP sticker as it is** (at most 512 pixels, 200 frames and 1 MiB), with its metadata
  stripped (`ImageStrip.animatedWebp`, knit-next ADR 2026-10.8hmx).
- **It plays both kinds** in the bubble and the viewer, through Coil 3's `AnimatedImageDecoder`. Coil's repeat count
  defaults to forever and it always sets it, so every clip loops whatever its file says (read from Coil 3.6.3's
  bytecode on 2026-10-08).
- **It labels a message "🎞️ GIF" from its frames,** read once its bytes land and stored on the message (knit-next
  `0b9d19ea`, database v17), not from its type. The iPhone keyed the label on `image/gif`, so a GIF from Android read
  "📷 Photo" here.

So nearly every moving photo from Android arrives as `image/webp`, and the iPhone had to play WebP to play anything.

**Decision:** a GIF, an animated WebP or an APNG plays in the bubble, the viewer and the composer's staged photo.

- **Timing** is `AnimationTiming` in KnitAppCore, tested on Linux. It clamps a delay under 20 ms to 100 ms, as
  browsers and Android's decoder do, and holds one to a minute so a hostile file cannot overflow the cycle. A player
  asks which frame is due at the elapsed time, so a late tick skips frames rather than slowing the clip. Every clip
  loops for good, as on Android.
- **Limits:** past 1,000 frames, or past 2048 × 2048 pixels a frame, a clip shows its first frame. Android sends none
  that large.
- **Reading** is `PhotoDecoder.animation`, behind the checks every photo from the mesh already passes: its type and its
  declared size. It reads each frame's delay from its header (the unclamped one first) and decodes nothing.
- **Playing** is `AnimatedPhotoView`, a UIKit view in SwiftUI:
  - It shows the first frame the cache already decoded at once, so a row keeps its height and the thread stays pinned
    (ADR 2026-10.pkbu).
  - A display link runs only while the view is in a window. An actor that owns the `CGImageSource` decodes each frame
    as it falls due, at the size the view draws, so a playing photo holds two frames, never the clip. A row scrolled
    away drops its decoder; Android likewise keeps no animation in its memory cache.
  - It does not play while Auto-Play Animated Images is off in Settings (`AccessibilitySettings.animatedImagesEnabled`,
    iOS 18). It reads the setting itself, because a thread's cells get no environment from the app (ADR
    2026-10.pkbu).
- **The cache** keeps a moving photo's bytes, not its frames, within half the stills' budget. A bubble asks for the
  frames only when the message says the photo moves, so a still costs nothing more.
- **The label:** schema v11 adds `messages.attachmentAnimated`, read beside the photo's size from the same bytes and
  stored wherever the size is. `PhotoDimensions` carries it. A list's line says GIF when the photo moves; until the
  bytes are read, as for a notification, the type speaks for it. A photo sized under v10 reads as still until the
  launch's read finds it again, since the unsized query also asks for a missing `attachmentAnimated`.
- **Sending:** a picked animated WebP goes as it is, like a GIF, once `AnimatedWebP` has stripped it with Android's
  allow-list: `VP8X` with its EXIF and XMP bits cleared, `ICCP`, `ANIM` and frames that hold only an image. A WebP the
  walk does not fully understand goes as a still. ImageIO can write no WebP, so the iPhone cannot shrink one as Android
  does.
- **Screening is unchanged:** the content filter scores the first frame, as Android's does (ADR 2026-10.rpmq), and a
  hidden photo never starts playing. The maintainer chose that parity on 2026-10-08 over sampling more frames.

The alternative a reader reaches for first is `UIImage.animatedImage(with:duration:)`. It wants every frame decoded up
front at one fixed delay: a 200-frame sticker decoded at the bubble's 660 pixels holds about 350 MB, and uneven delays
need frames repeated. ImageIO's `CGAnimateImageDataWithBlock` decodes full-size frames and leaves pausing off screen to its caller.

**Consequences / limits:**

- **Later frames are not screened,** on either platform. A clip that opens on a harmless frame plays the rest unseen.
- **A GIF picked on the iPhone goes as it is,** up to 8 MiB. Android's would go as a smaller WebP, so the iPhone's
  takes longer to cross the mesh.
- **A picked animated WebP goes whole,** up to 8 MiB, where Android sends a sticker as it is only up to 1 MiB and
  shrinks anything larger.
- (Amended 2026-10-08: both limits are gone. libwebp now writes the WebP ImageIO cannot, so a picked GIF, an animated
  WebP past the sticker's bounds and an APNG are shrunk as Android shrinks them; `AnimatedWebP` is now
  `WebPStrip.animated`; ADR 2026-10.m4ah.)
- **A sent GIF keeps any metadata it carries.** GIF has no EXIF, but an application extension can hold text.
- **A label for a photo sized before v11** says Photo until the launch's read reaches it, 64 photos at a time.
- **Guards:**
  - `AnimationTimingTests`: clamping, wrap-around, a late tick and both limits.
  - `AnimatedWebPTests`: the allow-list, idempotence, and every truncation of a valid file answering `nil`.
  - `PhotoDimensionsTests` and `SchemaTests` (v11) for the store, and `ChatPhotoTests` for the label.
  - The debug bridge's `photos` reply gives each photo's `frames`, and `interop.py iphone-photos --animated` sends
    GIFs both ways and fails unless the iPhone plays both.
