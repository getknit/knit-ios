#if os(Linux)
    @testable import KnitBlueZ
    import KnitMesh
    import KnitWire
    import Testing

    /// Channels on Unix sockets that keep L2CAP's message boundaries: dials, accepts, bytes both ways, and closes.
    @Suite(.timeLimit(.minutes(1))) struct BlueZChannelTests {
        @Test func aDialToASightedDeviceOpens() throws {
            let rig = try LoopRig()
            rig.start()
            let listener = try RemoteListener(for: try LoopRig.target(), psm: UnixSockets.psm, in: rig.sockets.directory)
            let (id, _) = try rig.dialPeer(listener)
            #expect(rig.loop.channels[id]?.connecting == false)
        }

        @Test func writesGoOutInSlicesTheChannelTakes() throws {
            let rig = try LoopRig(limit: 100)
            rig.start()
            let listener = try RemoteListener(for: try LoopRig.target(), psm: UnixSockets.psm, in: rig.sockets.directory)
            let (id, remote) = try rig.dialPeer(listener)
            let record = [UInt8](repeating: 0xAB, count: 250)
            rig.post(.write(id, record))
            rig.turn(3)
            #expect(remote.receive()?.count == 100)
            #expect(remote.receive()?.count == 100)
            #expect(remote.receive()?.count == 50)
        }

        @Test func whatThePeerSendsArrivesInOrder() throws {
            let rig = try LoopRig()
            rig.start()
            let listener = try RemoteListener(for: try LoopRig.target(), psm: UnixSockets.psm, in: rig.sockets.directory)
            let (id, remote) = try rig.dialPeer(listener)
            remote.send([1, 2, 3])
            remote.send([4, 5])
            rig.settle { rig.received(on: id) == [1, 2, 3, 4, 5] }
        }

        @Test func thePeerHangingUpClosesTheChannel() throws {
            let rig = try LoopRig()
            rig.start()
            let listener = try RemoteListener(for: try LoopRig.target(), psm: UnixSockets.psm, in: rig.sockets.directory)
            let (id, remote) = try rig.dialPeer(listener)
            remote.hangUp()
            rig.settle { rig.events.last == .closed(id) }
            #expect(rig.loop.channels[id] == nil)
        }

        @Test func aPeerThatDialsUsIsAcceptedAndHeard() throws {
            let rig = try LoopRig()
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            let id = try #require(rig.lastAccepted)
            remote.send(Array("hello".utf8))
            rig.settle { rig.received(on: id) == Array("hello".utf8) }
            rig.post(.write(id, [9, 9]))
            rig.turn(3)
            #expect(remote.receive() == [9, 9])
        }

        @Test func closingAChannelReportsItClosedAndHangsUp() throws {
            let rig = try LoopRig()
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            let id = try #require(rig.lastAccepted)
            rig.post(.close(id))
            rig.settle { rig.events.last == .closed(id) }
            #expect(remote.sawEnd())
            rig.post(.close(id))
            rig.post(.write(id, [1]))
            rig.turn()
            #expect(rig.events.filter { $0 == .closed(id) }.count == 1, "a second close finds nothing")
        }

        @Test func aDialToAnUnknownDeviceFails() throws {
            let rig = try LoopRig()
            rig.start()
            let id = rig.mailbox.nextChannel()
            rig.post(.dial(id, RadioAddress(LoopRig.peerPath), psm: UnixSockets.psm))
            rig.settle { rig.events.last == .dialFailed(id) }
        }

        @Test func aDialNobodyAnswersFails() throws {
            let rig = try LoopRig()
            rig.start()
            try rig.fake.add(device: LoopRig.peerPath, FakeBlueZ.device(address: LoopRig.peerAddress, advert: LoopRig.advert()))
            rig.settle { rig.loop.devices[LoopRig.peerPath] != nil }
            let id = rig.mailbox.nextChannel()
            rig.post(.dial(id, RadioAddress(LoopRig.peerPath), psm: UnixSockets.psm))
            rig.settle { rig.events.last == .dialFailed(id) }
            #expect(rig.log.all.contains { $0.contains("dial \(id) failed") })
        }

        @Test func aDeviceWithoutAnAddressCannotBeDialed() throws {
            let rig = try LoopRig()
            rig.start()
            try rig.fake.add(device: LoopRig.peerPath, .properties([("RSSI", .int16(-50))]))
            rig.settle { rig.loop.devices[LoopRig.peerPath] != nil }
            let id = rig.mailbox.nextChannel()
            rig.post(.dial(id, RadioAddress(LoopRig.peerPath), psm: UnixSockets.psm))
            rig.settle { rig.events.last == .dialFailed(id) }
        }

        @Test func aDialWhileTheRadioIsDownFails() throws {
            let rig = try LoopRig()
            let id = rig.mailbox.nextChannel()
            rig.post(.dial(id, RadioAddress(LoopRig.peerPath), psm: UnixSockets.psm))
            rig.turn(2)
            #expect(rig.events == [.dialFailed(id)])
        }

        @Test func aPeerThatStopsReadingIsCut() throws {
            let rig = try LoopRig(limit: 60_000)
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            let id = try #require(rig.lastAccepted)
            for _ in 0..<80 {
                rig.post(.write(id, [UInt8](repeating: 1, count: 60_000)))
            }
            rig.settle("never cut") { rig.events.last == .closed(id) }
            #expect(rig.log.all.contains { $0.contains("stopped reading") })
            _ = remote
        }

        @Test func goingDownClosesEveryChannelQuietly() throws {
            let rig = try LoopRig()
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            try rig.fake.setPowered(false)
            rig.settle { rig.events.last == .state(.off) }
            #expect(rig.loop.channels.isEmpty)
            #expect(remote.sawEnd())
        }

        // MARK: Letting go of links

        @Test func closingTheLastChannelToADeviceDropsItsLink() throws {
            let rig = try LoopRig()
            rig.start()
            let listener = try RemoteListener(for: try LoopRig.target(), psm: UnixSockets.psm, in: rig.sockets.directory)
            let (id, remote) = try rig.dialPeer(listener)
            rig.post(.close(id))
            rig.settle { rig.fake.disconnected == [LoopRig.peerPath] }
            rig.settle { rig.log.all.contains("bluez disconnect \(LoopRig.peerPath): done") }
            _ = remote
        }

        @Test func noLinkIsDroppedOffThisAdapter() throws {
            let rig = try LoopRig()
            rig.start()
            rig.loop.dropLink(to: LoopRig.otherPath, now: Monotonic.milliseconds())
            rig.loop.dropLink(to: FakeBlueZ.adapter, now: Monotonic.milliseconds())
            rig.turn()
            #expect(rig.fake.disconnected.isEmpty, "hci0's devices, and the adapter itself, are never asked to disconnect")
        }

        @Test func aPeerHangingUpDropsItsLinkToo() throws {
            let rig = try LoopRig()
            rig.start()
            let listener = try RemoteListener(for: try LoopRig.target(), psm: UnixSockets.psm, in: rig.sockets.directory)
            let (_, remote) = try rig.dialPeer(listener)
            remote.hangUp()
            rig.settle { rig.fake.disconnected == [LoopRig.peerPath] }
        }

        @Test func aDeviceWithTwoChannelsKeepsItsLinkUntilBothClose() throws {
            let rig = try LoopRig()
            rig.start()
            let listener = try RemoteListener(for: try LoopRig.target(), psm: UnixSockets.psm, in: rig.sockets.directory)
            let (first, firstRemote) = try rig.dialPeer(listener)
            let second = rig.mailbox.nextChannel()
            rig.post(.dial(second, RadioAddress(LoopRig.peerPath), psm: UnixSockets.psm))
            rig.settle { rig.events.contains(.connected(second)) }
            let secondRemote = try #require(listener.accept())
            rig.post(.close(first))
            rig.settle { rig.events.contains(.closed(first)) }
            rig.turn()
            #expect(rig.fake.disconnected.isEmpty)
            rig.post(.close(second))
            rig.settle { rig.fake.disconnected == [LoopRig.peerPath] }
            _ = (firstRemote, secondRemote)
        }

        @Test func aPeerThatDialedUsIsLetGoByItsAddress() throws {
            let rig = try LoopRig(acceptedPeer: try LoopRig.target())
            rig.start()
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            let id = try #require(rig.lastAccepted)
            rig.post(.close(id))
            rig.settle { rig.fake.disconnected == [LoopRig.peerPath] }
            _ = remote
        }

        @Test func goingDownLetsGoOfEveryLinkWithAChannel() throws {
            let rig = try LoopRig()
            rig.start()
            let listener = try RemoteListener(for: try LoopRig.target(), psm: UnixSockets.psm, in: rig.sockets.directory)
            let (_, remote) = try rig.dialPeer(listener)
            rig.post(.stop)
            rig.settle { rig.fake.disconnected == [LoopRig.peerPath] }
            _ = remote
        }

        @Test func aLinkLeftFromBeforeIsDroppedAtStart() throws {
            let rig = try LoopRig()
            rig.fake.knownDevices[LoopRig.peerPath] = .properties([
                ("Address", .string(LoopRig.peerAddress)), ("Connected", .boolean(true)),
            ])
            rig.fake.knownDevices[LoopRig.peerPath + "0"] = FakeBlueZ.device(address: "4A:00:00:00:00:E0", advert: nil)
            rig.start()
            rig.settle { rig.fake.disconnected == [LoopRig.peerPath] }
            #expect(rig.log.all.contains { $0.contains("left from before") })
        }
    }
#endif
