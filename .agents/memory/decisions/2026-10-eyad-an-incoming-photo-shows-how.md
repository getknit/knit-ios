---
id: "2026-10.eyad"
slug: an-incoming-photo-shows-how
title: "An incoming photo shows how far it has got"
date: 2026-10-24
topics: [blobs, app]
---

# ADR 2026-10.eyad — An incoming photo shows how far it has got

Status: Accepted (2026-10-24)

Mirrors knit-next ADR 2026-10.y9qh (`e4ff84b3a`) on the receiving side, with its #138 landing amendment read against
this port's own store. No wire, vector, schema or capability change. Closes the roadmap's "the iPhone's own ring for a
photo arriving" (ADR 2026-10.h6zz's amendment of 2026-10-04 named it owed).

**Context:** while a photo streamed in, its bubble showed Knit's stitches, then an hourglass after 30 s, over "Photo
appears once a phone that has it is in range". That line was wrong while bytes were arriving, and a photo crossing a
DM in 45 s (480 KB at about 10.5 KB/s, `roadmap.md`) looked the same as one nobody was sending. Every header from this
port since 2026-10-04, and from Android since y9qh, declares `FileHeader.size`: the length of the blob as stored, the
ciphertext for a sealed photo, under the hash the message names. `FileIntake.Reading` already held the key, the bytes
in and that size for each link. Nothing carried it past `LinkManager`.

**Decision:** the bubble draws a ring from a sample of the link's own count, taken while the thread waits on a photo.

- **The read** (`LinkManager.arrivingFiles`, `Mesh.arrivingFiles`). For each link whose intake is keeping a file, its
  reading, keyed by hash, the copy furthest along when two links stream one blob (Android's `furthestByKey`). A
  skipped stream is someone else's file and never shows. It is computed on each read and stores nothing, so a cut
  link, an abandoned file or a replacing header drops the entry because the intake dropped it (knit-next ADR
  2026-09.4tx5's rule). It is not on `MeshTransport`: the engine never reads it.
- **No landed files.** Android's read adds the files past their END that its store has not taken (`LandingFiles`,
  #138), because its store runs off the reader's thread. Here `fileEnd` and `MeshEngine.receiveFile` run in one actor
  turn, and `receiveFile`'s `defer` takes the file before the turn ends, so no reader outside the actor ever sees one.
  `landingFiles` stays a set.
- **The sample** (`AppSession.sampleArrivals`, `PhotoArrivals`). The thread loops on it while `ChatModel.awaitsPhotos`,
  Android's `awaitedHashes` gate: every 500 ms while a file streams in and every 2 s while none does
  (`ArrivalTicker`). It moves no `revision`, as `typing` doesn't, and the cells read `PhotoArrivals` from the
  environment, out of their `Row` value, so a moving ring reconfigures no cell. Behind another app it reads nothing.
- **The gap the store leaves.** The photo is stored before its `attachmentArrived` reaches the session and redraws the
  row, and a sample in between finds it gone. A hash that leaves the readings with its blob held therefore stays whole
  for one more sample, by when the event has redrawn the row, so the bubble never steps back to its waiting line. One
  sample only (blobs-reviewer, 2026-10-24): a profile photo raises no event, and an event that lands while a read is on
  its way would be undone by it, so a longer hold would keep the hash for good. One that leaves with its blob missing
  was cut off, and drops at once.
- **The bubble** (`ArrivalRing`, `WaitingPhoto`). A thin ring fills from twelve o'clock over a 30% track, as the App
  Store and Messages draw a download, with "84 kB of 205 kB" under it in Files' byte format. A sender that declared no
  size, or overran the size it declared, gets a still arrow and "84 kB received". The ring eases to each sample in
  0.4 s and then holds still, and steps under Reduce Motion, so a stalled stream lets the screen settle (knit-next
  #72). The box keeps the waiting line's height throughout. The caption joins the message's one VoiceOver element.
- **The demo:** `-demoScene photo-arriving` stages both kinds through `DemoMesh.Staging`, for
  `testAPhotoOnItsWayShowsHowFarItHasGot`.

The alternative a reader reaches for first is a `MeshEvent` per chunk. A link raises no event per chunk now. One would
wake the main actor and the debug bridge's tap at the chunk rate, up to about fourteen a second on a fast link, for a
ring that only needs two samples a second, and only while a photo is on screen. The second is carrying a size in the
message, as `attachmentSize` does from 1,000,000 bytes (ADR 2026-10.6cas's amendment of 2026-10-24). That size is the
plaintext's and is rarely set, while the link already carries the exact one.

**Consequences / limits:**

- **The total is the peer's claim.** It labels the ring and bounds nothing; the intake keeps its own ceiling.
- **A cut transfer starts over at 0** when the next holder streams it, because this port never resumes one (knit-next
  ADR 2026-10.wtyc, knit-ios #2). The ring resets with it. *Amended 2026-10-25 by ADR 2026-10.w6rn:* a resumed
  stream's reading starts at its offset and totals `offset + size`, so the ring picks up where the cut left it.
  Between the cut and the resume the bubble shows its waiting line.
- **Only the last hop shows.** A relay fetches the whole photo before serving it, so the ring fills only once a
  neighbour streams to us. Until then the stitches and the hourglass stand, as on Android.
- **A suspended iPhone reads nothing** until a doorbell wakes it, and FILE records never ring (ADR 2026-09.khjj). Back
  in front, the next sample corrects the ring in one jump.
- **Voice messages and files** keep their tiles. This build opens neither; Android rings them too.
- **The trap:** reading the bytes from a retained intake. The receive buffer stays cheap only while the intake holds
  its sole reference (`FileIntake.chunk`), so a stored copy would make every later chunk copy up to 8 MiB on the mesh's
  actor. `footprint.arrivingFiles` stays a count, since `interop.py` and `soak.py` take the largest value of every
  footprint key.
- **Guards:**
  - `LinkFileArrivalTests` for the read: kept only, no size, the ceiling, a cut, an abandon past its limit, a replacing
    header, the furthest copy, and its keys inside `arrivingFileKeys` at every step;
  - `MeshTests.aPhotoStreamingInShowsHowFarItHasGotUntilItIsStoredInTheSameTurn` through the actor;
  - `PhotoArrivalTests` for the share, the captions, the pace, the inactive read, the held and cut gap, the one-sample hold, the thread's
    gate and the demo scene;
  - `KnitUITests.testAPhotoOnItsWayShowsHowFarItHasGot` on the Simulator, audited.
- **Device check, passed 2026-10-24** (iPhone 12 on iOS 27.0.1, Kai's Pixel 8 sending three DM photos of 425 kB,
  screenshots about 0.8 s apart). The ring filled from 8 kB to 423 kB, the file landed at 22:17:43.65, and the next
  frame showed the photo with no frame of the stitches between. Sent to the background by `devicectl` at 45% for
  30 s, the bubble held its last reading for about 2.1 s after coming back (the idle pause), then showed the true
  count. Stopped through the bridge's `stop` at 140 kB, the bubble showed the waiting line in the first frame after
  `link down`. iOS 27 writes the sizes as "kB".
