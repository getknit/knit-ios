#if os(Linux)
    @testable import KnitBlueZ
    import KnitMesh
    import KnitWire
    import Testing

    /// Ringing a peer's doorbell over the link its channel uses: a write without response to the doorbell BlueZ
    /// found on the device at the channel's other end, once BlueZ has read that device's services.
    @Suite(.timeLimit(.minutes(1))) struct BlueZDoorbellTests {
        private static let doorbell = RemoteGattObjects.doorbellPath(of: LoopRig.peerPath)

        /// A peer that dialed us, with a channel open, and its device linked as bluetoothd links it.
        private struct Dialed {
            let rig: LoopRig
            let remote: RemoteEnd
            let id: ChannelID
        }

        private func dialedBy(doorbell: Bool = true, resolved: Bool = true) throws -> Dialed {
            let rig = try LoopRig(acceptedPeer: try LoopRig.target())
            rig.start()
            rig.fake.remoteGatt[LoopRig.peerPath] = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue, doorbell: doorbell)
            let remote = try RemoteEnd.dial(rig.sockets)
            rig.settle { rig.lastAccepted != nil }
            if resolved {
                try rig.fake.holdLink(LoopRig.peerPath)
            } else {
                try rig.fake.holdLinkUnresolved(LoopRig.peerPath)
            }
            rig.turn()
            return Dialed(rig: rig, remote: remote, id: try #require(rig.lastAccepted))
        }

        @Test func aRingWritesTheDoorbellWithoutAResponse() throws {
            let dialed = try dialedBy()
            let (rig, remote, id) = (dialed.rig, dialed.remote, dialed.id)
            rig.post(.ring(id))
            rig.settle { rig.fake.writes.count == 1 }
            #expect(rig.fake.writes == [FakeBlueZ.Write(path: Self.doorbell, value: [1], type: "command")])
            remote.hangUp()
        }

        @Test func theDoorbellIsLookedUpOnce() throws {
            let dialed = try dialedBy()
            let (rig, remote, id) = (dialed.rig, dialed.remote, dialed.id)
            rig.post(.ring(id))
            rig.settle { rig.fake.writes.count == 1 }
            let lookups = rig.fake.calls.filter { $0 == "org.freedesktop.DBus.ObjectManager.GetManagedObjects" }.count
            rig.post(.ring(id))
            rig.settle { rig.fake.writes.count == 2 }
            #expect(rig.fake.calls.filter { $0 == "org.freedesktop.DBus.ObjectManager.GetManagedObjects" }.count == lookups)
            remote.hangUp()
        }

        @Test func aRingWaitsForBlueZToReadTheServices() throws {
            let dialed = try dialedBy(resolved: false)
            let (rig, remote, id) = (dialed.rig, dialed.remote, dialed.id)
            rig.post(.ring(id))
            rig.post(.ring(id))
            rig.turn()
            #expect(rig.fake.writes.isEmpty)
            try rig.fake.resolve(LoopRig.peerPath)
            rig.settle { rig.fake.writes.count == 1 }
            rig.turn()
            #expect(rig.fake.writes.count == 1, "the rings waiting were one")
            remote.hangUp()
        }

        @Test func aPeerWithoutADoorbellIsNeverWritten() throws {
            let dialed = try dialedBy(doorbell: false)
            let (rig, remote, id) = (dialed.rig, dialed.remote, dialed.id)
            rig.post(.ring(id))
            rig.settle { rig.log.all.contains { $0.contains("found no doorbell") } }
            rig.post(.ring(id))
            rig.turn()
            #expect(rig.fake.writes.isEmpty)
            remote.hangUp()
        }

        @Test func aLinkThatDropsForgetsItsDoorbell() throws {
            let dialed = try dialedBy()
            let (rig, remote, id) = (dialed.rig, dialed.remote, dialed.id)
            rig.post(.ring(id))
            rig.settle { rig.fake.writes.count == 1 }
            try rig.fake.change(LoopRig.peerPath, interface: BlueZ.deviceInterface, .properties([("ServicesResolved", .boolean(false))]))
            rig.turn()
            #expect(rig.loop.doorbells.isEmpty)
            remote.hangUp()
        }

        @Test func aChannelWithNoDeviceRingsNothing() throws {
            let rig = try LoopRig()
            rig.start()
            rig.post(.ring(ChannelID(99)))
            rig.turn()
            #expect(rig.fake.writes.isEmpty)
        }
    }
#endif
