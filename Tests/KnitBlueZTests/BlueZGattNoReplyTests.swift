#if os(Linux)
    @testable import KnitBlueZ
    import KnitMesh
    import KnitWire
    import Testing

    /// The seal's forget-once rule on BlueZ (the `link-seal` contract, §7, revision 1): our plain dial that got no reply
    /// forgets an unflagged payload once, so the next advert reads it again; the payload read again is kept.
    @Suite(.timeLimit(.minutes(1))) struct BlueZGattNoReplyTests {
        @Test func aNoReplyForgetsAnUnflaggedPayloadOnceAndTheNextAdvertReadsItAgain() throws {
            let rig = try GattRig.reading()
            rig.start()
            rig.fake.remoteGatt[LoopRig.peerPath] = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { GattRig.sightings(rig).count == 1 }
            rig.settle("the read's link was never dropped") { rig.fake.disconnected == [LoopRig.peerPath] }
            rig.post(.dialGotNoReply(GattRig.peer))
            rig.settle { rig.loop.gatt.payload(of: GattRig.peer) == nil }
            let line = "bluez forgetting the GATT payload of dev_4A_00_00_00_00_EF: a plain dial to it got no reply"
            #expect(rig.log.all.contains { $0.contains(line) })
            rig.settle("never read again") {
                _ = try? GattRig.strength(-61, on: rig)
                return rig.loop.gatt.payload(of: GattRig.peer) != nil
            }
            #expect(rig.fake.connectRequests.count == 2)
            rig.post(.dialGotNoReply(GattRig.peer))
            rig.turn(3)
            #expect(rig.loop.gatt.payload(of: GattRig.peer) == LoopRig.gattAdvert(), "once: the payload read again is kept")
        }
    }
#endif
