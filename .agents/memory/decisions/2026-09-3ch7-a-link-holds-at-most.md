---
id: "2026-09.3ch7"
slug: a-link-holds-at-most
title: "a link holds at most one digest waiting, in an outbox both radios share"
date: 2026-09-27
topics: [mesh, transport, interop]
---

# ADR 2026-09.3ch7 — a link holds at most one digest waiting, in an outbox both radios share

Status: Accepted (2026-09-27)

**Context:** on 2026-09-27 a post the Pixel 3 sent once custody matched took 6.5 minutes to reach the Linux
peer on `hci1`. It was not lost. It waited behind about ten 20 KB digests that the Pixel had queued during a
9-minute back-fill, one per 60 s tick, each stale by the time it went out (`.agents/context/linux-peer.md`,
"Why the frames were late"). This port's writers had the same queue. `LinkManager` cut every record into 8 KiB
writes, and `L2CAPLink` kept what waited as one run of bytes, so a queued digest could not even be found
again. knit-next fixed its side in ADR 2026-09.tjfb (`FramedLink.kt`, commit `11b91371`): a link holds at most
one digest not yet written, and a newer one takes its place in the queue. That run's post and DM then arrived
in 133 s and 124 s, down from 393 s and 383 s. It changes no bytes on the wire, and each side can adopt it
alone.

**Decision:** `LinkOutbox`, in `KnitMesh`, is the queue of one link. `L2CAPLink` and BlueZ's channels each
hold one, so the rule is written once, and the Linux tests cover the copy the iPhone runs too (ADR
2026-09.6es2 keeps the adapters thin). `Radio.writeDigest(_:to:)` hands the radio the whole DIGEST record. The
radio queues it with `offerDigest`, which puts the newer record where the older one stands when one waits, and
the radio cuts it into its own writes. Its default writes the digest like any record, which is right for a
radio with no queue of its own: the fakes and `DemoRadio`. A digest counts as waiting until its first byte is
written. Android empties its slot a little earlier, when the writer reaches it. Waiting for the first byte
keeps a digest stuck behind a full socket replaceable, and a digest partly written is never rewritten.

Replacing the digest in `LinkManager` would look simpler, but `LinkManager` cannot see the radio's queue, so
it cannot tell whether the last digest has gone out.

**Consequences / limits:**

- **The slot reaches only as far as this queue.** Bytes handed to CoreBluetooth's stream or to the BlueZ
  socket go out as they were. On the Pixel 3 the socket held at least 120 KB, several minutes of `hci1`, and
  six digests that were already there still went out 33 to 37 s apart after the fix. Closing that would take
  shallow writes to the socket, paced like files, or a smaller digest record, which is a wire question.
  Neither is built.
- **An idle link is unchanged.** Each digest is written as it comes, at the same cadence and with the same
  bytes.
- **A digest still rides ahead of what was queued after it.** A newer one keeps the older one's place, so a
  digest is never pushed behind frames by a later tick.
- **Guards.** `LinkOutboxTests` ports `FramedLinkTest`'s digest cases. `BlueZOutboxTests` collapses two
  digests behind a socket that is backed up. `LinkAdmissionTests`'
  `aDigestReachesTheRadioWholeSoItCanReplaceOneStillWaiting` holds `LinkManager` to one whole record.

**Amended 2026-10-03, for files (ADR 2026-10.h6zz):** the outbox holds a third kind of entry, a FILE record
(`appendFileRecord`). Like bytes it waits its turn, and unlike a digest nothing takes its place. `wrote(_:)` answers
whether the bytes just written finished one, and the radio reports `RadioEvent.wroteFileRecord` when they did.
That report is how the link manager keeps at most one chunk of a file in the queue, so frames written meanwhile go
out between chunks. `LinkOutboxTests` and `BlueZOutboxTests` pin it.
