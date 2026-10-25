---
id: "2026-10.w6rn"
slug: a-cut-photo-resumes-from
title: "A cut photo resumes from the bytes the iPhone kept"
date: 2026-10-25
topics: [blobs, transport, interop]
---

# ADR 2026-10.w6rn — A cut photo resumes from the bytes the iPhone kept

Status: Accepted (2026-10-25)

This ADR mirrors knit-next ADR 2026-10.wtyc (`e13c2c76f`, #116, inside the pin `5f521cb9`) and its 2026-10-15
amendment (`0e96bb0cf`, #161), which this port takes ahead of the pin. It ports the Kotlin at knit-next `0108d8df1`
where that has moved past wtyc's text. It closes knit-ios #2 and amends ADRs 2026-10.h6zz, eyad, ds45, xwjc, m9uq and
8hek where they said this port never resumes. It changes no vector, schema or capability bit.

**Context:**

- A link that dropped partway through a photo threw away the bytes on both ends. `FileIntake` dropped a cut
  stream at `retire`, and every answer to the next ask streamed from byte 0.
- At the edge of range, or with people walking in and out of it, a large photo could fail forever while both phones
  paid for the airtime. Android's walk on 2026-10-02 lost a Coded link at −96 dBm partway through a photo that needed
  about three minutes.
- Since wtyc, Android keeps a cut prefix and asks with its length. On 2026-10-03 the lab iPhone answered such an ask
  with the whole file, which landed whole. That fallback is safe, but the 34,816 bytes crossed twice (knit-ios #2's
  note).
- Chat photos have crossed since phase 3 (ADR 2026-10.6cas), so the receiver half pays off now as well as the holder
  half.

**Decision:** both halves, rule for rule with the Kotlin, with the differences on purpose listed below.

- **The wire.**
  - A `blobreq`'s `offset` names the bytes the asker kept, and is omitted when it kept nothing.
  - The FILE_HEADER echoes it after `size`, written only when it is greater than 0 and never as `null`.
  - `size` keeps its meaning: the bytes that follow. The whole blob is `offset + size`.
  - An offset that will not decode refuses the file. A size that will not decode costs only the label
    (`LinkFraming.kt:159-209`).
  - A whole-file header is byte-identical to before, so an older build of either platform reads a resumed header as
    its fields and serves or takes whole files as it always has.
- **The holder** (commit `7d4e1ba`).
  - It serves from `offset` when that is in `1...length`, and the whole file otherwise. The range is inclusive, so a
    prefix that is already complete gets a header, no chunk, then END.
  - The serve memo stays keyed by hash and asker, offset left out. A memo that let a lower offset through would hand
    an unsigned asker a way around the flood bound.
  - A parked ask keeps the offset it last named, and is sized by its tail.
  - The feed counts from the offset. `FeedMeter.sized` takes the tail's length. `FeedWindow.report` subtracts the
    offset once as it starts, because the asker's `held` includes its prefix (`FeedWindow.kt:210-226`).
- **The kept prefixes** (`PartialBlobStore`).
  - The rules live in one pure `PartialBlobBook`, which both stores share. `FilePartialBlobStore` keeps the bytes in
    `Database/Partials/`, with the same Data Protection class and backup exclusion as `Blobs/`.
    `MemoryPartialBlobStore` serves knit-peer, the demo and the tests.
  - The bounds are Android's: 8 files, 32 MiB, a 16 KiB floor and an hour after the prefix was kept.
  - **Session scope:** every `Mesh.start` and `Mesh.stop` purges the store, because room photos and avatars cross as
    plaintext.
  - **Immutable once kept:** a longer prefix replaces a kept one by rename, never by a write in place.
  - **Keep-the-longer:** a whole-file stream never costs a longer kept prefix.
  - **Epochs:**
    - a drop, a sweep or a failed read retires a hash's epoch, and a copy built on a retired one is never kept;
    - eviction retires nothing;
    - at most 64 epochs are remembered.
- **The receiver.**
  - `FileIntake` refuses a resumed header, and skips its chunks and END, when any of these hold:
    - it is not an ATTACHMENT;
    - its offset is outside `1...8_454_144`;
    - the key resumed on this link within 45 s (#161);
    - the prefix would not fit the live budget;
    - less is kept than the offset names.
  - A resumed header for a key the engine never asked for is skipped instead, and read from its offset.
  - An explicit `0` is a whole file. The ceiling counts the prefix.
  - A link teardown keeps an attachment's buffer through `cut()`.
  - A replacing header still discards the file it interrupts, and a ceiling abort keeps nothing.
- **The engine.**
  - Every ask carries the kept length (`BlobExchange.kt:1573-1594`; Android's `onNeighborAdded` is gone, so every
    ask goes through `stepBlob`).
  - A stored blob drops its prefix: on arrival, in `stepBlob`'s held branch, and in the 60 s sweep.
  - A spliced file that fails its hash runs `restartFailedSplice`, in this order:
    1. It takes the file off the link first.
    2. It counts `splicesRefused`.
    3. It drops the prefix, and stops here if no live prefix went.
    4. It stops if the blob is arriving or held.
    5. It opens a forced new cycle for the blob from zero, with the failing holder marked failed
       (`BlobExchange.kt:2041-2059`). A fresh want made here has a pull budget of 0, as Kotlin's has.
  - A whole file that fails its hash leaves the prefix alone.
- **Counters and lines.**
  - `status.files` gains `resumedOut` and `resumedIn`, and `status.blobs` gains `splicesRefused`. All three keys are
    additive.
  - The store logs Android's words: `partial <h12> kept <n>B`, `dropped`, `evicted` and `stale, not kept`.

**Differences on purpose:**

- **The prefix read has no `Opening` state.**
  - `FileIntake` reads the prefix inside `header`, on the `Mesh` actor, so no close can race the copy, and the
    `closed` flag has nothing to guard.
  - The cost is one read of up to 8 MiB blocking the actor. #161 bounds it to once per key per link per 45 s.
  - The window is stamped only when the read succeeds, where Kotlin stamps when the prefix opens.
- **The resumed stream is buffered in memory, as every arriving file is here** (ADR 2026-10.h6zz).
  - Its buffer counts against the 16 MiB budget that all links' live files share, and the room is checked before
    the read (`no room for <n>B`). Kept prefixes on disk do not count against it.
- **The TTL runs on the monotonic clock.** The store is purged at every start, so only time within one process
  matters. Android uses the wall clock.
- **The accept gate runs before the room and the read.** A resumed header for a key the engine never asked for is
  skipped, not refused.
- **A short read retires the prefix.** A read that does not return exactly `offset` bytes retires the prefix and
  bumps its epoch. Kotlin retires only when the file will not open, so a truncated prefix there would be named, and
  refused, at every round for an hour.
- **A skipped or refused resumed stream is reported from its offset.**
  - Since AND-7, this port reports a file it skips so an Android sender's window keeps its pace.
  - A report below the sender's offset would be discarded (`FeedWindow.kt:210-215`), so the reading starts at the
    offset. Android reports nothing.
- **Foundation's JSON numbers.** `"offset":600.0` and `6e2` read as 600, where kotlinx refuses both. No build
  writes them, and they name the same bytes. A fraction still refuses the header.
- **A bad record drops the stream; it does not cut it.**
  - The bad records this port has seen came from peer stacks that mangle multi-packet SDUs (`cb440a6`, `04a927b`,
    `af87ba4`), whose corrupt bytes land before the framing desyncs.
  - A kept prefix from such a stream would fail its splice and cost a tail on top of the whole file.
- **Stop drops; a radio state keeps.**
  - `LinkManager.stop()` drops the intakes without cutting, since `Mesh.stop` purges right after.
  - A radio state other than `.on` cuts and keeps, like any other teardown. That covers Bluetooth switched off in
    Settings or Control Centre, `resetting` and a BlueZ power cycle.
- **`Mesh.stop` purges too.** Android purges only at start.
- **No fast plane.** This port has no bulk gate, no `fastOnly` and no plane choice that reads the kept length, so
  those parts of the Kotlin have nothing to mirror.
- **Our own lines.** Our own `link file …` lines and the serve line print the tail's bytes and append
  ` resumed at <offset>`, since ` from <offset>` would put a second "from" on a line that already names the peer
  with one. A refusal reads `refused resumed at <offset>: <reason>`.

The alternatives:

- **Keep prefixes in memory,** as arriving files are. That costs no disk I/O, but a suspended app would hold up to
  48 MiB, the figure ADR h6zz set the 16 MiB budget to avoid. A shared 16 MiB budget for both would make a live
  stream evict a kept prefix under load.
- **Do the holder half alone.** That was knit-ios #2's first recommendation, while only profile photos crossed.
- **Keep prefixes across a restart.** That breaks the session scope that keeps plaintext room photos off the disk
  past their transfer.

**Consequences / limits:**

- **The plaintext window** now spans one resumed transfer, up to an hour or the end of the session, instead of one
  link's. The prefixes take up to 32 MiB of disk.
- **A launch that cannot make `Partials/` keeps prefixes in memory,** at most two and 8 MiB (`AppStorage.partials`),
  rather than failing the launch or holding Android's 32 MiB in RAM.
- **A restoration relaunch purges.** A locked iPhone that walks out of range keeps the prefix in its background wake.
  If iOS then ends Knit, the relaunch's `Mesh.start` purges it. Purging only past-TTL entries at start would keep it;
  this port does not, so the session scope stays simple.
- **The offset tells each asked neighbour how much of the blob the asker holds.** A neighbour learns the asker's
  progress from it, never the content.
- **A failed splice costs one tail and a fresh cycle.** A blind cycle may ask the failing holder again, as Kotlin's
  does. Only a queried round passes it over.
- **The window is per link.** A peer that relinks to reset it pays a link setup per attempt.
- **The trap:** `size` is the tail's, never the whole. A new receive path goes through `FileIntake`, and a new
  teardown path decides whether to `cut()`.
- **Guards:**
  - Wire: `LinkTests` (the offset table, the overflow), and `LinkVectorTests` against `fileHeaderResumed`.
  - The holder: `MeshEngineBlobTests`, `MeshEngineBlobParkTests`, `LinkFileResumeTests`, `FeedWindowTests` and
    `FeedMeterTests`.
  - The store and the intake: `PartialBlobStoreTests` (both kinds), `FileIntakeTests` and `FileIntakeResumeTests`
    (#161 included).
  - The engine: `MeshEngineBlobResumeTests`.
  - The link: `LinkFileSpliceTests`, and the teardown policy's tests.
  - Through the actor: `MeshTests+Files`, against scripted Android-shaped far sides.
  - Both sides: the `LinkPipe` scenarios.
  - Fuzzing: `FuzzLinkRecords`, with the `file-resumed` seed.
  - On hardware: `interop.py iphone-resume`, both ways, against a Pixel on a wtyc build.
- **Device check, passed 2026-10-25** (iPhone 12 on iOS 27.0.1 with `2c28bf4`, the Pixel 9 on knit-next
  2.11.0-alpha.0, the Pixel 8, 7 and 3 capped at no links). Each way, a DM photo of about 690 KB was cut by the
  Pixel's `BLECAP 0` five seconds into the stream.
  - Into the iPhone: it kept 86,017 B, redialed in 13 s, and took a tail of 606,321 B from the Pixel in 53 s, with
    `resumedIn` 1 and `splicesRefused` 0.
  - Out of the iPhone: the Pixel kept 68,623 B, redialed in 9 s, and took a tail of 624,311 B in 56 s, with the
    iPhone's `resumedOut` 1. The Pixel's copy passed its hash check.
  - In both, the prefix and the tail added up to the sealed photo, and no holder sent the whole file again
    (`linux-peer.md`, "What the resume trial showed").
- **Bluetooth off mid-photo, checked by hand the same day.** A radio state that is not `.on` keeps the cut. Bluetooth
  went off on the iPhone 10 s into a photo from the Pixel 9, and the iPhone kept 59,358 B. 14 s after it came back,
  the iPhone took a 130,126 B tail from the Pixel 7, a second holder. iOS kept the connections under the links Knit
  dropped, so the Pixels whose ids sort above the iPhone's refused its redials for 56 s to 14 min
  (knit/knit-next#216). A Settings Stop mid-photo is still owed.
