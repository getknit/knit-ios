---
id: "2026-10.m4ah"
slug: a-picked-picture-is-shrunk
title: "A picked picture is shrunk as Android shrinks it"
date: 2026-10-08
topics: [blobs, app]
---

# ADR 2026-10.m4ah — A picked picture is shrunk as Android shrinks it

Status: Accepted (2026-10-08)

**Context:** the iPhone sent bigger pictures than Android, and lost a generation every time a picture went again.

- **A GIF went whole,** up to 8 MiB, and so did an animated WebP. Android shrinks every GIF into an animated WebP at
  480 pixels, 15 frames a second and quality 70, and sends a WebP sticker as it is only within 512 pixels, 200 frames
  and 1 MiB (knit-next ADR 2026-10.8hmx). A keyboard GIF of several MB crossed Bluetooth that much more slowly. An APNG
  went as a still.
- **A still JPEG was twice Android's size.** Both say quality 85, but ImageIO's scale is not libjpeg's: the tables
  ImageIO writes at 0.85 read as libjpeg's 95. A 1280-pixel photo came to 415 kB where libjpeg's 85 tables give 217 kB
  (measured on macOS 27, 2026-10-08). ImageIO's 0.575 writes tables that read as 85.
- **Every still was decoded and written again,** so a picture saved and sent on lost quality each time and got a new
  hash. Android sends a clean picture as its own bytes with the metadata taken out (knit-next ADR 2026-10.unqn).
- **A transparent photo went as PNG,** where Android writes lossy WebP. ImageIO writes no WebP on iOS or macOS 27 (its
  `CGImageDestinationCopyTypeIdentifiers` lists GIF, HEIC and AVIF, but not WebP). Android before API 31 cannot decode
  AVIF, and plays no HEIC animation.
- **Every refusal said "Knit couldn't open that photo",** a photo too large included.

**Decision:** a picked picture goes out as Android's would, from the same rules with the same numbers. The picture's
own bytes pick the door, whatever the picker called it (`PickedPhoto`, in `Sources/Knit/Images/`).

- **libwebp writes WebP.** It comes in as `SDWebImage/libwebp-Xcode` 1.6.0, upstream libwebp's sources as one C target.
  The new `KnitWebP` target wraps it: `WebPEncoder.still` and `AnimatedWebPWriter`, lossy only, looping forever, fed
  one frame at a time. It is platform-free, so its tests run on Linux.
- **A moving picture keeps its frames:**
  - A GIF becomes an animated WebP at `ChatAnimation`'s 480 pixels, 15 frames a second and quality 70, unless the
    WebP is no smaller, when the GIF goes as it is.
  - An animated WebP within `Sticker`'s bounds goes as itself, stripped by `WebPStrip.animated`. Past them it is
    resampled like a GIF, and the smaller of the two goes.
  - An APNG is always resampled, since Android plays none.
  - `FrameSchedule` (KnitAppCore) samples the clip as `WebpTranscode.sample` does: every 66 ms, more sparsely past
    200 frames so a long clip keeps its length, each sample shown for its share of the time. Unlike Android it merges
    samples of the same source frame into one longer frame, which shows the same picture at every moment for fewer
    bytes.
  - ImageIO draws each frame over the ones before it, as a player shows it, so unlike Android there is no compositor
    of our own. Each frame is read at 480 pixels as it is needed (about 2 ms a frame on the Mac, early or late in a
    300-frame clip).
  - A clip no route takes, or one whose result passes 8 MiB, goes as its first frame, as on Android.
- **A clean still goes as its own bytes.** A JPEG or a still lossy WebP goes stripped when it is within 1280 pixels,
  upright, decodes at the size it declares, and is no sharper than the re-encode: libjpeg quality 87 or less as its
  luminance table reads, or half a byte a pixel for a WebP (`StrippedPicture.isClean`).
  - `JPEGStrip` and `WebPStrip.still` port `ImageStrip`'s allow-lists. A JPEG keeps its tables, one 8-bit frame, the
    scans, a bare JFIF, the ICC profile and the Adobe segment. A WebP keeps `VP8X` with its EXIF and XMP bits cleared,
    `ICCP`, `ALPH` and its one `VP8 ` frame. Anything else goes, and a file either walk does not fully understand
    takes the long way.
  - The app's own JPEG is stripped as it is written: ImageIO adds an EXIF block of its own, the color space and the
    size. So a photo sent, saved and picked again goes as the same bytes, with the same hash.
- **Anything else is written afresh:** upright, at most 1280 pixels, sRGB. An opaque picture becomes a JPEG at ImageIO's
  0.575 (`ChatPhoto.imageIOQuality`). A transparent one becomes a lossy WebP at 85, keeping its alpha.
- **A refusal says why.** `ImageCodec.chatPhoto` answers a `PhotoFailure`. A picture past 100 megapixels, or one that
  nothing brings under 8 MiB, says "That photo is too large to send". While a pick is being made ready the composer
  shows a spinner, and a later pick replaces it.
- **The log says what each pick became,** for example `com.compuserve.gif 960x720, 4 frames, 91971 B -> image/webp,
  9580 B`.

The first alternative a reader reaches for is to stay on ImageIO and shrink a GIF into a smaller GIF. A GIF's
palette and LZW coding make one several times the size of the WebP, and it leaves animated WebP and transparent photos
where they were. Raising the pass-through guard to ImageIO's own 0.85 instead of lowering the write quality would let
libjpeg's q95 camera output through untouched, three to four times our photo's bytes, which Android refused for the
same reason.

**Consequences / limits:**

- **iPhone photos are now about half their old size,** at the quality Android's are. Someone used to the old JPEGs may
  see more compression in fine detail.
- **A dependency in C.** libwebp parses only bytes the app wrote or the user picked. ImageIO still decodes everything
  that arrives from the mesh. 1.6.0 carries the CVE-2023-4863 and CVE-2023-1999 fixes. Its row is in
  `THIRD-PARTY-NOTICES.md`.
- **The 0.575 holds for today's ImageIO.** A new iOS could scale its tables differently, so `ImageIOTests` in
  KnitAppCoreTests pins it on the Mac, which runs the whole suite in CI (`test:macos`).
- **Loop counts are not carried over.** Every clip loops for good, as both apps play every clip.
- **A GIF that goes as it is keeps any text its application extensions carry,** as on Android.
- **Identity reuse (knit-next ADR 2026-10.mptm) is not ported:** a picture already held still goes under a fresh seal.
- **Guards:**
  - `WebPEncoderTests` (Linux) and `ImageIOTests` in KnitWebPTests (the Mac): frames, timing, loop, alpha, and
    ImageIO reading what libwebp writes.
  - `FrameScheduleTests`, `JPEGStripTests` and `WebPStripTests`: the sampling, both allow-lists, the quality estimate,
    `isClean`, idempotence, and every truncation answering `nil`.
  - `ImageIOTests` in KnitAppCoreTests: the ImageIO quality reads as 85, and the app's own JPEG goes as itself when
    picked again.
  - `ChatPhotoTests`: the reasons, the spinner, and the last pick winning.
  - The UI walk `testAGIFPlaysWhereverItShows` sends a 960-pixel GIF, which goes as the WebP it plays.
