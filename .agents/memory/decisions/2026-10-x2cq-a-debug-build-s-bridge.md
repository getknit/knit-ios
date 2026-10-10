---
id: "2026-10.x2cq"
slug: a-debug-build-s-bridge
title: "a debug build's bridge records the screen with ReplayKit"
date: 2026-10-09
topics: [interop, testing, app]
---

# ADR 2026-10.x2cq — a debug build's bridge records the screen with ReplayKit

Status: Accepted (2026-10-09)

**Context:** knit-next's demo film (`.private/scripts/demo-film.sh` there) films the phones in hand with a camera
and records each phone's screen, then lines every recording up with the footage by a clap in their audio. Android
phones record over adb with their microphone. The iPhone needed Control Center's Screen Recording, started by hand
on camera and copied off over USB, and the workstation cannot go to the set. The bridge already reaches the phone
over Wi-Fi (ADR 2026-10.dz8d), but had no way to record.

**Decision:** a debug build's bridge answers `record-start`, `record-stop`, `record-fetch`, `record-delete` and
`record-status`, recording with ReplayKit's in-app recorder.

- **`startRecording`, then `stopRecording(withOutput:)`.** ReplayKit keeps the movie itself and writes it at the
  stop, so a 15-minute take holds no frames in Knit's memory and needs no `AVAssetWriter` of ours. The writer route
  (`startCapture`) would hand us every sample buffer to encode, and would bring `AVFoundation` into the bridge, which
  `seam_codes` keeps in `Sources/Knit/Codes/`.
- **The logic is platform-free.** `RecordCommand` and the `ScreenRecording` actor live in `KnitControl` behind a
  `ScreenCapture` protocol, so the state machine, the consent wait, the chunking and the replies run in Linux tests.
  `ReplayCapture` in `Sources/Knit/Debug/` is the only ReplayKit code.
- **A file is fetched in base64 chunks of at most 1 MiB.** That is about 1.4 MB on one reply line. The listener now
  reads a connection's next line only once its last reply has gone to the network, so a client pulling a few hundred
  megabytes never has more than one chunk queued on the phone.
- **Leaving the front ends a take and keeps it.** At `didEnterBackground`, the bridge stops the recording inside a
  background task and keeps the file, and `record-stop` after the return answers with it, `"endedBy":"background"`.
  The scene going inactive, which Control Center and a banner also cause, leaves the take running.
- **A start waits up to two minutes for consent.** iOS asks the person holding the phone at a start. If nobody
  answers, `record-start` refuses with `timeout`. If the start succeeds after that, it is stopped and its file thrown
  away, so the phone is never recording while the script believes it is off.
- **The microphone key is debug-only.** iOS ends an app that turns on the microphone without
  `NSMicrophoneUsageDescription`. The key comes from `App/project.yml`'s Debug config, not `App/Info.plist`, and
  `check.sh release` fails a store build that has it.

**Consequences / limits:**

- **In-app recording sees only Knit.** The home screen, other apps, Control Center and notification banners are not
  in the movie. A demo that leaves Knit ends the take there.
- **Nobody can allow a take ahead of time.** Apple documents that the question comes back once eight minutes have
  passed since the last start, and developers report it at every start since iOS 18.5. Someone has to tap Allow at
  each take's `record-start`.
- **A take does not outlive the app.** The file sits in the app's temporary directory. A relaunch forgets it, and
  the next start clears the directory. If iOS stops a recording itself, it keeps nothing, and the next `record-stop`
  answers `lost`.
- **Knit itself plays and records no sound,** so the recorder's microphone has nothing to share.
- **Guards.** `RecordCommandTests` covers parsing, the start, the stop and its repeat, chunked fetches with their
  SHA-256, a take that ended at the background, a start that replaces a take, refusals, a lost take, and the consent
  timeout with a late start. `check.sh release` checks that a store build has no bridge (its queue label) and no
  microphone key. `ReplayCapture` and the background stop are checked on the iPhone only.
