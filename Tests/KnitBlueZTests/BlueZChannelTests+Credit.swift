#if os(Linux)
    @testable import KnitBlueZ
    import KnitMesh
    import Testing

    /// A channel's inbound credit on a real socket: the loop stops polling a channel for input once 256 KiB it delivered
    /// wait unprocessed, so what the peer sends waits in the socket until the peer's own writes block, and nothing is lost
    /// once the consumer catches up (ADR 2026-10.f5zs, rule 6).
    extension BlueZChannelTests {
        /// One SDU of a flood, stamped with its place so the order can be checked.
        private static func sdu(_ number: Int) -> [UInt8] {
            let stamp = (0..<4).map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) }
            return stamp + [UInt8](repeating: UInt8(truncatingIfNeeded: number), count: sduBytes - stamp.count)
        }

        private static let sduBytes = 4000

        /// Floods `id` from `remote` until the loop has paused it and the peer's socket takes no more; how many SDUs went.
        private static func floodUntilHeldBack(_ rig: LoopRig, _ remote: RemoteEnd, on id: ChannelID) -> Int {
            var sent = 0
            rig.settle("the channel never paused") {
                while remote.trySend(sdu(sent)) {
                    sent += 1
                }
                return rig.log.all.contains { $0.hasPrefix("bluez \(id) reads paused: ") }
            }
            rig.settle("the peer's socket never filled") {
                rig.turn(3)
                var more = false
                while remote.trySend(sdu(sent)) {
                    sent += 1
                    more = true
                }
                return !more
            }
            return sent
        }

        private static func flood(_ count: Int) -> [UInt8] {
            (0..<count).flatMap(sdu)
        }

        @Test func aChannelAtItsCreditIsReadNoMoreUntilTheConsumerCatchesUp() throws {
            let rig = try LoopRig()
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            let id = try #require(rig.lastAccepted)
            let sent = Self.floodUntilHeldBack(rig, remote, on: id)
            let held = rig.received(on: id).count
            #expect(held >= InboxCredits.limitBytes)
            #expect(held < InboxCredits.limitBytes + Self.sduBytes, "the credit is asked before every read")
            #expect(sent * Self.sduBytes > held, "the rest waits in the socket, and the peer's writes block")
            #expect(rig.log.all.contains("bluez \(id) reads paused: \(held) bytes unprocessed"))
            rig.turn()
            #expect(rig.received(on: id).count == held, "nothing more is read while the channel waits")
            #expect(rig.mailbox.credits.unprocessed(on: id) == held)

            rig.mailbox.consumed(InboxCredits.limitBytes / 4, on: id)
            rig.turn()
            #expect(rig.received(on: id).count == held, "above half, the channel still waits")

            var consumed = InboxCredits.limitBytes / 4
            rig.settle("the rest never arrived") {
                let now = rig.received(on: id).count
                if now > consumed {
                    rig.mailbox.consumed(now - consumed, on: id)
                    consumed = now
                }
                return now >= sent * Self.sduBytes
            }
            #expect(rig.received(on: id) == Self.flood(sent), "nothing lost, in order")
            #expect(rig.log.all.contains { $0.hasPrefix("bluez \(id) reads resumed: ") })
            #expect(remote.trySend(Self.sdu(sent)), "the peer can write again")
        }

        @Test func aPeerHangingUpWhileItsChannelWaitsStillClosesIt() throws {
            let rig = try LoopRig()
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            let id = try #require(rig.lastAccepted)
            let sent = Self.floodUntilHeldBack(rig, remote, on: id)
            remote.hangUp()
            rig.settle("the hang-up never closed the channel") { rig.events.last == .closed(id) }
            #expect(rig.received(on: id) == Self.flood(sent), "what the socket held is read through to the end")
            #expect(rig.mailbox.credits.isEmpty, "the credit dies with the channel")
        }

        @Test func aFloodOnOneChannelHoldsNoOther() throws {
            let rig = try LoopRig()
            rig.start()
            let flooder = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            let flooded = try #require(rig.lastAccepted)
            let honest = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != flooded }
            let other = try #require(rig.lastAccepted)
            _ = Self.floodUntilHeldBack(rig, flooder, on: flooded)
            honest.send([1, 2, 3])
            rig.settle { rig.received(on: other) == [1, 2, 3] }
            rig.post(.close(flooded))
            rig.settle { rig.events.last == .closed(flooded) }
            #expect(rig.mailbox.credits.unprocessed(on: flooded) == 0, "a closed channel is no longer counted")
        }

        /// `--stop-reading-after` and the credit compose: a resume reads nothing once a trial stopped every read.
        @Test func aResumeReadsNothingOnceATrialStoppedReading() throws {
            let rig = try LoopRig(stopReadingAfter: 0)
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            let id = try #require(rig.lastAccepted)
            remote.send([1, 2, 3])
            rig.turn()
            rig.post(.resumeReading(id, unprocessed: 0))
            rig.turn()
            #expect(rig.received(on: id).isEmpty)
            #expect(!rig.log.all.contains { $0.hasPrefix("bluez \(id) reads paused") }, "a stopped loop never reached the credit")
        }

        @Test func goingDownForgetsEveryCredit() throws {
            let rig = try LoopRig()
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            let id = try #require(rig.lastAccepted)
            remote.send([1])
            rig.settle { rig.received(on: id) == [1] }
            #expect(!rig.mailbox.credits.isEmpty)
            rig.post(.stop)
            rig.settle { rig.loop.channels.isEmpty }
            #expect(rig.mailbox.credits.isEmpty)
        }
    }
#endif
