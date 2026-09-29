#if os(Linux)
    import Foundation
    @testable import KnitBlueZ
    import KnitMesh
    import KnitWire
    import Testing

    /// The BlueZ radio's loop against a fake BlueZ: the adapter check, bring-up and teardown, and the scan.
    @Suite(.timeLimit(.minutes(1))) struct BlueZLoopTests {
        // MARK: The adapter

        @Test func startingChecksTheAdapterThenListensAndScans() throws {
            let rig = try LoopRig()
            rig.start()
            #expect(rig.events == [.state(.on), .listening(psm: UnixSockets.psm)])
            rig.settle { rig.fake.discovering }
            #expect(rig.fake.discoveryFilter?["Transport"]?.text == "le")
            #expect(rig.fake.discoveryFilter?["DuplicateData"]?.bool == true)
            let inventory = try #require(rig.fake.calls.firstIndex(of: "org.freedesktop.DBus.ObjectManager.GetManagedObjects"))
            let discovery = try #require(rig.fake.calls.firstIndex(of: "org.bluez.Adapter1.StartDiscovery"))
            #expect(inventory < discovery, "the adapter is checked before anything is asked of it")
        }

        @Test func anAdapterWithAnotherAddressIsRefusedBeforeAnythingOpens() throws {
            let rig = try LoopRig(expectedAddress: "00:11:22:33:44:55")
            rig.loop.connect(now: Monotonic.milliseconds())
            rig.post(.start)
            rig.settle { rig.events == [.state(.unsupported)] }
            rig.turn()
            #expect(rig.events == [.state(.unsupported)])
            #expect(rig.fake.calls.allSatisfy { !$0.hasPrefix("org.bluez.") }, "nothing is asked of BlueZ")
            #expect(!FileManager.default.fileExists(atPath: rig.sockets.listenerPath), "no socket is opened")
            #expect(rig.log.all.contains { $0.contains("refused the adapter") })
        }

        @Test func aMissingAdapterIsUnsupported() throws {
            let rig = try LoopRig()
            rig.fake.hasAdapter = false
            rig.loop.connect(now: Monotonic.milliseconds())
            rig.post(.start)
            rig.settle { rig.events == [.state(.unsupported)] }
        }

        @Test func anUnpoweredAdapterIsOffUntilItPowersUp() throws {
            let rig = try LoopRig()
            rig.fake.powered = false
            rig.loop.connect(now: Monotonic.milliseconds())
            rig.post(.start)
            rig.settle { rig.events == [.state(.off)] }
            try rig.fake.setPowered(true)
            rig.settle { rig.events == [.state(.off), .state(.on), .listening(psm: UnixSockets.psm)] }
        }

        @Test func losingPowerTakesThePlaneDown() throws {
            let rig = try LoopRig()
            rig.start()
            try rig.fake.setPowered(false)
            rig.settle { rig.events.last == .state(.off) }
            #expect(rig.loop.listener == nil)
            #expect(throws: SocketError.self) { try RemoteEnd.dial(rig.sockets) }
        }

        @Test func aListenerThatWillNotOpenLeavesTheRadioOff() throws {
            let rig = try LoopRig(failsToListen: true)
            rig.loop.connect(now: Monotonic.milliseconds())
            rig.post(.start)
            rig.settle { rig.events == [.state(.off)] }
            #expect(!rig.fake.discovering)
        }

        @Test func anUnreachableBusIsUnsupportedAndRetried() throws {
            let rig = try LoopRig()
            let dead = BlueZLoop(
                configuration: BlueZLoop.Configuration(
                    bus: .peer("unix:path=/nonexistent/knit"),
                    adapter: try AdapterSelection(name: "hci1", expectedAddress: FakeBlueZ.adapterAddress),
                    profile: .android,
                    sockets: rig.sockets,
                    objectRoot: "/app/getknit/test",
                    log: rig.log,
                    retryDelayMilliseconds: 10
                ),
                mailbox: Mailbox()
            ) { event in #expect(event == .state(.unsupported)) }
            dead.connect(now: Monotonic.milliseconds())
            #expect(dead.bus == nil)
            #expect(dead.reconnectAt != nil)
            dead.iterate(maximumWaitMilliseconds: 20)
            #expect(rig.log.all.filter { $0.contains("bus unreachable") }.count == 2, "tried again once the delay passed")
        }

        // MARK: Stopping

        @Test func stoppingWithdrawsTheAdvertTheScanAndTheListener() throws {
            let rig = try LoopRig()
            rig.startAdvertising()
            rig.post(.stop)
            rig.settle { rig.fake.registered.isEmpty && !rig.fake.discovering }
            #expect(rig.loop.listener == nil)
            #expect(rig.events == [.state(.on), .listening(psm: UnixSockets.psm)], "the link manager already forgot everything")
        }

        @Test func aStoppedRadioStartsAgain() throws {
            let rig = try LoopRig()
            rig.start()
            rig.post(.stop)
            rig.settle { !rig.fake.discovering }
            rig.post(.start)
            rig.settle { rig.events.filter { $0 == .listening(psm: UnixSockets.psm) }.count == 2 }
            rig.settle { rig.fake.discovering }
        }

        @Test func shuttingDownWithdrawsEverythingAndEnds() throws {
            let rig = try LoopRig(profile: .ios)
            rig.startAdvertising()
            rig.post(.shutdown)
            // The loop spends up to half a second flushing; the fake must answer meanwhile, so turn it alongside.
            var turns = 0
            while !rig.loop.isFinished, turns < 200 {
                rig.fake.iterate(waitMilliseconds: 1)
                rig.loop.iterate(maximumWaitMilliseconds: 1)
                turns += 1
            }
            #expect(rig.loop.isFinished)
            rig.fake.iterate(waitMilliseconds: 5)
            #expect(rig.fake.calls.contains("org.bluez.LEAdvertisingManager1.UnregisterAdvertisement"))
            #expect(rig.fake.calls.contains("org.bluez.GattManager1.UnregisterApplication"))
        }

        // MARK: When BlueZ comes and goes

        @Test func bluetoothdLeavingTakesThePlaneDownAndItsReturnBringsItBack() throws {
            let rig = try LoopRig()
            rig.start()
            let owner = [DBusValue.string(BlueZ.service), .string(":1.7"), .string("")]
            try rig.fake.radio?.emit(path: BlueZ.busPath, interface: BlueZ.bus, member: "NameOwnerChanged", values: owner)
            rig.settle { rig.events.last == .state(.off) }
            let back = [DBusValue.string(BlueZ.service), .string(""), .string(":1.9")]
            try rig.fake.radio?.emit(path: BlueZ.busPath, interface: BlueZ.bus, member: "NameOwnerChanged", values: back)
            rig.settle { rig.events.suffix(2) == [.state(.on), .listening(psm: UnixSockets.psm)] }
            #expect(rig.loop.bluezOwner == ":1.9")
        }

        @Test func anotherNamesOwnerChangingIsIgnored() throws {
            let rig = try LoopRig()
            rig.start()
            let other = [DBusValue.string("org.example"), .string(":1.2"), .string("")]
            try rig.fake.radio?.emit(path: BlueZ.busPath, interface: BlueZ.bus, member: "NameOwnerChanged", values: other)
            rig.turn()
            #expect(rig.events.last == .listening(psm: UnixSockets.psm))
        }

        @Test func theAdapterGoingAwayTakesThePlaneDownAndItsReturnBringsItBack() throws {
            let rig = try LoopRig()
            rig.start()
            try rig.fake.remove(FakeBlueZ.adapter, interfaces: [BlueZ.adapterInterface])
            rig.settle { rig.events.last == .state(.off) }
            let adapter = DBusValue.properties([("Address", .string(FakeBlueZ.adapterAddress)), ("Powered", .boolean(true))])
            try rig.fake.radio?.emit(
                path: "/",
                interface: BlueZ.objectManager,
                member: "InterfacesAdded",
                values: [.objectPath(FakeBlueZ.adapter), FakeBlueZ.interfaces([(BlueZ.adapterInterface, adapter)])]
            )
            rig.settle { rig.events.suffix(2) == [.state(.on), .listening(psm: UnixSockets.psm)] }
        }

        @Test func theBusGoingAwayIsOffUntilItReconnects() throws {
            let rig = try LoopRig()
            rig.start()
            rig.fake.dropRadio()
            rig.settle { rig.events.last == .state(.off) }
            rig.settle("never reconnected") { rig.events.suffix(2) == [.state(.on), .listening(psm: UnixSockets.psm)] }
        }

        @Test func anInventoryBlueZRefusesIsUnsupported() throws {
            let rig = try LoopRig()
            rig.fake.refusesInventory = true
            rig.loop.connect(now: Monotonic.milliseconds())
            rig.post(.start)
            rig.settle { rig.events == [.state(.unsupported)] }
            #expect(rig.log.all.contains { $0.contains("is bluetoothd running") })
        }

        // MARK: Scanning

        @Test func aKnitDeviceOnThisAdapterIsSighted() throws {
            let rig = try LoopRig()
            rig.start()
            try rig.fake.add(device: LoopRig.peerPath, FakeBlueZ.device(address: LoopRig.peerAddress, advert: LoopRig.advert()))
            let expected = RadioSighting(address: RadioAddress(LoopRig.peerPath), advert: LoopRig.advert(), rssi: -55)
            rig.settle { rig.events.last == .sighted(expected) }
        }

        @Test func aNodeNeverSightedIsNeverReported() throws {
            let rig = try LoopRig(neverSighted: [LoopRig.advert().nodeId])
            rig.start()
            try rig.fake.add(device: LoopRig.peerPath, FakeBlueZ.device(address: LoopRig.peerAddress, advert: LoopRig.advert()))
            try rig.fake.change(LoopRig.peerPath, interface: BlueZ.deviceInterface, .properties([("RSSI", .int16(-70))]))
            let other = FakeBlueZ.adapter + "/dev_5A_00_00_00_00_4F"
            try rig.fake.add(device: other, FakeBlueZ.device(address: "5A:00:00:00:00:4F", advert: LoopRig.advert(8)))
            let expected = RadioSighting(address: RadioAddress(other), advert: LoopRig.advert(8), rssi: -55)
            rig.settle { rig.events.last == .sighted(expected) }
            let sighted = rig.events.compactMap { event -> String? in
                if case .sighted(let sighting) = event { sighting.address.rawValue } else { nil }
            }
            #expect(!sighted.contains(LoopRig.peerPath))
        }

        @Test func everyAdvertIsASightingWithItsNewStrength() throws {
            let rig = try LoopRig()
            rig.start()
            try rig.fake.add(device: LoopRig.peerPath, FakeBlueZ.device(address: LoopRig.peerAddress, advert: LoopRig.advert()))
            try rig.fake.change(LoopRig.peerPath, interface: BlueZ.deviceInterface, .properties([("RSSI", .int16(-70))]))
            let expected = RadioSighting(address: RadioAddress(LoopRig.peerPath), advert: LoopRig.advert(), rssi: -70)
            rig.settle { rig.events.last == .sighted(expected) }
        }

        @Test func aDeviceThatStoppedBeingHeardIsNotSighted() throws {
            let rig = try LoopRig()
            rig.start()
            try rig.fake.add(device: LoopRig.peerPath, FakeBlueZ.device(address: LoopRig.peerAddress, advert: LoopRig.advert()))
            rig.settle { rig.events.count == 3 }
            let payload = DBusValue.properties([
                ("ServiceData", .properties([(AdvertPayload.serviceUUID, .bytes(LoopRig.advert(8).bytes))]))
            ])
            try rig.fake.change(LoopRig.peerPath, interface: BlueZ.deviceInterface, payload, invalidated: ["RSSI"])
            rig.turn()
            #expect(rig.events.count == 3, "no strength, no sighting")
        }

        @Test func devicesElsewhereOrWithoutAKnitAdvertAreNotSighted() throws {
            let rig = try LoopRig()
            rig.start()
            try rig.fake.add(device: LoopRig.otherPath, FakeBlueZ.device(address: "11:22:33:44:55:66", advert: LoopRig.advert()))
            try rig.fake.change(LoopRig.otherPath, interface: BlueZ.deviceInterface, .properties([("RSSI", .int16(-40))]))
            try rig.fake.add(device: LoopRig.peerPath, FakeBlueZ.device(address: LoopRig.peerAddress, advert: nil))
            try rig.fake.change(FakeBlueZ.adapter, interface: BlueZ.adapterInterface, .properties([("Discovering", .boolean(true))]))
            try rig.fake.change(LoopRig.peerPath, interface: "org.bluez.MediaControl1", .properties([("Connected", .boolean(true))]))
            rig.turn()
            #expect(rig.events == [.state(.on), .listening(psm: UnixSockets.psm)])
        }

        @Test func nothingIsSightedWhileTheRadioIsDown() throws {
            let rig = try LoopRig()
            rig.loop.connect(now: Monotonic.milliseconds())
            rig.turn()
            try rig.fake.add(device: LoopRig.peerPath, FakeBlueZ.device(address: LoopRig.peerAddress, advert: LoopRig.advert()))
            rig.turn()
            #expect(rig.events.isEmpty)
        }

        @Test func aRemovedDeviceCannotBeDialed() throws {
            let rig = try LoopRig()
            rig.start()
            try rig.fake.add(device: LoopRig.peerPath, FakeBlueZ.device(address: LoopRig.peerAddress, advert: LoopRig.advert()))
            rig.settle { rig.loop.devices[LoopRig.peerPath] != nil }
            try rig.fake.remove(LoopRig.peerPath, interfaces: [BlueZ.deviceInterface])
            rig.settle { rig.loop.devices[LoopRig.peerPath] == nil }
            let id = rig.mailbox.nextChannel()
            rig.post(.dial(id, RadioAddress(LoopRig.peerPath), psm: UnixSockets.psm))
            rig.settle { rig.events.last == .dialFailed(id) }
        }

        @Test func aDeviceBlueZAlreadyKnewIsADialTargetButNotASighting() throws {
            let rig = try LoopRig()
            rig.fake.knownDevices[LoopRig.peerPath] = FakeBlueZ.device(address: LoopRig.peerAddress, advert: LoopRig.advert())
            let listener = try RemoteListener(for: try LoopRig.target(), psm: UnixSockets.psm, in: rig.sockets.directory)
            rig.start()
            #expect(rig.events == [.state(.on), .listening(psm: UnixSockets.psm)])
            let id = rig.mailbox.nextChannel()
            rig.post(.dial(id, RadioAddress(LoopRig.peerPath), psm: UnixSockets.psm))
            rig.settle { rig.events.last == .connected(id) }
            #expect(listener.accept() != nil)
        }
    }
#endif
