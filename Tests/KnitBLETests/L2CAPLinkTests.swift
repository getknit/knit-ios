#if canImport(CoreBluetooth)
    import Foundation
    @testable import KnitBLE
    import KnitMesh
    import Testing

    /// ``L2CAPLink`` over bound stream pairs in place of a CoreBluetooth channel: what it writes, what it reads, and how
    /// it ends. The far end runs on a ``StreamThread`` of its own, as the other phone would.
    @Suite(.timeLimit(.minutes(1))) struct L2CAPLinkTests {
        @Test func writesArriveWholeAndInOrder() async throws {
            let rig = try LinkRig()
            rig.link.write([1, 2, 3])
            rig.link.write([4, 5])
            rig.link.write([6])
            #expect(try await rig.far.read(6) == [1, 2, 3, 4, 5, 6])
        }

        @Test func aLongWriteGoesOutInCutsOfAtMost8KiB() async throws {
            let rig = try LinkRig()
            let bytes = (0..<20_000).map { UInt8(truncatingIfNeeded: $0) }
            rig.link.write(bytes)
            #expect(try await rig.far.read(bytes.count) == bytes)
            let cuts = rig.log.all.compactMap(LinkRig.written)
            #expect(cuts.reduce(0, +) == bytes.count)
            #expect(cuts.allSatisfy { $0 <= 8192 })
            #expect(cuts.contains(8192), "a write the stream has room for goes out in whole cuts")
        }

        @Test func whatTheFarEndWritesReachesReceivedInOrder() async throws {
            let rig = try LinkRig()
            rig.far.write([9, 8, 7])
            rig.far.write([6, 5])
            #expect(try await rig.received.take(5) == [9, 8, 7, 6, 5])
        }

        /// A digest that waits behind bytes the far end has not read yet is replaced by a newer one, which goes out in its
        /// place; one already on the stream goes out whole (ADR 2026-09.3ch7).
        @Test func aNewerDigestTakesTheWaitingOnesPlace() async throws {
            let rig = try LinkRig(bufferSize: 1024, farReads: false)
            let backfill = [UInt8](repeating: 0xAA, count: 4096)
            rig.link.write(backfill)
            rig.link.writeDigest([0xD1, 0xD1])
            rig.link.writeDigest([0xD2, 0xD2, 0xD2])
            rig.link.write([0xEE])
            await rig.settled()
            rig.far.startReading()
            #expect(try await rig.far.read(backfill.count + 4) == backfill + [0xD2, 0xD2, 0xD2, 0xEE])
            #expect(rig.log.all.contains { $0.contains("digest of 3 bytes replaced the one waiting") })
        }

        /// Each FILE record's last byte out of the queue is reported once, which feeds a file's next chunk; a frame's
        /// bytes report nothing (ADR 2026-10.nh55).
        @Test func aFileRecordIsReportedOnceItsLastByteIsOut() async throws {
            let rig = try LinkRig(bufferSize: 1024, farReads: false)
            let chunk = [UInt8](repeating: 0xCC, count: 4096)
            rig.link.writeFileRecord(chunk)
            rig.link.write([0xEE])
            await rig.settled()
            #expect(rig.fileWrites.times == 0, "still queued behind a far end that is not reading")
            rig.far.startReading()
            #expect(try await rig.far.read(chunk.count + 1) == chunk + [0xEE])
            try await rig.fileWrites.wait()
            await rig.settled()
            #expect(rig.fileWrites.times == 1)
        }

        @Test func theFarEndClosingEndsTheLinkOnce() async throws {
            let rig = try LinkRig()
            rig.far.close()
            try await rig.ends.wait()
            rig.link.close()
            rig.link.write([1])
            await rig.settled()
            #expect(rig.ends.times == 1)
        }

        @Test func closingDropsWhatWaitsAndNeverReportsAnEnd() async throws {
            let rig = try LinkRig(bufferSize: 1024, farReads: false)
            rig.link.write([UInt8](repeating: 1, count: 4096))
            await rig.settled()
            rig.link.close()
            rig.link.write([2])
            await rig.settled()
            rig.far.startReading()
            // Whatever the stream held before the close may still arrive; nothing written after it does.
            let arrived = await rig.far.drainAvailable()
            #expect(arrived.count <= 1024)
            #expect(!arrived.contains(2))
            #expect(rig.ends.times == 0)
        }

        /// A far end that stops reading fills the stream, and the link closes itself once more than the bound waits,
        /// reporting its end once, as BlueZ's channels do (ADR 2026-10.f5zs).
        @Test func aFarEndThatStopsReadingIsCutOnceItsQueuePassesTheBound() async throws {
            let rig = try LinkRig(bufferSize: 1024, farReads: false)
            let slice = [UInt8](repeating: 0x5A, count: 8192)
            let slices = LinkOutbox.maximumQueuedBytes / slice.count
            for _ in 0..<slices {
                rig.send(slice)
            }
            await rig.settled()
            #expect(rig.ends.times == 0, "at the bound, with the stream's buffer full, nothing is over it yet")
            rig.send(slice)
            try await rig.ends.wait()
            rig.send(slice)
            rig.link.writeDigest([0xD1])
            await rig.settled()
            #expect(rig.ends.times == 1)
            #expect(rig.log.all.contains("ble ch1 stopped reading; closing it"))
        }

        /// The level counts what the radio handed over as queued until the stream takes it, then as written, and gives
        /// back a digest replaced unwritten, so queued and written add up to what was handed over (ADR 2026-10.f5zs).
        @Test func theLevelCountsBytesQueuedThenWritten() async throws {
            let rig = try LinkRig(bufferSize: 1024, farReads: false)
            let backfill = [UInt8](repeating: 0xAA, count: 4096)
            rig.send(backfill)
            rig.send([0xD1, 0xD1], by: L2CAPLink.writeDigest)
            rig.send([0xD2, 0xD2, 0xD2], by: L2CAPLink.writeDigest)
            rig.send([UInt8](repeating: 0xCC, count: 2048), by: L2CAPLink.writeFileRecord)
            await rig.settled()
            let handed = backfill.count + 3 + 2048
            let waiting = rig.level
            #expect(waiting.queuedBytes > 0, "the far end is not reading")
            #expect(waiting.writtenBytes > 0, "the stream's own buffer took some")
            #expect(Int64(waiting.queuedBytes) + waiting.writtenBytes == Int64(handed), "the replaced digest is given back")
            rig.far.startReading()
            _ = try await rig.far.read(handed)
            try await rig.fileWrites.wait()
            await rig.settled()
            #expect(rig.level == OutboxLevel(queuedBytes: 0, writtenBytes: Int64(handed)))
        }

        /// A far end that floods the link is read up to the channel's credit and no further: the rest waits in the stream,
        /// which says `hasBytesAvailable` again only after a read. Once the consumer brings the count below half, the link
        /// reads the rest of its own accord, with nothing lost (ADR 2026-10.f5zs, rule 6).
        @Test func aFloodPausesAtTheCreditAndAResumeReadsTheRestUnasked() async throws {
            let rig = try LinkRig()
            let flood = LinkRig.pattern(LinkRig.floodBytes)
            rig.far.writeAll(flood)
            try await rig.log.wait { $0.hasPrefix("ble ch1 reads paused: ") }
            await rig.settled()
            let held = rig.received.all.count
            #expect(held >= InboxCredits.limitBytes)
            #expect(held < InboxCredits.limitBytes + 65_536, "the credit is asked before every gulp")
            #expect(rig.log.all.contains("ble ch1 reads paused: \(held) bytes unprocessed"))
            #expect(rig.credits.unprocessed(on: ChannelID(1)) == held)
            await rig.far.settled()
            await rig.settled()
            #expect(rig.received.all.count == held, "nothing more is read while the link waits")

            rig.consume(InboxCredits.limitBytes / 4)
            await rig.settled()
            #expect(rig.received.all.count == held, "above half, the link still waits")
            rig.consume(held - InboxCredits.limitBytes / 4)
            #expect(try await rig.received.take(flood.count) == flood, "the rest, in order, with no stream event to ask")
            #expect(rig.log.all.contains("ble ch1 reads resumed: 0 bytes unprocessed"))
        }

        /// The far end closing while the link's reads are paused still ends the link, once, after everything it sent.
        @Test func theFarEndClosingWhileReadsArePausedEndsTheLinkOnce() async throws {
            let rig = try LinkRig()
            let flood = LinkRig.pattern(LinkRig.floodBytes)
            rig.far.writeAll(flood)
            try await rig.log.wait { $0.hasPrefix("ble ch1 reads paused: ") }
            await rig.settled()
            let held = rig.received.all.count
            rig.far.close()
            let sent = await rig.far.accepted()
            #expect(sent > held, "the far end ended with bytes still waiting in the stream")
            await rig.settled()
            rig.consume(held)
            #expect(try await rig.received.take(sent) == Array(flood.prefix(sent)), "nothing sent before the end is lost")
            try await rig.ends.wait()
            await rig.settled()
            #expect(rig.ends.times == 1)
            #expect(rig.credits.isEmpty, "the credit dies with the link")
        }

        @Test func nothingIsWrittenUntilTheStreamsAreOpen() async throws {
            let rig = try LinkRig(opens: false)
            rig.link.write([1, 2])
            await rig.settled()
            #expect(rig.log.all.compactMap(LinkRig.written).isEmpty)
            rig.link.open()
            rig.link.write([3])
            #expect(try await rig.far.read(3) == [1, 2, 3])
        }
    }
#endif
