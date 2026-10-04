---
id: "2026-10.h6zz"
slug: file-records-cross-a-link
title: "FILE records cross a link one chunk at a time, each behind the radio's report of the last"
date: 2026-10-03
topics: [ble, transport, interop]
---

# ADR 2026-10.h6zz — FILE records cross a link one chunk at a time, each behind the radio's report of the last

Status: Accepted (2026-10-03)

**Context:** profile photos and photos in chats travel as FILE records on the link (ADR 2026-10.nh55). Android writes
a file as follows (`FramedLink.streamFile`, `FramedLink.kt:321-359`):

- a `FILE_HEADER` (compact kotlinx JSON: `kind`, `key`, `mime`), then `FILE_CHUNK`s of 16 KiB, then an empty
  `FILE_END`;
- one file at a time per link;
- each chunk paced at 28 KiB/s on a 1M or 2M link;
- frames and the waiting digest drained between chunks.

Its writer blocks on the socket, so a slow link holds back the file and never the frames behind it. Here a radio's
queue never blocks: each radio keeps a first-in, first-out `LinkOutbox` per channel (ADR 2026-09.3ch7) that grows
as long as it is fed. Fed a whole file, it would hold every later frame until the file had gone. On `hci1`, which
carries 0.5 to 2.5 KB/s, a photo of a few hundred KiB would hold a DM for minutes. BlueZ closes a channel that queues
past 4 MiB, so a large file would end the link.

The receiving rules come from the same file (`FramedLink.kt:402-520`):

- a header mid-file drops the partial file;
- a chunk or an END with no header is ignored;
- a file past 8,454,144 bytes is dropped, and the link kept;
- a key that is not 64 lowercase hex is rejected.

**Decision:** the link manager streams each file itself, and the radio says when to send more.

- **The radio seam.** `Radio.writeFileRecord(_:to:)` hands the radio one whole record. The radio queues it in its
  `LinkOutbox` as a FILE record, and when the record's last byte leaves the queue it reports
  `RadioEvent.wroteFileRecord`. KnitBLE reports from `L2CAPLink.drain`, and BlueZ from its `flush`.
- **The gate.** The next chunk goes once the last is reported out, and no sooner than its own share of a second at
  the pace: 16 KiB at 28 KiB/s is 571 ms. Our queue therefore holds at most one chunk of a file, and frames
  written meanwhile go out between chunks, as Android's do.
  - The pace is spaced per chunk, never averaged over the file, so an app resumed after a suspension does not burst
    to catch up.
  - A radio that does not report (`reportsFileWrites` false: the test radios, the demo radio) is fed at the pace
    alone.
- **The rest of sending.** `sendFile` writes the header and the first chunk at once, since the timers run the links
  before the engine. A file whose bytes cannot be read ends early, and the receiver's hash check drops it. FILE
  records never ring a doorbell, as on Android.
- **Receiving.** A `FileIntake` per channel, in `KnitWire` so that `FuzzLinkRecords` drives it, applies Android's
  rules. Two of its limits are this port's own:
  - **Keys.** A malformed key is refused at its header, not at its END. The file is dropped either way, but its bytes
    are never held.
  - **Size.** A peer's own AVATAR push is kept up to 1 MiB. An ATTACHMENT is kept only when the engine asked for its
    hash (`MeshTransport.acceptFiles`), up to 8,454,144 bytes. Partial files on every link together stay under
    16 MiB, so six links cannot hold 48 MiB in a suspended app.

The alternative a reader reaches for first is a synchronous read of the radio's queue depth (`pendingBytes`). It
would block the `Mesh` actor on the radio's thread (ADR 2026-09.gq84), or read a counter that lags the writes still
crossing to that thread. It would also need a timer to poll a full queue. The report is one event per chunk, and
nothing waits on it.

**Consequences / limits:**

- **The gate reaches only our own queue.** The socket's buffer, or the stream's, still sits between a frame and the
  air, as it does for a digest (ADR 2026-09.3ch7).
- **No Coded PHY.** An iPhone cannot tell when a link runs on the Coded PHY. Android feeds such a link at 1 KiB/s in
  2 KiB chunks (#114). This port keeps 28 KiB/s, and the gate bounds the damage to one chunk ahead of the frames.
- **No resume.** A file cut off by a dying link is dropped on both ends, and the next request fetches it whole.
- **Guards:**
  - `FileIntakeTests` for Android's receiving rules, and `LinkTests.fileHeaderBytesArePinned` for the header.
  - `LinkFileTests` for the stream, the pace, the gate, frames between chunks, one file at a time, and teardown.
  - `LinkOutboxTests` and `BlueZOutboxTests` for the report, and `L2CAPLinkTests` for KnitBLE's report on the Mac.
  - `LinkDoorbellTests.fileRecordsDoNotRing`.
  - `FuzzLinkRecords`, seeded with whole files.

**Amended 2026-10-04, for the header's size (knit-next ADR 2026-10.y9qh):** every header this port writes declares
`size`, the length of the stream that follows, after `mime`, as Android's `streamFile` has since `e4ff84b3`. An
Android phone then fills a ring as our photo arrives, where it showed only the bytes in so far. The size is the
sender's claim: nothing here sizes a buffer, caps a stream or judges a stall by it. `FileIntake` still counts the
bytes against its own limits. The reader is as lenient as Android's `decodeFileHeader`: a size that is not an integer
reads as none, and the file still lands. A header with no size is the three keys a build before the field wrote. No capability bit: a reader that predates the key skips it. The iPhone does not yet draw its own ring
from the size it reads (`.agents/memory/roadmap.md`). Guards:

- `LinkVectorTests.theFileHeaderRecordMatchesKotlinxByteForByte`, against knit-next's `fileHeader` vector;
- `LinkTests.aSizeThatWillNotDecodeCostsTheLabelNotTheFile`, Android's bad sizes;
- `LinkFileTests.aFileStreamsAsAHeaderChunksAndAnEndAtTheBlePace`, for the size a served file declares.
