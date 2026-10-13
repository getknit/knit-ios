---
id: "2026-10.g3k9"
slug: the-store-s-video-is
title: "The store's video is a scripted demo scene filmed in the Simulator"
date: 2026-10-08
topics: [testing, store, ui]
---

# ADR 2026-10.g3k9 — The store's video is a scripted demo scene filmed in the Simulator

Status: Accepted (2026-10-08)

**Context:** the App Store takes up to three app previews per device size: 15 to 30 seconds of the app moving, which
the screenshot walk (ADR 2026-10.5u39) cannot give. knit-next films its trailer from a debug-only director
(`DemoDirector.kt`) that plays a scripted Nearby room into the app's own stores, and types the user's part into the
real composer (`DemoComposer`), while `adb screenrecord` runs. The iPhone's demo had no way to change after launch:
`DemoSeed` writes a scene once, and `DemoMesh` reports a fixed set of linked peers.

**Decision:** a scripted scene, `-demoScene trailer`, played by a director in the app, everyone's part and the user's,
while a UI test opens the room and the Simulator films. The film is mostly one shot of the Nearby room, then cuts to a
DM and a group, as knit-next's is.

- **The scene:** the marketing cast with the room cut to its opening, Sam alone linked, and a `script` of cues:
  `type` (the user types and sends), `heard` (that post shows delivered), `link`, `post` and `react`.
- **The director:** `DemoDirector` in `KnitAppCore`, which `DemoMesh` starts on its first `start()` and which waits
  for its curtain, raised when the room first comes on screen. The mesh starts as the app launches, before its first
  frame, and a script that started there had played half its beats before anyone could see them. Each beat goes the
  engine's way: written to the stores, then announced as the `MeshEvent` the engine would send (`received`,
  `attachmentArrived`, `reacted`, `delivered`, `neighborsChanged`). The session screens and counts them as it does a
  real peer's.
- **The user's part:** a `type` beat fills the room's composer a key at a time, 65 ms a key as knit-next's does,
  through the director's `composer` stream, then sends. The room's `ChatModel` follows that stream from `appear()`
  while `AppSession.director` is set, which only `AppEnvironment.demo` does. The field never takes focus, so no
  keyboard rises, and Send is the model's own. The script then waits until `DemoMesh` sees the post before anyone
  answers it.
- **The gate:** `scripts/check.sh trailer` films "Knit shots" with `simctl io recordVideo` while `KnitTrailer`, a UI
  test in the `KnitShots` target, opens the room and waits for the script's posts. Each appearance (dark unless
  `KNIT_SHOT_MODES` says otherwise) lands in `.build-xcode/trailer/<mode>_trailer.mov`. The test keeps the host's
  time at four marks (room, answer, photo, end) as an attachment, and the gate writes them into
  `<mode>_trailer.marks` as seconds after a change it makes itself: it records the home screen in the other
  appearance, waits, and switches to the take's. Both clocks are the Mac's, since a Simulator's processes run on it.
  The builder reads the switch as the recording's second frame, and starts the film where the room settles.
- **What stays private:** pulling the take, and cutting it into the App Store preview and the trailer masters, in
  `.private/scripts/`, as in knit-next.

The first takes had the UI test type the user's posts, to keep the director out of `ChatModel`. XCTest types only
into a focused field, and focus raised the software keyboard over half the room, where Knit has no gesture to put it
away; typed a key at a time, it also took over half a second a key. The composer seam costs one optional property on
`AppSession` and one branch in `ChatModel.appear()`, both nil and untaken outside the demo, and a release build cannot
reach the demo (ADR 2026-10.8cy5). knit-next also cuts its take at a `START` measured by eye, again after any change to
start-up and per device; the marks replace that.

**Consequences / limits:**

- **"Recording started" is not the recording's zero.** On a still home screen simctl wrote its first frame about 4 s
  after saying so (2026-10-08), and marks counted from the message cut the film 4 s late. A recording writes a frame
  only when the screen changes, so the switch the gate makes is its second frame, and a take whose second frame is not
  a fraction of a second in has no zero; the builder refuses it.
- **The room has no peer count** on the iPhone, unlike Android's, so the people linking (`link`) show only as "in
  range" in a DM. The iPhone shows typing since ADR 2026-10.29z9, but no beat has a peer type, so nobody is seen typing
  but the user.
- **The composer follows one director at a time.** Its `composer` stream has one reader; a room that closes and opens
  again follows nothing more. The film opens the room once.
- **It checks nothing.** No CI job runs it. The script is checked on Linux by
  `theTrailersDirectorPlaysItsScriptThroughTheRoom`, through a real mesh, session and room, and `KnitTrailer` fails
  when a post it waits for never appears.
- **The guards:** `DemoDirectorTests` (`onlyAScriptedSceneHasADirector` and the playback test), `check.sh xcode`,
  which builds the `KnitShots` scheme and so `KnitTrailer`, and `check.sh release`, which fails if the demo reaches a
  release build (ADR 2026-10.8cy5). `check.sh shots` runs the `KnitShots` class alone, so it never films.
