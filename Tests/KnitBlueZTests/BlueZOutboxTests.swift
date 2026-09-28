#if os(Linux)
    @testable import KnitBlueZ
    import KnitMesh
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
    }
#endif
