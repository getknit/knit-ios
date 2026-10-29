---
id: "2026-10.f5zs"
slug: a-neighbour-s-digests-and
title: "a neighbour's digests and asks are metered and its link queues bounded"
date: 2026-10-26
topics: [mesh, transport, custody, security]
---

# ADR 2026-10.f5zs — a neighbour's digests and asks are metered and its link queues bounded

Status: Accepted (2026-10-26)

**Context:** knit-next's malicious-fork review of 2026-10-26 (`eccabcd72`, finding H1) found that one neighbour can
make a phone serve its whole custody for an empty DIGEST of about 15 bytes, as often as it likes. This port had the same
path (knit-ios #19, checked against `9a67484`):

- **No meter.** `LinkManager.dispatch` turned every DIGEST into an event. `CustodySync.missing` then read and decoded
  every live row through `liveFrames`, up to the 1,000 custody holds, and served each one the digest left out.
- **A bound that could be flushed.** `LinkCrossings`, which lets a frame cross a link once per 10 minutes, kept what we
  wrote and what the link gave us in one 1,024-entry set per link. Inbound stamps went in before any router check, so
  1,025 junk frames evicted every outbound stamp. A relink cleared them all.
- **No queue bound.** Every round went into `LinkOutbox`, and so did up to 128 keyreq answers of profiles with no byte
  cap (knit-ios #22). The outbox had no bound. `L2CAPLink` waited on `hasSpaceAvailable` forever, and nothing watched a
  live link's writes. knit-peer closed a channel past 4 MiB queued (`BlueZLoop.maximumQueuedBytes`); the iPhone did not.
- **No inbound bound.** `BLERadio`'s `AsyncStream` kept the default unbounded buffer, and `L2CAPLink` read everything
  available into it, ahead of every honest link's records, behind one serial consumer.

A fork that stops reading grows Knit's memory until jetsam ends it. knit-next has not fixed H1 at `eccabcd72`: Android
meters no digest, caps no round, and its link writer is `Channel.UNLIMITED`. One rule here is Android's.
`LinkSilence.kt` at the pin (`e63f15f4`) closes a link whose write makes no progress for `WRITE_STALL_MS = 120_000`
(`:35-37`, `:212`, `:389`), and exempts a `CAP_DOORBELL` link (`:39`), because iOS suspends Knit with its link up.

**Decision:** six local rules, none of them on the wire. Each side can adopt them alone, and Android needs no change.

1. **A peer's digests are metered.** `LinkManager.dispatch` admits a DIGEST through `IngressBudget<NodeId>`, a burst of
   2 and then one per 30 s, and drops the rest, counting them in `refusedDigests`. It keys by the HELLO's node id, so a
   relink under the same id gets no fresh burst. Android and knit-peer send one at link-up and one every 60 s
   (`MeshManager.kt:3025-3048`), so an honest peer is never refused, and a relink within 30 s still finds a token.
2. **Inbound stamps cannot evict outbound ones.** Each link keeps what we wrote apart from what it gave us, 1,024
   entries each for 10 minutes, both cleared with the link. `send` skips a frame found in either. Junk now costs only
   its own link: at worst we echo a frame back to the fork that sent it. The fix first proposed was to stamp an inbound
   frame only once `Router.admit` says `.new`. It would not have held, because `admit` runs before `verify`, so junk
   minted with fresh canonical ids is `.new`. It would also have needed a seam from the engine back to the link manager.
3. **A link's queue is bounded, and a stalled write ends it.** `LinkOutbox.maximumQueuedBytes` (4 MiB, moved from
   `BlueZLoop`) is the one bound both radios read. Past it, `L2CAPLink` closes with `ble chN stopped reading`, as BlueZ
   does. Each radio counts a link's queued and written bytes at its entry points (`Radio.outboxLevel(on:)`), and
   `LinkManager` checks them every 30 s. A link with bytes queued and none written for 120 s of Knit's running time ends
   with `link chN write stalled for <ms> ms`, and backs off nobody, the way Android's `closeSilent` does. A slow link
   whose bytes keep moving never trips it. Time Knit spends suspended does not count: `SystemClock` runs on a
   `ContinuousClock` and a suspended Knit writes nothing, so a late check, a ring and coming to the front each restart
   the count. A `CAP_DOORBELL` peer that never advertised a digest cue, which is how an iPhone looks, is exempt, since a
   suspended iPhone reads nothing by design.
4. **A reply round is capped, and reads ids first.** `CustodySync.missing` picks from `CustodyStore.liveIndex`, which
   decodes nothing: profiles first, then newest received first, minus the digest's ids and whatever already crossed the
   link either way. It loads only what it picks, up to 200 frames or 256 KiB as encoded. Keys sent ahead count toward
   the bytes but not the 200. The first pick always goes, and the round stops at the first pick that would pass the
   budget, so a large profile goes ahead of its sender's chat instead of being skipped. A group frame is loaded to read
   its roster, and one whose roster lacks the peer takes no slot. While the link still holds half a round (128 KiB)
   unwritten, the newest digest waits in one slot per link. It is looked at every 5 s and answered once the queue
   falls, so a slow link holds about one round. Android serves every omitted frame at once (`ForwardSync.kt:136-163`);
   the cap is this port's rule alone. Convergence holds because each 60 s digest answers the next slice.
5. **Keyreq answers are budgeted per peer.** `KeyExchange` serves from a byte bucket per link peer, 256 KiB refilling at
   8 KiB/s with 64 peers remembered. A request's answers and the wanters served when a pin lands draw on the same
   bucket. It is keyed by the HELLO's node id, never the keyreq's signer, so a fork replaying requests it captured from
   other signers still draws on one bucket per link. It runs on debt, so a profile larger than the burst still goes
   once. A profile the link already carried inside the crossing window is neither sent nor charged. A skipped id is
   neither wanted nor asked on. The asker asks again on its next frame dropped for want of that key past its 30 s
   cooldown, at link-up, or at its heal: every 15 minutes on Android (`MeshManager.kt:1320`), the 60 s re-offer here.
6. **A channel's inbound bytes are bounded by a credit.** A radio stops reading a channel once 256 KiB it delivered
   wait unprocessed, and `Mesh` reports what it consumed (`Radio.consumed(_:on:)`). The radio resumes below half and
   restarts its own read, since the stream sends no new `hasBytesAvailable` until something reads. L2CAP's credits then
   push back on the sender. Nothing is dropped while the link lives, where Android's inbound flow drops past 256 frames
   without a count. A hang-up is read through to its end. An error close on BlueZ drops what the socket still held,
   because the kernel returns the error first. Whether iOS keeps a paused channel's bytes when the far end hangs up is
   for the device trial to show. Custody's next digest repairs either loss.

**Consequences / limits:**

- **A newcomer fills in slices.** Facing a full custody it takes about five exchanges, newest first, where Android's
  answer is one. The harness's `custody-converges` waits allow 420 s for it. On 2026-10-26 a `LinkPipe` newcomer owed
  601 of 1,000 frames converged in four digests.
- **A held digest on a locked iPhone waits for a wake.** The 5 s look runs only while Knit does, and writing a digest
  rings no doorbell. A round held at suspension is answered at the next wake, which the peer's next frame brings at the
  latest.
- **A fork that rotates node ids** pays a dial and a HELLO for each burst of two rounds. A fork claiming an honest
  peer's id can empty both of that peer's buckets, which delays its back-fill by 30 to 60 s and its keys until a re-ask
  after the refill.
- **An honest relink can lose one round.** The 60 s re-offer is one round for every link, not timed from each link-up.
  So a peer can send its link-up digest, then the round's a few seconds later, then relink within 30 s. That third
  digest is refused, and its back-fill waits for the next round, 60 s at most while Knit runs. A locked iPhone waits
  longer: digests never ring the doorbell, so the round that makes up for it is read only at Knit's next wake.
- **A burst keeps its oldest digests.** A suspended iPhone takes a link's buffered records all at once when it wakes,
  so several 60 s digests from one peer arrive together. The first two are answered and the rest refused, and the round
  serves against the oldest picture of the peer's custody until its next digest. `refusedDigests` counts these bursts
  as well as a looping peer, so on its own it is no evidence of abuse.
- **A `CAP_DOORBELL` fork that stops reading** escapes the stall close, and only the 4 MiB bound ends it. The exemption
  reads the advert's digest cue, since a GATT payload always carries it zeroed. A doorbell peer whose custody is empty
  advertises a zero cue through service data too, and keeps the exemption.
- **Rules 3 and 4 ship together.** Before the round cap, a back-fill toward a locked iPhone, which the stall close
  exempts, could pass 4 MiB between its wakes. The link would close, relink and queue the same round again.
- **Six links at 4 MiB** can still hold 24 MiB queued in a backgrounded Knit. Nothing caps the links together yet.
- **#22's profile cap** is its own issue. Until it lands, rule 5's debt lets one oversized profile go per refill.
- **Guards:**
  - rule 1: `LinkDigestBudgetTests`;
  - rule 2: `LinkCrossingsTests` and `LinkCrossingFloodTests`;
  - rule 3: `LinkOutboxTests`, `LinkWriteStallTests`, `WriteStallWatchTests`, `BlueZOutboxTests` and
    `BlueZChannelTests`;
  - rule 4: `CustodyIndexTests` (both stores), `CustodySyncRoundTests` and `MeshEngineDigestRoundTests`, with
    `LinkPipeCustodyRoundTests` and `LinkPipeFeedWindowRoundTests` running two engines;
  - rule 5: `KeyExchangeTests`, `MeshEngineKeyBudgetTests` and `LinkPipeKeyBudgetTests`;
  - rule 6: `InboxCreditsTests` and `BlueZChannelTests`;
  - on the Mac: `L2CAPLinkTests`, for the bound, the level and the credit over bound streams.

**Amended 2026-10-29, for knit-next #176 and #235 (ADR 2026-10.metv):** rule 4's group exception is gone. A round no
longer loads a group frame to read its roster, and a frame whose roster lacks the peer now takes a slot like any
other, as knit-next ADR 2026-10.hr9f serves it. Busy groups the peer is not in can now fill its first rounds, and an
older frame it is owed follows at a later digest. The budget, the order and the crossings skip are unchanged.
`CustodySyncRoundTests.aDMBehindFourHundredGroupFramesThePeerIsNotInFollowsThemOnceEach` replaces the test that
pinned the exception.

**Amended 2026-11-01, for the link proof (ADR 2026-11.hpmt):** the meters keyed by the HELLO's node id (rule 1's
digests, rule 5's keyreq bucket) are keyed by a proven id on a link where both sides carry `CAP_LINK_PROOF`. There, a
node claiming an honest peer's id can no longer empty that peer's buckets: its claim is refused or fails its proof
before anything is metered. Toward a peer that can't prove itself, the consequence above still holds.
