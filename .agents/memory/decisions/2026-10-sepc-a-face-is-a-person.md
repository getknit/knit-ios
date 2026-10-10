---
id: "2026-10.sepc"
slug: a-face-is-a-person
title: "A face is a person's photo or their node id's tint, and a profile photo is cropped and saved on the phone"
date: 2026-10-03
topics: [app, blobs, ui]
---

# ADR 2026-10.sepc — A face is a person's photo or their node id's tint, and a profile photo is cropped and saved on the phone

Status: Accepted (2026-10-03)

**Context:** after Phase 1 of ADR 2026-10.nh55 the iPhone pushed, fetched and adopted profile photos, and drew none of
them. Every row wore the same gray SF Symbol, and the user had no way to set a photo of their own.

Knit for Android draws a face wherever a person appears:

- **A photo,** when its bytes are held.
- **Otherwise an initial on a tint.** The initial is the first grapheme of the name, upper-cased. The tint is one of 12
  disc and letter pairs, chosen by `floorMod(String.hashCode(nodeId), 12)`, so a person is the same hue on every
  phone that knows them (knit-next ADR 2026-09.j8c7).
- **A group without a photo** shows up to four of its other members' faces, ordered by node id, or a people glyph on
  the group's own tint when fewer than two others remain (knit-next ADR 2026-09.zapp).

Its own photo comes from the system picker and a circle cropper, saved as a 256-pixel JPEG at quality 90
(`AvatarStore.kt`, `AvatarCropDialog.kt`).

**Decision:** the iPhone draws the same faces, and edits its photo the same way, except for when the photo is
published.

- **`Face`** lives in KnitAppCore: what a face stands for, the key its tint comes from, its initial, the hash of its
  photo, and a group's members.
  - View state carries hashes only. The app decodes a photo when it draws one, so `Cached` view state stays small.
  - `Directory.face(for:)` and `face(of:)` build every face from one snapshot.
- **The tint and the initial** port Android's rules. `AvatarTint` holds both palettes verbatim, which is what Android
  shows unless Material You is on, and its slot is Java's `String.hashCode` over UTF-16, floor-modded.
- **Where faces show, at Android's sizes:**

  | Surface | Size |
  | --- | --- |
  | Chat list rows | 52 pt |
  | A thread's title | 36 pt |
  | Others' messages in the room and groups | 40 pt |
  | Requests | 44 pt |
  | Group members, and New message's contacts | 48 pt |
  | Settings' profile row | 56 pt |
  | Both profiles, group info, and onboarding's name page | 96 pt |

  - A face beside a name is hidden from VoiceOver, since the name says who.
  - At the accessibility text sizes the rows drop their faces, as the chat list already dropped its glyph.
  - Someone's photo on their profile is a View photo button that opens it full screen.
- **Our own photo:**
  1. PhotosPicker picks it. The picker runs outside Knit, so it needs no permission.
  2. ImageIO decodes it upright, at most 1280 pixels on its long side.
  3. The cropper pans and zooms it under a circle at 0.8 of the shorter side, from 1 to 5 times. VoiceOver zooms it by
     swiping up and down. It is pushed rather than presented, since the picker may still be closing as the photo
     decodes, and SwiftUI drops a presentation that starts while another is going.
  4. Choose keeps a 256-pixel JPEG at quality 90, with none of the picked photo's metadata. Run on the Mac over a
     GPS-tagged picture, the codec's JPEG kept only the color space and the pixel size.
  5. Save publishes the photo and then the fields, each only if it changed.

  Android publishes a photo the moment its crop is confirmed. Its Save then stayed dimmed beside a photo that had
  already gone out, and it had to add a snackbar to say so (knit-next #26). Here the photo waits for Save with
  everything else, and the cropper's button is Choose rather than Save, since it publishes nothing.
- **A photo from someone else is untrusted bytes.**
  - ImageIO decodes it only as a bounded thumbnail.
  - It must be JPEG, PNG, GIF, WebP or HEIC, and declare at most 25 megapixels, since a small file can declare a huge
    image and ImageIO decodes some types whole before it scales them.
  - Anything else, and a hash whose bytes went missing, draws as the initial.
  - Decoded faces are kept by hash and by size, rounded up to a power of two, within about 16 MB.
- **The seam:** PhotosUI, ImageIO, UniformTypeIdentifiers and CoreTransferable are imported only under
  `Sources/Knit/Images/` (`seam_images` in `.swiftlint.yml`). The codec reaches KnitAppCore as `ImageCodec`, as the
  camera reaches it as `CameraAccess`.
- **The demo:**
  - The `marketing` scene gives five of its eight people photos. Knit paints them at launch, so no photograph ships in
    the app. The other three keep their initials. Superseded on 2026-10-09: everyone wears an AI-generated face that
    only a debug build bundles (ADR 2026-10.2acj).
  - `-demoPhoto` makes Choose photo hand the cropper a painted picture, since the system picker is out of a UI test's
    reach. A debug build honours it in a live launch too, for `KnitDeviceTests`.
  - The `edge-cases` scene is unchanged, so the walks that audit it measure the same rows as before.

**Consequences / limits:**

- **The own profile's face sits in its section's header,** apart from the rows of Choose photo and Remove photo. With
  the face and a centered Choose photo in one row, the audit's contrast check failed the screen whenever the face was a
  monogram, with a report it could name no element for: the accent label read against the disc's pastel is about
  4.2:1. A photo, or a label set to the leading edge, as on someone's profile and group info, passed. Putting a label
  back under the disc in one row brings the failure back.
- **A tint is a cue, never a fingerprint.** One person in twelve shares a hue with another. The safety number is what
  tells people apart.
- **No "changed their photo" line.** Android writes one into a DM thread when a peer's photo changes, and a line for a
  rename. This port has neither yet. A later change ports both, as status notices.
- **Out of scope:** faces in notifications, taking a photo with the camera, and group photos. Group photos are Phase 4
  of ADR 2026-10.nh55. Until then a group shows its members or its glyph.
- **The photo is public**, as the name is. The profile says so under the photo.
- **The guards:**
  - `FaceTests`: Android's tint slot vectors, both palettes' 4.5:1 contrast and their walk round the wheel, the
    initials, the cluster's pick and cells, and `AvatarCropTest`'s crops.
  - `PhotoTests`: the face on every surface, our photo chosen, cropped, saved and removed, and the demo's photos.
  - `CopyCatalogTests`, `seam_images`, and `KnitUITests`' photo walk, which audits the profile, the cropper and the
    viewer at both text sizes.
  - `KnitDeviceTests`' `PhotoTests`, which chooses, crops and saves a photo on the iPhone, live.
