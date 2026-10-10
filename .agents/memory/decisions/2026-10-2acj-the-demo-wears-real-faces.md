---
id: "2026-10.2acj"
slug: the-demo-wears-real-faces
title: "The demo wears real faces and photos that only a debug build bundles"
date: 2026-10-09
topics: [app, store, ui, testing]
---

# ADR 2026-10.2acj — The demo wears real faces and photos that only a debug build bundles

Status: Accepted (2026-10-09)

**Context:** the `marketing` scene is what the store's screenshots, its video and the creative assets show. Its faces
and photos were painted at launch, a sky and a few shapes, so that no photograph shipped in the app (ADR 2026-10.sepc).
On the store's images they read as clip art: Dani's face was a mountain, and the post by the fire a triangle on a
gradient. Three of its eight people wore initials. Its DMs and its group were also short: Sam's DM held three lines and
the group three, so their shots were mostly empty screen. Knit for Android's demo wears AI-generated faces from UI
Faces and Unsplash photos, kept in a source set only its debug build compiles.

**Decision:** the demo wears real-looking faces and photographs, which only a debug build bundles.

- **The pictures:** `App/DemoMedia/`, committed, since the Mac builds tracked files only. Eight faces from UI Faces,
  the same as Android's hiking cast where the person is the same, so both listings show one cast. Six photos from
  Unsplash, Android's summit among them. `.private/scripts/fetch-demo-media.sh` pins each source and fetches them again,
  and `THIRD-PARTY-NOTICES.md` lists them.
- **Debug only:** `App/project.yml` copies the folder whole into the app, and Release's `EXCLUDED_SOURCE_FILE_NAMES`
  leaves it out. `check_release_app` fails a build that holds `DemoMedia`, and `check_xcode_app` fails a debug build
  that lacks any of its pictures.
- **The types:** `DemoPortrait` is now a person's face, one case per member of the cast, and `DemoSnapshot` a photo of
  a place, which a message carries and `-demoPhoto` picks. Each raw value names its file. `DemoPictures` replaces the
  painter: it reads a file and crops it to fill the size it is wanted at, about its middle.
- **The cast:** everyone in `marketing` wears a face, and each DM and the group runs longer than a screen, with a photo
  in each. Their earlier lines come first in the scene's list, so they move no later line, and the chat list keeps its
  order and its previews.

The alternative a reader reaches for first is to keep painting, with more detail. No painter in a few hundred lines
draws a face anyone takes for a person. The other is to keep the pictures in `.private/`, out of the public
repository, as the captions are. The UI tests and the screenshot walk run on the Mac, which receives tracked files
only, so the pictures would need a second way there.

**Consequences / limits:**

- **The repository holds pictures under other licenses.** They are not GPL, and the notices say so. UI Faces allows
  commercial use of its AI-generated images, but its licenses page also says it "is not recommended for use in public,
  live projects", and says nothing about redistribution. Android ships the same faces the same way. Replace them if
  that changes.
- **The edge cases keep no photos,** so the walks that audit them measure the same rows as before.
- **No initials in the marketing scene.** The tint and initial still show in `edge-cases`, and under `-demoSensitive`
  for a hidden photo.
- **The guards:** `PhotoTests` (every face, and the photo in the room, both DMs and the group), `check_release_app`,
  `check_xcode_app`, and `NoticesSyncTests` for the packages beside them.
