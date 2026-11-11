#if os(Linux)
    @testable import KnitBlueZ
    import KnitMesh
    import KnitTestSupport
    import KnitWire
    import Testing

    /// A blinded GATT payload read over BlueZ (ADR 2026-11.prsp): a blinding iPhone's, with its tag's prefix, is sighted as
    /// the blinded form it is, and its line names no tag; one flagged without the prefix is a stranger's.
    @Suite(.timeLimit(.minutes(1))) struct BlueZGattBlindedTests {
        private static func reading() throws -> LoopRig {
            try LoopRig(profile: .ios, acceptedPeer: nil, readsGattPayloads: true, gatt: LoopRig.gattPacing)
        }

        private static func sightings(_ rig: LoopRig) -> [RadioSighting] {
            rig.events.compactMap { if case .sighted(let sighting) = $0 { sighting } else { nil } }
        }

        @Test func aCharacteristicThatHoldsABlindedPayloadIsSightedAsATag() throws {
            let rig = try Self.reading()
            rig.start()
            let tag = try #require(NodeId(bytes: [0xCE, 0x73, 0x96] + [UInt8](repeating: 0x5A, count: 13)))
            let flags = AdvertPayload.writtenFlags(dialsGattPeers: true, blinded: true)
            let blinded = AdvertPayload(capabilities: 0x9, advertised: tag, digestCue: 0, psm: UnixSockets.psm, flags: flags)
            rig.fake.remoteGatt[LoopRig.peerPath] = FakeBlueZ.RemoteGatt(value: blinded.gattValue)
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { Self.sightings(rig).count == 1 }
            let sighted = try #require(Self.sightings(rig).first)
            #expect(sighted.advert.blinded)
            #expect(sighted.advert.advertised == tag)
            #expect(rig.log.all.contains { $0.contains("bluez read a tag on PSM") })
            #expect(!rig.log.all.contains { $0.contains(tag.string) }, "no line names the tag")
        }

        /// As service data's parse has it (`BleAdvertPayload.isMalformedBlinded` at knit-next `cad69c77b`): never sighted,
        /// and not read again at the next advert.
        @Test func aCharacteristicFlaggedBlindedWithoutAPrefixIsAStranger() throws {
            let rig = try Self.reading()
            rig.start()
            let notATag = fixtureNodeId(9)
            let flags = AdvertPayload.blindedFlag
            let malformed = AdvertPayload(capabilities: 0x9, advertised: notATag, digestCue: 0, psm: UnixSockets.psm, flags: flags)
            #expect(AdvertPayload(serviceData: malformed.gattValue) == nil, "as service data it would not read either")
            rig.fake.remoteGatt[LoopRig.peerPath] = FakeBlueZ.RemoteGatt(value: malformed.gattValue)
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { rig.fake.disconnected == [LoopRig.peerPath] }
            try rig.fake.change(LoopRig.peerPath, interface: BlueZ.deviceInterface, .properties([("RSSI", .int16(-60))]))
            rig.turn()
            #expect(rig.fake.connectRequests.count == 1, "a stranger waits out its retry")
            #expect(Self.sightings(rig).isEmpty)
            #expect(rig.log.all.contains { $0.contains("holds no payload") })
            #expect(!rig.log.all.contains { $0.contains("bluez read ") || $0.contains(notATag.string) }, "no read line, no form")
        }
    }
#endif
