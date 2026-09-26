import KnitMesh
import KnitStore
import KnitWire
import Testing

/// The actor that runs the engine and the link manager on a radio.
@Suite(.timeLimit(.minutes(1))) struct MeshTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let channel = ChannelID(50)

    private struct Rig {
        let mesh: Mesh
        let radio: FakeRadio
        let clock: ManualClock
        let stores: MeshStores
    }

    private func rig() -> Rig {
        let radio = FakeRadio(advertisesServiceData: false)
        let clock = ManualClock(wall: EngineFixture.start, monotonic: 1000)
        let stores = MeshStores.inMemory()
        let mesh = Mesh(
            identity: alice.keys,
            deviceTag: nil,
            stores: stores,
            radio: radio,
            clock: clock,
            random: SeededGenerator(seed: 11),
            log: RecordingLog()
        )
        return Rig(mesh: mesh, radio: radio, clock: clock, stores: stores)
    }

    private func hello(_ peer: TestPeer) -> [UInt8] {
        LinkRecord(.hello, payload: Hello(nodeId: peer.nodeId.string, capabilities: 0xFFF).payload).encoded ?? []
    }

    /// Links `bob` as a dialer we never sighted.
    private func linkBob(_ rig: Rig) async {
        await rig.mesh.process(.accepted(channel))
        await rig.mesh.process(.received(channel, hello(bob)))
    }

    @Test func startingStartsTheRadioAndSeedsOurProfile() async {
        let rig = rig()
        await rig.mesh.start()
        #expect(rig.radio.started)
        #expect(rig.mesh.nodeId == alice.nodeId)
        #expect(rig.stores.custody.liveIds(now: EngineFixture.start) == ["profile-\(alice.nodeId)-\(EngineFixture.start)"])
    }

    @Test func aDialerIsLinkedAndGetsOurHelloProfileAndDigest() async {
        let rig = rig()
        await rig.mesh.start()
        await rig.mesh.process(.listening(psm: 0x81))
        #expect(rig.radio.advertised.last?.psm == 0x81)
        let cue = UInt32(truncatingIfNeeded: rig.stores.custody.fingerprint(now: EngineFixture.start))
        #expect(rig.radio.advertised.last?.digestCue == cue)
        await linkBob(rig)
        #expect(await rig.mesh.neighbors.map(\.nodeId) == [bob.nodeId])
        #expect(rig.radio.records(on: channel).map(\.tag) == [.hello, .frame, .digest])
    }

    @Test func theRadiosOwnStreamDrivesTheMesh() async {
        let rig = rig()
        await rig.mesh.start()
        rig.radio.emit(.accepted(channel))
        rig.radio.emit(.received(channel, hello(bob)))
        var linked: [Neighbor] = []
        for await event in rig.mesh.events {
            if case .neighborsChanged(let neighbors) = event, !neighbors.isEmpty {
                linked = neighbors
                break
            }
        }
        #expect(linked.map(\.nodeId) == [bob.nodeId])
    }

    @Test func theNextDeadlineFiresWhenTheClockReachesIt() async {
        let rig = rig()
        await rig.mesh.start()
        await linkBob(rig)
        var activity = rig.radio.activity.makeAsyncIterator()
        rig.clock.advance(60_000)
        var digests = 0
        while digests < 2, let next = await activity.next() {
            if case .wrote(let id, let bytes) = next, id == channel, bytes.first == LinkRecord.Tag.digest.rawValue {
                digests += 1
            }
        }
        #expect(digests == 2, "the link-up digest, then the 60-second one")
    }

    @Test func aCustodyChangeIsReAdvertisedOnceItSettles() async {
        let rig = rig()
        await rig.mesh.start()
        await rig.mesh.process(.listening(psm: 0x81))
        await rig.mesh.postToRoom("Changes custody")
        let cue = UInt32(truncatingIfNeeded: rig.stores.custody.fingerprint(now: EngineFixture.start))
        var activity = rig.radio.activity.makeAsyncIterator()
        rig.clock.advance(1500)
        var readvertised: AdvertPayload?
        while readvertised == nil, let next = await activity.next() {
            if case .advertised(let payload) = next, payload.digestCue == cue {
                readvertised = payload
            }
        }
        #expect(readvertised?.psm == 0x81)
    }

    @Test func theAppsSendsGoOutOverTheLinks() async throws {
        let rig = rig()
        await rig.mesh.start()
        await linkBob(rig)
        let post = try #require(await rig.mesh.postToRoom("Hello"))
        let ids = rig.radio.frames(on: channel).compactMap { try? RelayEnvelope(decoding: $0.signed).id }
        #expect(ids.contains(post.id))
        #expect(await rig.mesh.sendDirectMessage("Waits for a key", to: bob.nodeId)?.pendingKey == true)
        await rig.mesh.accept(bob.nodeId.string)
        #expect(rig.stores.conversations.acceptedConversations() == [bob.nodeId.string])
        await rig.mesh.updateProfile(name: "Alice", status: "", openToChat: false)
        #expect(rig.stores.ownProfile.load().name == "Alice")
    }

    @Test func framesAndDigestsFromALinkReachTheEngine() async throws {
        let rig = rig()
        let carried = try TestPeer(seed: 3).roomPost("Carried for others", id: "carried-1", sentAt: EngineFixture.start)
        let frame = CarriedFrame(envelope: carried.envelope, sig: carried.wire.sig, signed: carried.wire.signed)
        rig.stores.custody.store(frame, origin: .relayed, now: EngineFixture.start)
        await rig.mesh.start()
        await linkBob(rig)
        let profile = try bob.profile(publishedAt: EngineFixture.start)
        await rig.mesh.process(.received(channel, LinkRecord(.frame, payload: profile.wire.encoded).encoded ?? []))
        #expect(rig.stores.peers.peer(bob.nodeId) != nil)
        let digest = LinkRecord(.digest, payload: LinkJSON.digestPayload(ids: [])).encoded ?? []
        await rig.mesh.process(.received(channel, digest))
        let ids = rig.radio.frames(on: channel).compactMap { try? RelayEnvelope(decoding: $0.signed).id }
        // Our profile and Bob's own already crossed this link, so the answer carries only what it has not.
        #expect(ids == ["profile-\(alice.nodeId)-\(EngineFixture.start)", "carried-1"])
        #expect(await rig.mesh.dropped.isEmpty)
    }

    @Test func stoppingTakesTheLinksDownAndStopsTheRadio() async {
        let rig = rig()
        await rig.mesh.start()
        await linkBob(rig)
        await rig.mesh.stop()
        #expect(rig.radio.stopped)
        #expect(rig.radio.closed == [channel])
        #expect(await rig.mesh.neighbors.isEmpty)
        #expect(await rig.mesh.sightings.isEmpty)
    }

    @Test func aStoppedMeshStartsAgainOnTheSameRadio() async {
        let rig = rig()
        await rig.mesh.start()
        await rig.mesh.stop()
        await rig.mesh.stop()
        #expect(await !rig.mesh.isRunning, "stopping a stopped mesh changes nothing")
        await rig.mesh.postToRoom("Waits in custody")
        #expect(rig.clock.sleeperCount == 0, "a stopped mesh sets no timer")
        await rig.mesh.start()
        #expect(await rig.mesh.isRunning)
        rig.radio.emit(.accepted(channel))
        rig.radio.emit(.received(channel, hello(bob)))
        for await event in rig.mesh.events {
            if case .neighborsChanged(let neighbors) = event, !neighbors.isEmpty {
                break
            }
        }
        #expect(await rig.mesh.neighbors.map(\.nodeId) == [bob.nodeId], "the radio's stream still reaches the mesh")
    }

    @Test func theRadiosStateIsKeptAndReportedWhileStopped() async {
        let rig = rig()
        #expect(await rig.mesh.radioState == nil)
        await rig.mesh.process(.state(.unauthorized))
        await rig.mesh.process(.state(.unauthorized))
        await rig.mesh.start()
        await rig.mesh.process(.state(.on))
        var reported: [RadioState] = []
        for await event in rig.mesh.events {
            if case .radioChanged(let state) = event {
                reported.append(state)
            }
            if reported.count == 2 {
                break
            }
        }
        #expect(reported == [.unauthorized, .on], "a repeat says nothing new")
        #expect(await rig.mesh.radioState == .on)
    }

    @Test func aPinnedPeerIsVerifiedThroughTheMesh() async throws {
        let rig = rig()
        await rig.mesh.start()
        await linkBob(rig)
        let profile = try bob.profile(publishedAt: EngineFixture.start)
        await rig.mesh.process(.received(channel, LinkRecord(.frame, payload: profile.wire.encoded).encoded ?? []))
        await rig.mesh.setVerified(bob.nodeId, true)
        #expect(rig.stores.peers.verifiedNodeIds() == [bob.nodeId])
        await rig.mesh.setVerified(alice.nodeId, true)
        #expect(rig.stores.peers.verifiedNodeIds() == [bob.nodeId], "our own id has no pinned key")
        var updates = 0
        for await event in rig.mesh.events {
            if case .peerUpdated(let peer) = event, peer == bob.nodeId {
                updates += 1
            }
            if updates == 2 {
                break
            }
        }
        #expect(updates == 2, "the pin, then the verification")
    }

    @Test func aRefusedPeerIsCutAndKeptOutUntilPermitted() async {
        let rig = rig()
        await rig.mesh.start()
        await linkBob(rig)
        await rig.mesh.refuseLinks(with: bob.nodeId)
        #expect(await rig.mesh.neighbors.isEmpty)
        #expect(rig.radio.closed == [channel])
        await linkBob(rig)
        #expect(await rig.mesh.neighbors.isEmpty, "its next dial is closed at the HELLO")
        await rig.mesh.permitLinks(with: bob.nodeId)
        await rig.mesh.process(.accepted(ChannelID(51)))
        await rig.mesh.process(.received(ChannelID(51), hello(bob)))
        #expect(await rig.mesh.neighbors.map(\.nodeId) == [bob.nodeId])
    }

    @Test func startingTwiceStartsOnce() async {
        let rig = rig()
        await rig.mesh.start()
        await rig.mesh.start()
        #expect(rig.stores.custody.liveIds(now: EngineFixture.start).count == 1)
    }

    @Test func anEventBeforeStartSchedulesNothing() async {
        let rig = rig()
        await rig.mesh.process(.listening(psm: 0x81))
        #expect(rig.radio.advertised.isEmpty, "the links are not running yet")
        #expect(rig.clock.sleeperCount == 0)
    }
}
