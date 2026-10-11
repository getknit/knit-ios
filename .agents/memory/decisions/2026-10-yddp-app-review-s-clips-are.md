---
id: "2026-10.yddp"
slug: app-review-s-clips-are
title: "App Review's clips are scripted scenes filmed like the store's video"
date: 2026-10-10
topics: [testing, store, moderation]
---

# ADR 2026-10.yddp — App Review's clips are scripted scenes filmed like the store's video

Status: Accepted (2026-10-10)

**Context:** App Review checks guideline 1.2 against what it can see: a way to report, a way to block, and what each
does. A reviewer with one iPhone and no second Knit nearby sees an empty room, with nobody to report or block. The
review notes describe both features, and a video shows them. Two ways to film one were already in place. The
bridge's ReplayKit recorder (ADR 2026-10.x2cq) films the iPhone, but someone has to tap Allow, the film is 888 by
1920 at a varying frame rate, and the phone has to be free. The store's video (ADR 2026-10.g3k9) films the Simulator
from a scripted scene, with nobody at the Mac. Its director, though, only plays the room on a clock. It could not wait
for the user to do something, and it wrote every post to the stores, so a block would have hidden a post only by the
row filter, never at the gate where the engine stops it.

**Decision:** each clip is a scripted demo scene, `-demoScene <clip>`, and a test in `KnitClips` (in the `KnitShots`
target), filmed by `scripts/check.sh clips` the way `trailer` films `KnitTrailer`. The first is `block`.

- **The scene:** the trailer's room and people, plus a stranger with no name, so the room shows their alias. The
  script posts the stranger's line, waits for a block, has the stranger post again, then has Sam post.
- **A beat that waits for the user:** `blocks(Slot)` holds the script until the block store holds that person.
  `DemoMesh.block` tells the director after the mesh has stored the block. A report blocks through the same
  `AppSession.block`, so a block made from the menu, a profile or a request releases the beat.
- **A blocked person's post stops at the gate.** The director checks the block store before it stores a post, as the
  first lines of `MeshEngine.handleChat` do, so nothing is stored or announced. The film shows what a real block does,
  not a row hidden by `ChatModel`'s filter.
- **The test plays the user at a person's pace:** a long press and Report and Email Knit, the Simulator's no-mail
  alert naming the address, Copy Address, then Settings, Blocked people, the profile and Unblock. It holds still for a
  few seconds after each change, for someone watching to read it. It keeps marks on the host's clock, in an
  attachment named `<clip>_marks`.
- **The gate:** `film_take` in `check.sh` now films any test, and both `trailer` and `clips` call it. `KNIT_CLIPS`
  names the clips, each the test's name less `test`. Each clip and appearance lands in `.build-xcode/clips/` as
  `<mode>_<clip>.mov` and `.marks`.
- **The second clip, `filter`,** shows content filtering (ADR 2026-10.rpmq, ADR 2026-10.e4kz) with nothing explicit
  or abusive on screen or in the repository. The demo's filters flag only what the scene names.
  - A scene lists `flaggedWords` and `flaggedPhotos`. `DemoTextClassifier` flags those words by exact match, and
    `DemoPhotoClassifier` flags those photos byte for byte.
  - The demo environment makes each flagged photo once and hands the same bytes to the classifier, the seed and the
    director, so the classifier sees exactly the bytes it was given.
  - The stranger's words are a mild insult, and a tap in the clip shows them. Their photo is an ordinary one standing
    in, which the clip never shows: a hidden photo draws only an icon.
  - The test then types a flagged reply into the room, which refuses it, and ends on Settings' Content filtering
    switch. The captions say the demo flags these posts on purpose.
  - The other choice was a real false positive for the photo model, so that the real model ran. That needs the Core
    ML model in the demo and a search for a picture it misreads, and a model update could undo the find.
- **What stays private:** pulling the takes, and cutting them at real speed with a caption beside the screen for each
  step, in `.private/scripts/`, as for the trailer.

The rejected option was to film the iPhone with ReplayKit and drive it from `KnitDeviceTests`. That shows real
hardware, but it waits on an Allow tap and on a free phone, and a second Knit would still have to play the stranger.
The block feature is all on this phone (ADR 2026-10.5wgg), so the Simulator shows the same code doing the same thing.
The two-phone video in the review notes is still filmed on real phones, because only hardware shows the mesh.

**Consequences / limits:**

- **The review notes have to say these clips come from the Simulator, with sample people.**
- **The director's gate is a copy of the engine's, not the engine's.** It checks node ids only, not device tags. If
  the engine's gate changes, this one does not follow it. `theBlockClipWaitsForTheReportAndTheBlockStopsTheStranger`
  pins the behaviour the film shows.
- **The stranger's words are rude, not abusive,** in both clips. The filter clip's verdicts are the scene's, not
  the models'. The models' own scores are checked against Android's by the parity scripts (ADR 2026-10.rpmq, ADR
  2026-10.e4kz), not here.
- **The zero is the first frame after the gate's still wait,** not always the second frame, as ADR 2026-10.g3k9 had
  it. On 2026-10-10 a take of the block clip opened on a home screen still drawing its icons: seven frames in its
  first 0.2 s, then the switch at 6.29 s. The builders now read the first frame after a gap of 2 s or more.
- **A mark taken on seeing a change runs late.** XCUITest sees a change only after the app goes idle and a snapshot
  is taken: a chat list was on screen 2 s before its mark, and an alert 8 s before its mark on a slower run. The
  recorder writes a frame only when the screen changes, so `build-clips.sh` moves each such mark back to the last
  frame at or before it. Marks taken after a hold and before a tap (`leaving`, `typing`, `end`) stay as they are.
- **It checks nothing.** No CI job runs `clips`. `check.sh xcode` builds the `KnitShots` scheme, so `KnitClips`
  compiles, and a clip's test fails when a step it waits for never comes.
- **The guards:**
  - `DemoDirectorTests`, through a real mesh and session: `onlyAScriptedSceneHasADirector`, the block clip's playback
    test, and the filter clip's, which checks that only the named words and bytes are flagged.
  - `check.sh release`, which fails if the demo reaches a store build (ADR 2026-10.8cy5).
