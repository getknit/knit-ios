#if os(Linux)
    @testable import KnitBlueZ
    import KnitCrypto
    import KnitMesh
    import KnitWire
    import Testing

    /// A channel's outbox on a real socket: what waits behind a peer that is slow to read.
    @Suite(.timeLimit(.minutes(1))) struct BlueZOutboxTests {
        @Test func digestsQueuedBehindABackedUpSocketCollapseIntoTheNewest() throws {
            // A mebibyte is far more than the socket holds while the peer is not reading, so both digests are offered
            // while the back-fill still waits, and only the newer is written (knit-next ADR 2026-09.tjfb).
            let rig = try LoopRig(limit: 60_000)
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            let id = try #require(rig.lastAccepted)
            let backfill = [UInt8](repeating: 1, count: 1 << 20)
            rig.post(.write(id, backfill))
            rig.post(.writeDigest(id, [0xD1]))
            rig.post(.writeDigest(id, [0xD2, 0xD2]))
            rig.post(.write(id, [9, 9, 9]))
            rig.turn(3)
            var received: [UInt8] = []
            let expected = backfill.count + 5
            rig.settle("never drained") {
                while let sdu = remote.receive(timeoutMilliseconds: 0) {
                    received += sdu
                }
                return received.count >= expected
            }
            #expect(received.count == expected)
            #expect(Array(received.suffix(5)) == [0xD2, 0xD2, 9, 9, 9])
            #expect(rig.log.all.contains { $0.contains("replaced the one waiting") })
        }

        @Test func aFileRecordIsReportedOnceItsLastByteLeavesTheQueue() throws {
            // The link manager feeds a file's next chunk on this report, so a file never fills the queue ahead of the
            // frames written after it (ADR 2026-10.nh55).
            let rig = try LoopRig(limit: 60_000)
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            let id = try #require(rig.lastAccepted)
            let chunk = [UInt8](repeating: 3, count: 20_000)
            rig.post(.writeFileRecord(id, chunk))
            rig.post(.write(id, [9]))
            var received: [UInt8] = []
            rig.settle("never drained") {
                while let sdu = remote.receive(timeoutMilliseconds: 0) {
                    received += sdu
                }
                return received.count >= chunk.count + 1
            }
            #expect(received == chunk + [9])
            #expect(rig.events.filter { $0 == .wroteFileRecord(id) }.count == 1, "one report for one record, none for the frame")
        }

        /// The mailbox counts a write queued as it is posted, the loop counts each byte the socket takes as written, and a
        /// digest replaced unwritten is given back, so a reader of the level never waits on the loop (ADR 2026-10.f5zs).
        @Test func theLevelCountsBytesQueuedThenWritten() throws {
            let rig = try LoopRig(limit: 60_000)
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            let id = try #require(rig.lastAccepted)
            let backfill = [UInt8](repeating: 1, count: 1 << 20)
            rig.post(.write(id, backfill))
            rig.post(.writeDigest(id, [0xD1]))
            rig.post(.writeDigest(id, [0xD2, 0xD2]))
            rig.post(.writeFileRecord(id, [3, 3, 3]))
            let handed = Int64(backfill.count + 2 + 3)
            #expect(rig.mailbox.levels.level(on: id).queuedBytes == backfill.count + 1 + 2 + 3, "counted as posted")
            rig.turn(3)
            let backedUp = rig.mailbox.levels.level(on: id)
            #expect(backedUp.queuedBytes > 0, "the peer is not reading")
            #expect(Int64(backedUp.queuedBytes) + backedUp.writtenBytes == handed, "the replaced digest is given back")
            var received = 0
            rig.settle("never drained") {
                while let sdu = remote.receive(timeoutMilliseconds: 0) {
                    received += sdu.count
                }
                return Int64(received) >= handed
            }
            #expect(rig.mailbox.levels.level(on: id) == OutboxLevel(queuedBytes: 0, writtenBytes: handed))
            rig.post(.close(id))
            rig.settle { rig.events.last == .closed(id) }
            #expect(rig.mailbox.levels.isEmpty, "a closed channel is no longer counted")
        }

        /// `--stop-reading-after`, a trial's switch: once its time is up the loop polls no channel for input, so what the
        /// peer writes waits in its own socket, and its writes stall.
        @Test func aLoopToldToStopReadingReadsNothingMore() throws {
            let rig = try LoopRig(stopReadingAfter: 0)
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            let id = try #require(rig.lastAccepted)
            remote.send([1, 2, 3])
            rig.turn()
            #expect(rig.received(on: id).isEmpty)
            #expect(rig.log.all.contains("bluez channels are no longer read, for a trial (--stop-reading-after)"))
            rig.post(.write(id, [9]))
            rig.turn(3)
            #expect(remote.receive() == [9], "it still writes")
        }

        // MARK: Sealing (the `link-seal` contract, §4 and §5)

        /// Both halves of one exchange: the loop's sealer and the remote end's opener.
        private static func halves() throws -> (sealer: LinkSealer, opener: LinkOpener) {
            let ours = LinkSeal.Ephemeral()
            let theirs = LinkSeal.Ephemeral()
            let sealing = try LinkSeal.derive(ours, peerShare: theirs.keyShare, role: .responder)
            let opening = try LinkSeal.derive(theirs, peerShare: ours.keyShare, role: .dialer)
            return (sealing.sealer, opening.opener)
        }

        /// The remote end's reading of `bytes`: the outer tags, and the inner records of the frames opened in order.
        private static func open(_ bytes: [UInt8], with opener: LinkOpener) throws -> (outer: [LinkRecord.Tag], inner: [LinkRecord]) {
            var outer = LinkRecordReader()
            outer.append(bytes)
            var tags: [LinkRecord.Tag] = []
            var inner = LinkRecordReader()
            while let record = try outer.next() {
                tags.append(record.tag)
                if record.tag == .sealed {
                    inner.append(try #require(opener.open(sealedPayload: record.payload), "frame \(tags.count) opens in order"))
                }
            }
            var records: [LinkRecord] = []
            while let record = try inner.next() {
                records.append(record)
            }
            return (tags, records)
        }

        private static func record(_ tag: LinkRecord.Tag, _ fill: UInt8, count: Int) -> [UInt8] {
            LinkRecord(tag, payload: [UInt8](repeating: fill, count: count)).encoded ?? []
        }

        @Test func aDigestReplacedBehindABackedUpSealedSocketStillOpensInOrder() throws {
            let (sealer, opener) = try Self.halves()
            let rig = try LoopRig(limit: 60_000)
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            let id = try #require(rig.lastAccepted)
            let share = LinkRecord(.keyShare, payload: [UInt8](repeating: 0x5E, count: 32)).encoded ?? []
            rig.post(.writeKeyShare(id, share, sealer))
            let backfill = Self.record(.frame, 1, count: 400_000)
            rig.post(.write(id, backfill))
            rig.post(.writeDigest(id, Self.record(.digest, 0xD1, count: 100)))
            rig.post(.writeDigest(id, Self.record(.digest, 0xD2, count: 60)))
            let live = Self.record(.frame, 9, count: 3)
            rig.post(.write(id, live))
            rig.turn(3)
            let handed = Int64(share.count + backfill.count + LinkRecord.headerBytes + 60 + live.count)
            var received: [UInt8] = []
            rig.settle("never drained") {
                while let sdu = remote.receive(timeoutMilliseconds: 0) {
                    received += sdu
                }
                return rig.mailbox.levels.level(on: id).writtenBytes >= handed
            }
            while let sdu = remote.receive(timeoutMilliseconds: 100) {
                received += sdu
            }
            #expect(rig.mailbox.levels.level(on: id) == OutboxLevel(queuedBytes: 0, writtenBytes: handed), "plaintext, and all of it")
            let read = try Self.open(received, with: opener)
            #expect(read.outer.first == .keyShare)
            #expect(read.outer.dropFirst().allSatisfy { $0 == .sealed }, "nothing but frames after the KEY_SHARE")
            #expect(read.inner.map(\.tag) == [.frame, .digest, .frame])
            #expect(read.inner[1].payload.count == 60, "the newer digest, in the older one's place")
            #expect(rig.log.all.contains { $0.contains("replaced the one waiting") })
        }

        @Test func aHelloQueuedBetweenOurKeyShareAndTheSealerLeavesSealed() throws {
            let (sealer, opener) = try Self.halves()
            let rig = try LoopRig(limit: 60_000)
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            let id = try #require(rig.lastAccepted)
            let share = LinkRecord(.keyShare, payload: [UInt8](repeating: 0x5E, count: 32)).encoded ?? []
            rig.post(.writeKeyShare(id, share, nil))
            rig.post(.write(id, Self.record(.hello, 0x48, count: 40)))
            rig.post(.writeDigest(id, Self.record(.digest, 0xD1, count: 30)))
            rig.turn(3)
            #expect(remote.receive() == share, "the KEY_SHARE alone")
            #expect(remote.receive(timeoutMilliseconds: 100) == nil, "the HELLO and the digest held for the sealer")
            rig.post(.seal(id, sealer))
            rig.turn(3)
            var received: [UInt8] = []
            rig.settle("never drained") {
                while let sdu = remote.receive(timeoutMilliseconds: 0) {
                    received += sdu
                }
                return (try? Self.open(received, with: opener).inner.count) == 2
            }
            var outer = LinkRecordReader()
            outer.append(received)
            var tags: [LinkRecord.Tag] = []
            while let record = try outer.next() {
                tags.append(record.tag)
            }
            #expect(!tags.isEmpty && tags.allSatisfy { $0 == .sealed })
        }

        @Test func theBitFlipArmsOnLinkUpAndBreaksTheNextFrame() throws {
            let (sealer, opener) = try Self.halves()
            let rig = try LoopRig(limit: 60_000, flipsSealedBit: true)
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            let id = try #require(rig.lastAccepted)
            let share = LinkRecord(.keyShare, payload: [UInt8](repeating: 0x5E, count: 32)).encoded ?? []
            rig.post(.writeKeyShare(id, share, sealer))
            rig.post(.write(id, Self.record(.hello, 0x48, count: 40)))
            rig.turn(3)
            #expect(remote.receive() == share)
            var hello = LinkRecordReader()
            hello.append(try #require(remote.receive()))
            #expect(opener.open(sealedPayload: try #require(try hello.next()).payload) != nil, "before link-up, honest")
            rig.post(.linkUp(id))
            rig.post(.write(id, Self.record(.frame, 1, count: 10)))
            rig.turn(3)
            var frame = LinkRecordReader()
            frame.append(try #require(remote.receive()))
            let flipped = try #require(try frame.next())
            #expect(flipped.tag == .sealed, "still a frame")
            #expect(opener.open(sealedPayload: flipped.payload) == nil, "and it fails to open")
            #expect(rig.log.all.contains { $0.contains("will flip a bit in its next sealed frame") })
        }
    }
#endif
