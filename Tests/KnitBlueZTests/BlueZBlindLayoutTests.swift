#if os(Linux)
    @testable import KnitBlueZ
    import KnitMesh
    import KnitTestSupport
    import KnitWire
    import Testing

    /// A blinding iPhone's GATT layout as BlueZ finds it (ADR 2026-11.prsp): the doorbell in a `0xFE30` service of its own
    /// beside the payload's, which a rotation replaces. The reader finds each in whichever service holds it; the ring
    /// client treats a doorbell missing while the services settle as a failure the next ring retries, and drops one BlueZ
    /// removes or whose write fails. knit-peer's `ios` profile rotates its value under one characteristic.
    @Suite(.timeLimit(.minutes(1))) struct BlueZBlindLayoutTests {
        private static let lookups = "org.freedesktop.DBus.ObjectManager.GetManagedObjects"

        /// A peer that dialed us, with a channel open, and its device linked as bluetoothd links it.
        private struct Dialed {
            let rig: LoopRig
            let remote: RemoteEnd
            let id: ChannelID
        }

        private func dialedBy(doorbell: Bool = true, apart: Bool = true) throws -> Dialed {
            let rig = try LoopRig(acceptedPeer: try LoopRig.target())
            rig.start()
            rig.fake.remoteGatt[LoopRig.peerPath] = FakeBlueZ.RemoteGatt(
                value: LoopRig.advert().gattValue, doorbell: doorbell, doorbellApart: apart)
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            try rig.fake.holdLink(LoopRig.peerPath)
            rig.turn()
            return Dialed(rig: rig, remote: remote, id: try #require(rig.lastAccepted))
        }

        private static func blinded(_ byte: UInt8) throws -> AdvertPayload {
            let tag = try #require(NodeId(bytes: [0xCE, 0x73, 0x96] + [UInt8](repeating: byte, count: 13)))
            let flags = AdvertPayload.writtenFlags(dialsGattPeers: true, blinded: true, seals: false)
            return AdvertPayload(capabilities: .local, advertised: tag, digestCue: 0, psm: UnixSockets.psm, flags: flags)
        }

        private func lookups(_ rig: LoopRig) -> Int {
            rig.fake.calls.filter { $0 == Self.lookups }.count
        }

        // MARK: Reading

        @Test func aReaderFindsThePayloadBesideADoorbellServedApart() throws {
            let rig = try LoopRig(profile: .ios, acceptedPeer: nil, readsGattPayloads: true, gatt: LoopRig.gattPacing)
            rig.start()
            let payload = try Self.blinded(0x5A)
            rig.fake.remoteGatt[LoopRig.peerPath] = FakeBlueZ.RemoteGatt(value: payload.gattValue, doorbell: true, doorbellApart: true)
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { rig.events.contains { if case .sighted = $0 { true } else { false } } }
            let sighted = rig.events.compactMap { if case .sighted(let sighting) = $0 { sighting } else { nil } }
            #expect(sighted.first?.advert.advertised == payload.advertised)
            #expect(!rig.log.all.contains { $0.contains("serves no Knit payload") })
        }

        @Test func aRingFindsTheDoorbellInItsOwnService() throws {
            let dialed = try dialedBy()
            let (rig, remote, id) = (dialed.rig, dialed.remote, dialed.id)
            rig.post(.ring(id))
            rig.settle { rig.fake.writes.count == 1 }
            let doorbell = RemoteGattObjects.doorbellPath(of: LoopRig.peerPath, apart: true)
            #expect(rig.fake.writes == [FakeBlueZ.Write(path: doorbell, value: [1], type: "command")])
            remote.hangUp()
        }

        // MARK: The settle bound

        /// Just after BlueZ resolved the services, a missing doorbell may be on its way: the next ring looks again, and
        /// finds it once it came.
        @Test func aDoorbellMissingWhileTheServicesSettleIsLookedUpAgain() throws {
            let dialed = try dialedBy(doorbell: false)
            let (rig, remote, id) = (dialed.rig, dialed.remote, dialed.id)
            rig.post(.ring(id))
            rig.settle { rig.log.all.contains { $0.contains("found no doorbell on dev_4A_00_00_00_00_EF yet") } }
            #expect(rig.loop.doorbells[LoopRig.peerPath] == nil)
            let first = lookups(rig)
            rig.fake.remoteGatt[LoopRig.peerPath]?.doorbell = true
            rig.post(.ring(id))
            rig.settle { rig.fake.writes.count == 1 }
            #expect(lookups(rig) == first + 1, "looked up again")
            remote.hangUp()
        }

        /// Past the bound an absence stands, and no ring looks again.
        @Test func aDoorbellMissingPastTheBoundIsAbsent() throws {
            let dialed = try dialedBy(doorbell: false)
            let (rig, remote, id) = (dialed.rig, dialed.remote, dialed.id)
            #expect(rig.loop.doorbellSettlingSince[LoopRig.peerPath] != nil, "ServicesResolved started the bound")
            rig.loop.doorbellSettlingSince[LoopRig.peerPath] = Monotonic.milliseconds() - DoorbellLookup.doorbellSettleMilliseconds
            rig.post(.ring(id))
            rig.settle { rig.loop.doorbells[LoopRig.peerPath] == .absent }
            let looked = lookups(rig)
            rig.post(.ring(id))
            rig.turn()
            #expect(lookups(rig) == looked)
            #expect(rig.fake.writes.isEmpty)
            remote.hangUp()
        }

        @Test func theBoundGoesWithTheLink() throws {
            let dialed = try dialedBy()
            let (rig, remote) = (dialed.rig, dialed.remote)
            try rig.fake.change(LoopRig.peerPath, interface: BlueZ.deviceInterface, .properties([("ServicesResolved", .boolean(false))]))
            rig.turn()
            #expect(rig.loop.doorbellSettlingSince[LoopRig.peerPath] == nil)
            try rig.fake.remove(LoopRig.peerPath, interfaces: [BlueZ.deviceInterface])
            rig.turn()
            #expect(rig.loop.doorbellSettlingSince.isEmpty)
            remote.hangUp()
        }

        // MARK: A doorbell that went

        /// BlueZ removes the characteristic's object when the peer's services change: the next ring looks it up again.
        @Test func aDoorbellBlueZRemovesIsLookedUpAgain() throws {
            let dialed = try dialedBy()
            let (rig, remote, id) = (dialed.rig, dialed.remote, dialed.id)
            rig.post(.ring(id))
            rig.settle { rig.fake.writes.count == 1 }
            let looked = lookups(rig)
            let doorbell = RemoteGattObjects.doorbellPath(of: LoopRig.peerPath, apart: true)
            try rig.fake.remove(doorbell, interfaces: [BlueZ.gattCharacteristic])
            rig.settle { rig.loop.doorbells[LoopRig.peerPath] == nil }
            #expect(rig.log.all.contains { $0.contains("bluez forgot the doorbell of dev_4A_00_00_00_00_EF: BlueZ removed it") })
            rig.post(.ring(id))
            rig.settle { rig.fake.writes.count == 2 }
            #expect(lookups(rig) == looked + 1)
            remote.hangUp()
        }

        /// The payload's service going, as at a rotation, keeps the doorbell found in a service of its own.
        @Test func thePayloadsServiceGoingKeepsTheDoorbell() throws {
            let dialed = try dialedBy()
            let (rig, remote, id) = (dialed.rig, dialed.remote, dialed.id)
            rig.post(.ring(id))
            rig.settle { rig.fake.writes.count == 1 }
            let before = Monotonic.milliseconds()
            try rig.fake.remove(LoopRig.peerPath + "/service0010", interfaces: [BlueZ.gattService])
            rig.settle { (rig.loop.doorbellSettlingSince[LoopRig.peerPath] ?? 0) >= before }
            #expect(rig.loop.doorbells[LoopRig.peerPath] == .at(RemoteGattObjects.doorbellPath(of: LoopRig.peerPath, apart: true)))
            remote.hangUp()
        }

        /// A doorbell found absent may come with a services change.
        @Test func anAbsentDoorbellIsLookedForAgainOnAServicesChange() throws {
            let dialed = try dialedBy(doorbell: false)
            let (rig, remote, id) = (dialed.rig, dialed.remote, dialed.id)
            rig.loop.doorbellSettlingSince[LoopRig.peerPath] = nil
            rig.post(.ring(id))
            rig.settle { rig.loop.doorbells[LoopRig.peerPath] == .absent }
            try rig.fake.remove(LoopRig.peerPath + "/service0010/char0011", interfaces: [BlueZ.gattCharacteristic])
            rig.settle { rig.loop.doorbells[LoopRig.peerPath] == nil }
            // Another device's object, and one of no device BlueZ told us of, change nothing.
            try rig.fake.remove(FakeBlueZ.adapter + "/dev_00_00_00_00_00_01/service0010", interfaces: [BlueZ.gattService])
            rig.turn()
            remote.hangUp()
        }

        /// A `0xFE30` service BlueZ adds, as a blinding iPhone's doorbell service after a services change, clears an
        /// absence and restarts the bound; another service changes nothing.
        @Test func aNewKnitServiceClearsAnAbsentDoorbell() throws {
            let dialed = try dialedBy(doorbell: false)
            let (rig, remote, id) = (dialed.rig, dialed.remote, dialed.id)
            rig.loop.doorbellSettlingSince[LoopRig.peerPath] = nil
            rig.post(.ring(id))
            rig.settle { rig.loop.doorbells[LoopRig.peerPath] == .absent }
            let battery = DBusValue.properties([("UUID", .string("0000180f-0000-1000-8000-00805f9b34fb"))])
            try rig.fake.addObject(LoopRig.peerPath + "/service0020", interface: BlueZ.gattService, battery)
            rig.turn()
            #expect(rig.loop.doorbells[LoopRig.peerPath] == .absent, "not a Knit service")
            let knit = DBusValue.properties([("UUID", .string(AdvertPayload.serviceUUID)), ("Primary", .boolean(true))])
            try rig.fake.addObject(FakeBlueZ.adapter + "/dev_00_00_00_00_00_01/service000a", interface: BlueZ.gattService, knit)
            rig.turn()
            #expect(rig.loop.doorbells[LoopRig.peerPath] == .absent, "another device's")
            try rig.fake.addObject(RemoteGattObjects.doorbellServicePath(of: LoopRig.peerPath), interface: BlueZ.gattService, knit)
            rig.settle { rig.loop.doorbells[LoopRig.peerPath] == nil }
            #expect(rig.loop.doorbellSettlingSince[LoopRig.peerPath] != nil, "the services settle again")
            remote.hangUp()
        }

        /// A write that fails may have gone to a handle that moved: the next ring looks the doorbell up again.
        @Test func aDoorbellWhoseWriteFailsIsLookedUpAgain() throws {
            let dialed = try dialedBy()
            let (rig, remote, id) = (dialed.rig, dialed.remote, dialed.id)
            rig.fake.remoteGatt[LoopRig.peerPath]?.writeFails = true
            rig.post(.ring(id))
            rig.settle { rig.log.all.contains { $0.contains("bluez could not ring dev_4A_00_00_00_00_EF") } }
            rig.settle { rig.loop.doorbells[LoopRig.peerPath] == nil }
            let looked = lookups(rig)
            rig.fake.remoteGatt[LoopRig.peerPath]?.writeFails = false
            rig.post(.ring(id))
            rig.settle { rig.fake.writes.count == 1 }
            #expect(lookups(rig) == looked + 1)
            remote.hangUp()
        }

        // MARK: knit-peer's ios profile, blinding

        /// The `ios` profile answers each read with the advert of the moment, so a rotation moves the value and nothing
        /// else: one application, one characteristic. No GATT object moves here, so no Linux run exercises a moving
        /// handle; only the iPhone's probe can.
        @Test func theIOSProfileRotatesItsBlindedValueUnderOneCharacteristic() throws {
            let rig = try LoopRig(profile: .ios)
            let first = try Self.blinded(0x11)
            rig.startAdvertising(first)
            rig.settle { rig.fake.applicationRoot != nil }
            let path = rig.loop.application.characteristicPath
            try rig.fake.read(characteristic: path)
            rig.settle { rig.fake.readResult != nil }
            let read = try #require(try rig.fake.readResult?.get())
            #expect(AdvertPayload(gattValue: read)?.advertised == first.advertised)
            #expect(AdvertPayload(gattValue: read)?.blinded == true)

            let second = try Self.blinded(0x22)
            rig.post(.advertise(second))
            rig.settle { rig.loop.activeAdvert?.payload == second }
            #expect(rig.loop.application.characteristicPath == path, "the same characteristic")
            try rig.fake.read(characteristic: path)
            rig.settle { rig.fake.readResult != nil }
            let reread = try #require(try rig.fake.readResult?.get())
            #expect(AdvertPayload(gattValue: reread)?.advertised == second.advertised)
            #expect(rig.fake.calls.filter { $0 == "org.bluez.GattManager1.RegisterApplication" }.count == 1, "no GATT churn")
        }
    }
#endif
