#if os(Linux)
    @testable import KnitBlueZ
    import KnitMesh
    import KnitTestSupport
    import KnitWire
    import Testing

    /// How long the radio's own GATT read may run, against the fake BlueZ (ADR 2026-09.xzpt): 20 s, where the shared pacing
    /// that KnitBLE reads keeps 12. A read's services are left unresolved, and the loop is handed a clock 14 s on.
    @Suite(.timeLimit(.minutes(1))) struct BlueZGattReadTimeoutTests {
        private static func reading(_ gatt: GattPayloads.Configuration) throws -> LoopRig {
            let rig = try LoopRig(profile: .ios, readsGattPayloads: true, gatt: gatt)
            rig.start()
            var remote = FakeBlueZ.RemoteGatt(value: LoopRig.advert().gattValue)
            remote.resolves = false
            rig.fake.remoteGatt[LoopRig.peerPath] = remote
            try rig.fake.add(device: LoopRig.peerPath, LoopRig.uuidOnlyDevice())
            rig.settle { rig.loop.gattStage == .resolving }
            return rig
        }

        private static func sightings(_ rig: LoopRig) -> [AdvertPayload] {
            rig.events.compactMap { if case .sighted(let sighting) = $0 { sighting.advert } else { nil } }
        }

        /// The radio's own read may take 20 s, the shared pacing 12 (``BlueZLoop/Configuration/readPacing``): under BlueZ an
        /// iPhone's services resolved 10.1 and 13.05 s into a read (`.agents/context/linux-peer.md`, "Its trial did not
        /// reach the window"). The loop is handed a clock 14 s on rather than waited 14 s for.
        @Test func aReadWhoseServicesResolveFourteenSecondsInStillReads() throws {
            #expect(BlueZLoop.Configuration.readPacing.readTimeoutMilliseconds == 20_000)
            let rig = try Self.reading(BlueZLoop.Configuration.readPacing)
            let built = BlueZLoop.Configuration(
                bus: .peer(rig.fake.address),
                adapter: try AdapterSelection(name: "hci1", expectedAddress: FakeBlueZ.adapterAddress, shared: false),
                profile: .ios,
                sockets: rig.sockets,
                objectRoot: "/app/getknit/test",
                log: rig.log
            )
            #expect(built.gatt.readTimeoutMilliseconds == 20_000, "what BlueZRadio and knit-peer read")
            rig.loop.expireGattRead(now: Monotonic.milliseconds() + 14_000)
            #expect(rig.loop.gatt.current != nil, "inside its 20 s")
            #expect(!rig.log.all.contains { $0.contains("could not read the GATT payload") })
            try rig.fake.resolve(LoopRig.peerPath)
            rig.settle { Self.sightings(rig) == [LoopRig.gattAdvert()] }
        }

        /// The shared pacing keeps its 12 s, which KnitBLE reads; a read given up there names the stage it stopped in.
        @Test func theSharedPacingGivesUpAtTwelveSecondsNamingTheStage() throws {
            let shared = GattPayloads.Configuration()
            #expect(shared.readTimeoutMilliseconds == 12_000)
            let own = BlueZLoop.Configuration.readPacing
            #expect(own.retryMilliseconds == shared.retryMilliseconds)
            #expect(own.strangerRetryMilliseconds == shared.strangerRetryMilliseconds)
            #expect(own.quietMilliseconds == shared.quietMilliseconds)
            let rig = try Self.reading(shared)
            rig.loop.expireGattRead(now: Monotonic.milliseconds() + 14_000)
            #expect(rig.loop.gatt.current == nil)
            let line = "bluez could not read the GATT payload of dev_4A_00_00_00_00_EF: it took longer than 12000 ms (resolving services)"
            #expect(rig.log.all.contains { $0.hasSuffix(line) })
        }
    }
#endif
