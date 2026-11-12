#if os(Linux)
    @testable import KnitBlueZ
    import KnitMesh
    import KnitTestSupport
    import KnitWire
    import Testing

    /// The link a GATT read made outlives the read by a grace, as KnitBLE's reader's does: an iPhone whose new address we
    /// read ends our old link to it, and dials back over the read's own connection right after the read
    /// (`.agents/context/linux-peer.md`, "The iPhone ends a link when the same device connects to it again").
    @Suite(.timeLimit(.minutes(1))) struct BlueZGattReleaseTests {
        /// Long enough that a loaded run (TSan) accepts the channel well inside it.
        private static let grace: Int64 = 1500

        private func reading() throws -> LoopRig {
            let rig = try LoopRig(profile: .ios, acceptedPeer: try LoopRig.target(), readsGattPayloads: true, readReleaseGrace: Self.grace)
            rig.start()
            rig.fake.remoteGatt[LoopRig.peerPath] = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle("never read") { rig.events.contains { if case .sighted = $0 { true } else { false } } }
            return rig
        }

        /// Turns the loop and the fake for `milliseconds` of real time.
        private func turn(_ rig: LoopRig, for milliseconds: Int64) {
            let until = Monotonic.milliseconds() + milliseconds
            while Monotonic.milliseconds() < until {
                rig.turn(1)
            }
        }

        @Test func aChannelThePeerOpensRightAfterTheReadKeepsTheReadsLink() throws {
            let rig = try reading()
            #expect(rig.fake.disconnected.isEmpty, "the grace holds the link")
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle("never accepted") { rig.lastAccepted != nil }
            turn(rig, for: Self.grace + 500)
            #expect(rig.fake.disconnected.isEmpty, "the channel uses the link")
            remote.hangUp()
            rig.settle("the channel's close never dropped the link") { rig.fake.disconnected == [LoopRig.peerPath] }
        }

        @Test func aReadsLinkNothingUsesIsDroppedOnceItsGraceEnds() throws {
            let rig = try reading()
            let read = Monotonic.milliseconds()
            #expect(rig.fake.disconnected.isEmpty, "not at the read's end")
            rig.settle("the read's link was never dropped") { rig.fake.disconnected == [LoopRig.peerPath] }
            #expect(Monotonic.milliseconds() - read >= Self.grace - 100, "not before its grace")
        }

        @Test func aFailedReadDropsItsLinkAtOnce() throws {
            let rig = try LoopRig(profile: .ios, readsGattPayloads: true, readReleaseGrace: 60_000)
            rig.start()
            // A device that serves no Knit payload: a stranger, whose connection goes as the read ends.
            rig.fake.remoteGatt[LoopRig.peerPath] = FakeBlueZ.RemoteGatt(value: [1, 2, 3])
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle("the failed read's link was never dropped") { rig.fake.disconnected == [LoopRig.peerPath] }
        }

        @Test func theRadioGoingDownDropsALinkInItsGrace() throws {
            let rig = try reading()
            rig.post(.stop)
            rig.settle("the stop never dropped the read's link") { rig.fake.disconnected == [LoopRig.peerPath] }
            turn(rig, for: Self.grace + 200)
            #expect(rig.fake.disconnected == [LoopRig.peerPath], "once")
        }
    }
#endif
