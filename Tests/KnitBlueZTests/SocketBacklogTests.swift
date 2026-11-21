#if os(Linux)
    import Glibc
    @testable import KnitBlueZ
    import KnitMesh
    import KnitSync
    import Testing

    /// What a channel's socket holds below the link, counted as unwritten (the `custody-carry-policy` contract, §2): the
    /// kernel's two answers read as `bt_sock_ioctl` is written, every answer it cannot give counted as nothing, and the
    /// level adding it. No test here opens an L2CAP socket, so the reading of the kernel stays unverified until a run on
    /// `hci1`.
    @Suite(.timeLimit(.minutes(1))) struct SocketBacklogTests {
        /// Linux's default `wmem_default`, which a socket's `SO_SNDBUF` starts at.
        private let buffer: Int32 = 212_992

        // MARK: The two reads

        @Test func whatTheSocketHoldsIsItsBufferLessItsFreeSpace() {
            #expect(SocketBacklog.bytes(sendBuffer: buffer, freeSpace: buffer - 12_000) == 12_000)
            #expect(SocketBacklog.bytes(sendBuffer: buffer, freeSpace: buffer) == 0, "an empty buffer")
            #expect(SocketBacklog.bytes(sendBuffer: buffer, freeSpace: 0) == Int(buffer), "a full one, or one charged past it")
        }

        @Test func aFailedReadCountsNothing() {
            #expect(SocketBacklog.bytes(sendBuffer: nil, freeSpace: 100) == 0)
            #expect(SocketBacklog.bytes(sendBuffer: buffer, freeSpace: nil) == 0)
            #expect(SocketBacklog.bytes(sendBuffer: nil, freeSpace: nil) == 0)
        }

        @Test func anAnswerTheKernelCannotGiveCountsNothing() {
            #expect(SocketBacklog.bytes(sendBuffer: buffer, freeSpace: -1) == 0, "negative free space")
            #expect(SocketBacklog.bytes(sendBuffer: buffer, freeSpace: buffer + 1) == 0, "more free than the buffer")
            #expect(SocketBacklog.bytes(sendBuffer: 0, freeSpace: 0) == 0, "no buffer")
            #expect(SocketBacklog.bytes(sendBuffer: -4096, freeSpace: -8192) == 0, "a negative buffer")
        }

        @Test func theCallsAnswerOnAnOpenSocketAndFailOnAClosedOne() throws {
            let descriptor = try UnixSockets.socket()
            defer { Glibc.close(descriptor) }
            let size = try #require(L2CAPSockets.sendBuffer(of: descriptor), "SO_SNDBUF answers on any socket")
            #expect(size > 0)
            #expect(L2CAPSockets.freeSpace(of: descriptor) != nil, "TIOCOUTQ answers on a Unix socket too, meaning its own thing")
            #expect(L2CAPSockets.sendBuffer(of: -1) == nil)
            #expect(L2CAPSockets.freeSpace(of: -1) == nil)
            let sockets = L2CAPSockets(adapter: try #require(BluetoothAddress("00:11:22:33:44:55")))
            #expect(sockets.queuedBelow(-1) == 0, "both calls fail, so nothing is counted")
        }

        @Test func aSocketThatCannotSayCountsNothing() throws {
            let sockets = UnixSockets(directory: "/tmp")
            let descriptor = try UnixSockets.socket()
            defer { Glibc.close(descriptor) }
            #expect(sockets.queuedBelow(descriptor) == 0, "the provider's default")
        }

        // MARK: The channels' sockets

        @Test func aChannelIsReadOnlyWhileWatched() {
            let reads = Lock<[Int32]>([])
            let backlogs = SocketBacklogs { descriptor in
                reads.withLock { $0.append(descriptor) }
                return 700
            }
            let id = ChannelID(5)
            #expect(backlogs.bytes(on: id) == 0, "not watched")
            backlogs.watch(id, descriptor: 42)
            #expect(backlogs.bytes(on: id) == 700)
            #expect(backlogs.bytes(on: ChannelID(6)) == 0)
            backlogs.forget(id)
            #expect(backlogs.bytes(on: id) == 0)
            #expect(reads.withLock { $0 } == [42], "a forgotten socket is never read")
        }

        @Test func aNegativeReadCountsNothing() {
            let backlogs = SocketBacklogs { _ in -5 }
            backlogs.watch(ChannelID(1), descriptor: 3)
            #expect(backlogs.bytes(on: ChannelID(1)) == 0)
        }

        // MARK: The level

        @Test func theLevelAddsWhatTheSocketHoldsAndLeavesWrittenAlone() {
            let mailbox = Mailbox { _ in 700 }
            let id = mailbox.nextChannel()
            mailbox.levels.queued(5000, on: id)
            mailbox.levels.wrote(3000, on: id)
            #expect(mailbox.level(on: id) == OutboxLevel(queuedBytes: 2000, writtenBytes: 3000), "no socket watched yet")
            mailbox.backlogs.watch(id, descriptor: 9)
            #expect(mailbox.level(on: id) == OutboxLevel(queuedBytes: 2000, writtenBytes: 3000, belowBytes: 700))
            #expect(mailbox.level(on: id).unwrittenBytes == 2700)
        }

        @Test func theSocketNeverHoldsMoreThanItWasGiven() {
            let mailbox = Mailbox { _ in 50_000 }
            let id = mailbox.nextChannel()
            mailbox.backlogs.watch(id, descriptor: 9)
            #expect(mailbox.level(on: id).belowBytes == 0, "nothing written yet")
            mailbox.levels.queued(800, on: id)
            mailbox.levels.wrote(600, on: id)
            #expect(mailbox.level(on: id) == OutboxLevel(queuedBytes: 200, writtenBytes: 600, belowBytes: 600))
        }

        /// The loop watches an accepted channel's socket and a dialed one's once it opens, and forgets each before it
        /// closes the socket.
        @Test func theLoopWatchesEachOpenChannelsSocketUntilItCloses() throws {
            let rig = try LoopRig(limit: 60_000) { _ in 1000 }
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            let accepted = try #require(rig.lastAccepted)
            #expect(rig.mailbox.backlogs.bytes(on: accepted) == 1000)
            rig.post(.write(accepted, [UInt8](repeating: 7, count: 4000)))
            rig.settle("never written") { rig.mailbox.level(on: accepted).writtenBytes == 4000 }
            #expect(rig.mailbox.level(on: accepted) == OutboxLevel(queuedBytes: 0, writtenBytes: 4000, belowBytes: 1000))
            #expect(remote.receive()?.count == 4000)

            let listener = try RemoteListener(for: try LoopRig.target(), psm: UnixSockets.psm, in: rig.sockets.directory)
            // Its far end held, so the channel stays open.
            let (dialed, far) = try rig.dialPeer(listener)
            #expect(rig.mailbox.backlogs.bytes(on: dialed) == 1000)

            rig.post(.close(accepted))
            rig.settle("never closed") { rig.events.contains(.closed(accepted)) }
            #expect(rig.mailbox.backlogs.bytes(on: accepted) == 0)
            #expect(rig.mailbox.backlogs.bytes(on: dialed) == 1000, "the other channel's socket is still read")
            rig.post(.stop)
            rig.settle("never brought down") { rig.mailbox.backlogs.bytes(on: dialed) == 0 }
            withExtendedLifetime(far) {
                // Held to here.
            }
        }
    }
#endif
