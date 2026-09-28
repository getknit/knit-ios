#if os(Linux)
    @testable import KnitBlueZ
    import KnitMesh
    import KnitWire
    import Testing

    /// The rig and helpers both GATT suites share.
    private enum GattRig {
        static let peer = RadioAddress(LoopRig.peerPath)
        static let otherPeerAddress = "5A:00:00:00:00:4F"
        static let otherPeerPath = FakeBlueZ.adapter + "/dev_5A_00_00_00_00_4F"

        static func reading(
            _ gatt: GattPayloads.Configuration = LoopRig.gattPacing, acceptedPeer: DialTarget? = nil
        ) throws -> LoopRig {
            try LoopRig(profile: .ios, acceptedPeer: acceptedPeer, readsGattPayloads: true, gatt: gatt)
        }

        /// Pacing that gives a read up quickly, for a test that waits for that to happen: its fake never answers, so
        /// a slow run cannot change the outcome.
        static let brisk = GattPayloads.Configuration(
            readTimeoutMilliseconds: 300, retryMilliseconds: 60_000, strangerRetryMilliseconds: 60_000)

        /// Pacing whose deadline a slow run (TSan) cannot reach before the test has looked.
        static func patient(retryMilliseconds: Int64 = 60_000) -> GattPayloads.Configuration {
            GattPayloads.Configuration(
                readTimeoutMilliseconds: 1500, retryMilliseconds: retryMilliseconds, strangerRetryMilliseconds: 60_000)
        }

        static func sightings(_ rig: LoopRig) -> [RadioSighting] {
            rig.events.compactMap { if case .sighted(let sighting) = $0 { sighting } else { nil } }
        }

        static func strength(_ rssi: Int16, of path: String = LoopRig.peerPath, on rig: LoopRig) throws {
            try rig.fake.change(path, interface: BlueZ.deviceInterface, .properties([("RSSI", .int16(rssi))]))
        }
    }

    /// Reading the GATT payload of a peer that advertises only the `0xFE30` UUID, against the fake BlueZ's remote GATT
    /// servers (ADR 2026-09.xzpt): a read, and whom the radio reads.
    @Suite(.timeLimit(.minutes(1))) struct BlueZGattReadTests {
        // MARK: A read

        @Test func aPeerAdvertisingOnlyTheUUIDIsReadThenSighted() throws {
            let rig = try GattRig.reading()
            rig.start()
            rig.fake.remoteGatt[LoopRig.peerPath] = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            let expected = RadioSighting(address: GattRig.peer, advert: LoopRig.gattAdvert(), rssi: -55)
            rig.settle { rig.events.last == .sighted(expected) }
            rig.settle("the read's link was never dropped") { rig.fake.disconnected == [LoopRig.peerPath] }
            #expect(rig.fake.connectRequests == [LoopRig.peerPath])
            #expect(rig.fake.calls.filter { $0 == "org.bluez.GattCharacteristic1.ReadValue" }.count == 1)
            #expect(rig.log.all.contains { $0.contains("bluez read \(LoopRig.advert().nodeId) on PSM \(UnixSockets.psm)") })
        }

        @Test func everyLaterAdvertIsSightedWithWhatTheReadFound() throws {
            let rig = try GattRig.reading()
            rig.start()
            rig.fake.remoteGatt[LoopRig.peerPath] = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { GattRig.sightings(rig).count == 1 }
            try GattRig.strength(-70, on: rig)
            let expected = RadioSighting(address: GattRig.peer, advert: LoopRig.gattAdvert(), rssi: -70)
            rig.settle { rig.events.last == .sighted(expected) }
            #expect(rig.fake.connectRequests.count == 1, "read once")
        }

        @Test func servicesResolvedBeforeConnectAnswersStillRead() throws {
            let rig = try GattRig.reading()
            rig.start()
            var gatt = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            gatt.resolvesBeforeAnswering = true
            rig.fake.remoteGatt[LoopRig.peerPath] = gatt
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { GattRig.sightings(rig).map(\.advert) == [LoopRig.gattAdvert()] }
        }

        @Test func aPeerBlueZAlreadyHoldsALinkToIsReadOverIt() throws {
            let rig = try GattRig.reading()
            rig.start()
            rig.fake.remoteGatt[LoopRig.peerPath] = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            try rig.fake.holdLink(LoopRig.peerPath)
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { GattRig.sightings(rig).map(\.advert) == [LoopRig.gattAdvert()] }
            #expect(rig.fake.connectRequests == [LoopRig.peerPath], "answered AlreadyConnected")
        }

        // MARK: Whom it reads

        @Test func aRadioThatDoesNotReadGATTLeavesAUUIDOnlyPeerAlone() throws {
            let rig = try LoopRig(profile: .ios)
            rig.start()
            rig.fake.remoteGatt[LoopRig.peerPath] = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            try GattRig.strength(-60, on: rig)
            rig.turn()
            #expect(rig.fake.connectRequests.isEmpty)
            #expect(GattRig.sightings(rig).isEmpty)
        }

        @Test func aPeerWithServiceDataIsNeverReadOverGATT() throws {
            let rig = try GattRig.reading()
            rig.start()
            let device = FakeBlueZ.device(address: LoopRig.peerAddress, advert: LoopRig.advert(), uuids: [AdvertPayload.serviceUUID])
            try rig.fake.add(device: LoopRig.peerPath, device)
            rig.settle { GattRig.sightings(rig).map(\.advert) == [LoopRig.advert()] }
            rig.turn()
            #expect(rig.fake.connectRequests.isEmpty)
        }

        @Test func aUUIDOnlyDeviceOfHci0IsNeverRead() throws {
            let rig = try GattRig.reading()
            rig.start()
            try rig.fake.add(device: LoopRig.otherPath, LoopRig.uuidOnlyDevice(address: "11:22:33:44:55:66"))
            try GattRig.strength(-40, of: LoopRig.otherPath, on: rig)
            rig.turn()
            #expect(rig.fake.connectRequests.isEmpty)
            #expect(rig.events == [.state(.on), .listening(psm: UnixSockets.psm)])
        }

        @Test func aDeviceWithAChannelOpenIsNotRead() throws {
            let rig = try GattRig.reading(acceptedPeer: try LoopRig.target())
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            rig.fake.remoteGatt[LoopRig.peerPath] = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            try GattRig.strength(-60, on: rig)
            rig.turn()
            #expect(rig.fake.connectRequests.isEmpty)
            remote.hangUp()
        }

        @Test func oneDeviceIsReadAtATime() throws {
            let rig = try GattRig.reading(GattRig.patient())
            rig.start()
            var silent = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            silent.answersConnect = false
            rig.fake.remoteGatt[LoopRig.peerPath] = silent
            rig.fake.remoteGatt[GattRig.otherPeerPath] = FakeBlueZ.RemoteGatt(value: LoopRig.advert(8).gattValue)
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { rig.fake.connectRequests == [LoopRig.peerPath] }
            try rig.fake.add(device: GattRig.otherPeerPath, LoopRig.uuidOnlyDevice(address: GattRig.otherPeerAddress))
            rig.turn()
            #expect(rig.fake.connectRequests == [LoopRig.peerPath], "the second waits for the first")
            rig.settle("the first read never gave up") { rig.fake.disconnected.contains(LoopRig.peerPath) }
            try GattRig.strength(-60, of: GattRig.otherPeerPath, on: rig)
            rig.settle { GattRig.sightings(rig).map(\.advert) == [LoopRig.gattAdvert(8)] }
        }
    }

    /// GATT reads that fail, and reading a payload again (ADR 2026-09.xzpt).
    @Suite(.timeLimit(.minutes(1))) struct BlueZGattRetryTests {
        // MARK: Reads that fail

        @Test func aDeviceThatServesNoPayloadIsAStrangerAndLeftAlone() throws {
            let rig = try GattRig.reading()
            rig.start()
            rig.fake.remoteGatt[LoopRig.peerPath] = FakeBlueZ.RemoteGatt(value: nil)
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { rig.fake.disconnected == [LoopRig.peerPath] }
            try GattRig.strength(-60, on: rig)
            rig.turn()
            #expect(rig.fake.connectRequests.count == 1)
            #expect(GattRig.sightings(rig).isEmpty)
            #expect(rig.log.all.contains { $0.contains("serves no Knit payload") })
        }

        @Test func aCharacteristicThatHoldsNoPayloadIsAStranger() throws {
            let rig = try GattRig.reading()
            rig.start()
            rig.fake.remoteGatt[LoopRig.peerPath] = FakeBlueZ.RemoteGatt(value: [1, 2, 3])
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { rig.fake.disconnected == [LoopRig.peerPath] }
            #expect(GattRig.sightings(rig).isEmpty)
            #expect(rig.log.all.contains { $0.contains("holds no payload") })
        }

        @Test func aCharacteristicThatWillNotReadDropsTheLink() throws {
            let rig = try GattRig.reading()
            rig.start()
            var gatt = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            gatt.readFails = true
            rig.fake.remoteGatt[LoopRig.peerPath] = gatt
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { rig.fake.disconnected == [LoopRig.peerPath] }
            #expect(GattRig.sightings(rig).isEmpty)
            #expect(rig.log.all.contains { $0.contains("did not read") })
        }

        @Test func aFailedConnectIsTriedAgainOnceItsWaitIsOver() throws {
            let rig = try GattRig.reading(GattRig.patient(retryMilliseconds: 500))
            rig.start()
            var gatt = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            gatt.connects = false
            rig.fake.remoteGatt[LoopRig.peerPath] = gatt
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { rig.log.all.contains { $0.contains("did not connect") } }
            try GattRig.strength(-60, on: rig)
            rig.turn()
            #expect(rig.fake.connectRequests.count == 1, "not while it waits")
            rig.fake.remoteGatt[LoopRig.peerPath]?.connects = true
            rig.settle {
                _ = try? GattRig.strength(-61, on: rig)
                return !GattRig.sightings(rig).isEmpty
            }
            #expect(rig.fake.connectRequests.count == 2)
        }

        @Test func aReadThatNeverAnswersIsGivenUpAtItsDeadline() throws {
            let rig = try GattRig.reading(GattRig.brisk)
            rig.start()
            var gatt = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            gatt.answersConnect = false
            rig.fake.remoteGatt[LoopRig.peerPath] = gatt
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { rig.fake.connectRequests.count == 1 }
            rig.settle("never gave up") { rig.fake.disconnected == [LoopRig.peerPath] }
            #expect(rig.log.all.contains { $0.contains("took longer than 300 ms") })
            #expect(rig.loop.gatt.current == nil)
        }

        @Test func servicesBlueZWillNotListFailTheRead() throws {
            let rig = try GattRig.reading()
            rig.start()
            rig.fake.refusesInventory = true
            rig.fake.remoteGatt[LoopRig.peerPath] = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { rig.fake.disconnected == [LoopRig.peerPath] }
            #expect(rig.log.all.contains { $0.contains("BlueZ did not list its services") })
            #expect(GattRig.sightings(rig).isEmpty)
        }

        @Test func anAnswerToAReadGivenUpOnIsDropped() throws {
            let rig = try GattRig.reading(GattRig.patient())
            rig.start()
            var gatt = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            gatt.answersConnect = false
            rig.fake.remoteGatt[LoopRig.peerPath] = gatt
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { rig.fake.heldConnects.count == 1 }
            try rig.fake.remove(LoopRig.peerPath, interfaces: [BlueZ.deviceInterface])
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { rig.fake.heldConnects.count == 2 }
            rig.fake.failHeldConnect()
            rig.turn()
            #expect(rig.loop.gattStage == .connecting, "the second read of the same device runs on")
            #expect(!rig.log.all.contains { $0.contains("did not connect") })
        }

        @Test func aLinkThatDropsMidReadFailsTheRead() throws {
            let rig = try GattRig.reading()
            rig.start()
            var gatt = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            gatt.resolves = false
            rig.fake.remoteGatt[LoopRig.peerPath] = gatt
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { rig.loop.gattStage == .resolving }
            try rig.fake.change(LoopRig.peerPath, interface: BlueZ.deviceInterface, .properties([("Connected", .boolean(false))]))
            rig.settle { rig.log.all.contains { $0.contains("its link dropped") } }
            #expect(rig.loop.gatt.current == nil)
            #expect(GattRig.sightings(rig).isEmpty)
        }

        // MARK: Reading again

        @Test func aDialThatFailsReadsThePayloadAgain() throws {
            let rig = try GattRig.reading()
            rig.start()
            rig.fake.remoteGatt[LoopRig.peerPath] = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { GattRig.sightings(rig).count == 1 }
            let id = rig.mailbox.nextChannel()
            rig.post(.dial(id, GattRig.peer, psm: UnixSockets.psm))
            rig.settle { rig.events.last == .dialFailed(id) }
            #expect(rig.log.all.contains { $0.contains("will read the GATT payload of dev_4A_00_00_00_00_EF again") })
            try GattRig.strength(-60, on: rig)
            rig.settle { GattRig.sightings(rig).count == 2 }
            #expect(rig.fake.connectRequests.count == 2)
        }

        @Test func goingDownMidReadDropsItsLinkAndReadsAgainOnTheWayUp() throws {
            let rig = try GattRig.reading()
            rig.start()
            var gatt = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            gatt.answersConnect = false
            rig.fake.remoteGatt[LoopRig.peerPath] = gatt
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { rig.fake.connectRequests.count == 1 }
            rig.post(.stop)
            rig.settle { rig.fake.disconnected == [LoopRig.peerPath] && rig.fake.forgotten == [LoopRig.peerPath] }
            #expect(rig.loop.gatt.current == nil)
            rig.post(.start)
            rig.settle { rig.loop.isUp }
            // Forgotten at the stop, the device is listed afresh once BlueZ hears it again.
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle("no wait after a cancelled read") { rig.fake.connectRequests.count == 2 }
        }

        @Test func aDeviceBlueZForgetsMidReadIsReadAfreshWhenItReturns() throws {
            let rig = try GattRig.reading()
            rig.start()
            var gatt = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            gatt.answersConnect = false
            rig.fake.remoteGatt[LoopRig.peerPath] = gatt
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { rig.fake.connectRequests.count == 1 }
            try rig.fake.remove(LoopRig.peerPath, interfaces: [BlueZ.deviceInterface])
            rig.settle { rig.loop.gatt.current == nil }
            rig.fake.remoteGatt[LoopRig.peerPath]?.answersConnect = true
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { GattRig.sightings(rig).map(\.advert) == [LoopRig.gattAdvert()] }
            #expect(rig.fake.connectRequests.count == 2)
        }

        @Test func aChannelOpenedMidReadKeepsTheLinkWhenTheReadEnds() throws {
            let rig = try GattRig.reading(GattRig.patient(), acceptedPeer: try LoopRig.target())
            rig.start()
            var gatt = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            gatt.resolves = false
            rig.fake.remoteGatt[LoopRig.peerPath] = gatt
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { rig.loop.gattStage == .resolving }
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            rig.settle("never gave up") { rig.loop.gatt.current == nil }
            #expect(rig.fake.disconnected.isEmpty, "the channel still uses the link")
            remote.hangUp()
            rig.settle { rig.fake.disconnected == [LoopRig.peerPath] }
        }
    }
#endif
