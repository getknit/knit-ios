import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The profile cap at the engine's door (ADR 2026-10.r88m, contract `profile-door-cap` sections 1, 2, 4 and 5), beside
/// ``MeshEngineProfileTests``: a profile whose `signed` is longer than custody's profile cap is refused before it is read,
/// whatever path brought it, and still relayed; one of exactly the cap pins.
@Suite struct MeshEngineProfileCapTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)

    private static let cap = CustodyLimits().maxProfileSignedBytes
    /// Long enough for a relay's jitter to pass.
    private static let hop = Router.Configuration().jitterWindowMilliseconds + 1

    private struct NoPadding: Error {}

    /// `peer`'s profile padded in `status` until its `signed` is exactly `length` bytes, stamped `publishedAt`.
    private func profile(of peer: TestPeer, signed length: Int, publishedAt: Int64, relay: Bool = true) throws -> TestFrame {
        let bare = try peer.profile(publishedAt: publishedAt, relay: relay).wire.signed.count
        // The status's CBOR head grows by up to two bytes past 255 and 65,535 characters, so the pad is found by trying.
        for pad in stride(from: length - bare, through: max(0, length - bare - 4), by: -1) {
            let frame = try peer.profile(status: String(repeating: "s", count: pad), publishedAt: publishedAt, relay: relay)
            if frame.wire.signed.count == length {
                return frame
            }
        }
        throw NoPadding()
    }

    /// `frame` as `fixture`'s engine relayed it to `peer`, if it did.
    private func relayed(_ frame: TestFrame, by fixture: EngineFixture, to peer: TestPeer) -> Written? {
        fixture.transport.written(frame.envelope.type).first { $0.to == peer.nodeId && $0.envelope.id == frame.envelope.id }
    }

    /// The door refused `frame`: nothing pinned, kept, cached or carried, and not read as a missing key, `keyless` being the
    /// frames before it that were.
    private func expectRefused(
        _ frame: TestFrame, by fixture: EngineFixture, count: Int, keyless: Int? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let sender = bob.nodeId
        #expect(fixture.stores.peers.peer(sender) == nil, "no pin", sourceLocation: sourceLocation)
        #expect(fixture.stores.peers.profileFrame(of: sender) == nil, "no proof of key", sourceLocation: sourceLocation)
        #expect(fixture.engine.keyExchange.cachedProfile(of: sender) == nil, "not cached", sourceLocation: sourceLocation)
        #expect(fixture.engine.footprint.cachedProfiles == 0, sourceLocation: sourceLocation)
        #expect(!fixture.stores.custody.contains(frame.envelope.id), "not carried", sourceLocation: sourceLocation)
        #expect(fixture.engine.dropped[.noSenderKey] == keyless, "never read as a missing key", sourceLocation: sourceLocation)
        #expect(fixture.engine.custody.profileOversizeRefusedCount == 0, "custody never saw it", sourceLocation: sourceLocation)
        #expect(fixture.engine.profileOversizeRefused == count, sourceLocation: sourceLocation)
        let length = frame.wire.signed.count
        let line = "debug mesh refused \(frame.envelope.id.prefix(8)) (profile): \(length) signed bytes over the profile cap"
        #expect(fixture.log.all.contains(line), sourceLocation: sourceLocation)
    }

    // MARK: The edge

    @Test func aProfileOfExactlyTheCapPinsWithItsStatusCut() throws {
        let fixture = EngineFixture(alice)
        let frame = try profile(of: bob, signed: Self.cap, publishedAt: EngineFixture.start)
        fixture.deliver(frame, from: bob)
        let record = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(record.status.utf16.count == TextLimits.status, "the stored status is cut; the proof stays verbatim")
        #expect(fixture.stores.peers.profileFrame(of: bob.nodeId)?.signed == frame.wire.signed)
        #expect(fixture.engine.keyExchange.cachedProfile(of: bob.nodeId) != nil)
        #expect(fixture.stores.custody.contains(frame.envelope.id))
        #expect(fixture.engine.profileOversizeRefused == 0)
    }

    @Test func aProfileOneByteOverIsRefusedAtTheDoorAndStillRelayed() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol, dave)
        fixture.transport.clear()
        let frame = try profile(of: bob, signed: Self.cap + 1, publishedAt: EngineFixture.start)
        fixture.deliver(frame, from: carol)
        expectRefused(frame, by: fixture, count: 1)
        #expect(fixture.transport.written(.keyRequest).isEmpty, "a profile carries its own key")
        #expect(fixture.engine.footprint.parked == 0)
        fixture.advance(Self.hop)
        let relayed = fixture.transport.written(.profile).filter { $0.envelope.id == frame.envelope.id }
        #expect(relayed.map(\.to) == [dave.nodeId], "the router relays it whatever the door decided")
        #expect(relayed.first?.wire.signed == frame.wire.signed)
    }

    @Test func aPointToPointAnswerOverTheCapIsRefusedTheSameWay() throws {
        // A key request's answer arrives with relay = false, and custody would carry it even so (ADR 2026-09.7bu7).
        let fixture = EngineFixture(alice)
        let frame = try profile(of: bob, signed: Self.cap + 1, publishedAt: EngineFixture.start, relay: false)
        fixture.deliver(frame, from: carol)
        expectRefused(frame, by: fixture, count: 1)
    }

    @Test func theDoorReadsCustodysConfiguredCap() throws {
        // A rig that lowers custody's cap lowers the door's: a door with its own 8,192 would pin the first of these.
        let lowered = 1024
        let fixture = EngineFixture(alice, stores: .inMemory(custodyLimits: CustodyLimits(maxProfileSignedBytes: lowered)))
        let over = try profile(of: bob, signed: lowered + 1, publishedAt: EngineFixture.start)
        fixture.deliver(over, from: carol)
        expectRefused(over, by: fixture, count: 1)
        let at = try profile(of: bob, signed: lowered, publishedAt: EngineFixture.start + 1)
        fixture.deliver(at, from: carol)
        #expect(fixture.stores.peers.peer(bob.nodeId) != nil)
        #expect(fixture.engine.profileOversizeRefused == 1)
    }

    // MARK: What waits for the key

    @Test func aParkedChatWaitsThroughAnOverCapProfileAndLandsOnAnInCapOne() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        let chat = try bob.directMessage("hello", to: alice, id: frameIdOf("parked-dm"), sentAt: EngineFixture.start)
        fixture.deliver(chat, from: carol)
        #expect(fixture.engine.footprint.parked == 1)
        let droppedBefore = fixture.engine.dropped
        fixture.transport.clear()
        fixture.deliver(try profile(of: bob, signed: Self.cap + 1, publishedAt: EngineFixture.start), from: carol)
        #expect(fixture.engine.footprint.parked == 1, "still parked")
        #expect(fixture.stores.messages.message(chat.envelope.id) == nil, "nothing released")
        #expect(fixture.transport.written(.keyRequest).isEmpty, "no key asked for")
        #expect(fixture.engine.dropped == droppedBefore, "the refusal is no drop")
        #expect(fixture.engine.profileOversizeRefused == 1)
        fixture.deliver(try profile(of: bob, signed: Self.cap, publishedAt: EngineFixture.start + 1), from: carol)
        #expect(fixture.stores.messages.message(chat.envelope.id) != nil, "an in-cap profile releases it")
        #expect(fixture.engine.footprint.parked == 0)
    }

    // MARK: Two engines

    @Test func aCarrierWithoutTheCapFloodsAndServesAnOverCapProfileAndNeitherPins() throws {
        // Carol stands for a build without the profile cap: her custody and her proofs hold anything under the byte cap.
        // Bob, the author, never serves his own key on request, so the answer comes from a carrier, as on the air.
        let lifted = CustodyLimits(maxProfileSignedBytes: CustodyLimits().maxSignedBytes)
        let carols = EngineFixture(carol, stores: .inMemory(custodyLimits: lifted), seed: 8)
        let alices = EngineFixture(alice)
        carols.link(bob)
        let first = try profile(of: bob, signed: Self.cap + 1, publishedAt: EngineFixture.start)
        carols.deliver(first, from: bob)
        #expect(carols.stores.peers.profileFrame(of: bob.nodeId)?.signed == first.wire.signed, "carol keeps it as proof")
        carols.link(alice)
        alices.link(carol)
        // Alice's own profile, pushed at the link, pins her key at carol, who reads her key request by it.
        let alicesProfile = try #require(alices.transport.written(.profile).first { $0.to == carol.nodeId })
        carols.deliver(TestFrame(wire: alicesProfile.wire, envelope: alicesProfile.envelope), from: alice)

        // A chat of bob's reaches alice, keyless, and she asks carol for his key; carol serves the over-cap profile point to
        // point.
        let chat = try bob.directMessage("hello", to: alice, id: frameIdOf("served-dm"), sentAt: EngineFixture.start)
        alices.deliver(chat, from: carol)
        let request = try #require(alices.transport.written(.keyRequest).last { $0.to == carol.nodeId })
        carols.transport.clear()
        carols.deliver(TestFrame(wire: request.wire, envelope: request.envelope), from: alice)
        let served = try #require(carols.transport.written(.profile).last { $0.to == alice.nodeId })
        #expect(!served.wire.relay && served.wire.signed == first.wire.signed)
        alices.deliver(TestFrame(wire: served.wire, envelope: served.envelope), from: carol)
        expectRefused(first, by: alices, count: 1, keyless: 1)
        #expect(alices.engine.footprint.parked == 1, "the chat still waits")

        // Bob republishes over the cap, and carol floods it on.
        let second = try profile(of: bob, signed: Self.cap + 1, publishedAt: EngineFixture.start + 1)
        carols.transport.clear()
        carols.deliver(second, from: bob)
        carols.advance(Self.hop)
        let flooded = try #require(relayed(second, by: carols, to: alice))
        alices.deliver(TestFrame(wire: flooded.wire, envelope: flooded.envelope), from: carol)
        expectRefused(second, by: alices, count: 2, keyless: 1)

        // The twin at exactly the cap pins, and the chat lands.
        let twin = try profile(of: bob, signed: Self.cap, publishedAt: EngineFixture.start + 2)
        carols.transport.clear()
        carols.deliver(twin, from: bob)
        carols.advance(Self.hop)
        let pinned = try #require(relayed(twin, by: carols, to: alice))
        alices.deliver(TestFrame(wire: pinned.wire, envelope: pinned.envelope), from: carol)
        #expect(alices.stores.peers.peer(bob.nodeId)?.publicKey == bob.keys.bundle.encoded)
        #expect(alices.stores.messages.message(chat.envelope.id) != nil)
        #expect(alices.engine.profileOversizeRefused == 2)
    }

    // MARK: knit-next's frames

    /// Alice's frame `name` from `keyed-v1.json`, Tink-signed by Android, after checking its `signed` is as long as the
    /// file says, so a vector that drifted fails here rather than in the verdict.
    private func keyed(_ name: String, signed length: Int) throws -> (TestFrame, TestPeer) {
        let file = KeyedVectors.file
        let entry = try #require(file.frames[name])
        #expect(entry.signedBytes == length)
        let wire = try WireEnvelope(decoding: try #require(Hex.decode(entry.wire)))
        #expect(wire.signed.count == length)
        let identity = try #require(file.identities[entry.sender])
        let seed = try #require(Hex.decode(identity.signingSeed))
        let scalar = try #require(Hex.decode(identity.agreementScalar))
        let keys = try #require(IdentityKeys(signingSeed: seed, agreementScalar: scalar))
        return (TestFrame(wire: wire, envelope: try RelayEnvelope(decoding: wire.signed)), TestPeer(keys: keys))
    }

    @Test func knitNextsProfileAtTheCapPins() throws {
        let (frame, sender) = try keyed("aliceProfileAtCap", signed: Self.cap)
        let fixture = EngineFixture(bob)
        fixture.deliver(frame, from: sender)
        let record = try #require(fixture.stores.peers.peer(sender.nodeId))
        #expect(record.publicKey == sender.keys.bundle.encoded)
        #expect(record.status.utf16.count == TextLimits.status, "the stored status is cut; the proof stays verbatim")
        #expect(fixture.stores.peers.profileFrame(of: sender.nodeId)?.signed == frame.wire.signed)
        #expect(fixture.engine.profileOversizeRefused == 0)
    }

    @Test func knitNextsProfileOneByteOverIsRefusedAtTheDoor() throws {
        let (frame, sender) = try keyed("aliceProfileOverCap", signed: Self.cap + 1)
        let fixture = EngineFixture(bob)
        fixture.deliver(frame, from: sender)
        #expect(fixture.stores.peers.peer(sender.nodeId) == nil)
        #expect(fixture.stores.peers.profileFrame(of: sender.nodeId) == nil)
        #expect(fixture.engine.keyExchange.cachedProfile(of: sender.nodeId) == nil)
        #expect(!fixture.stores.custody.contains(frame.envelope.id))
        #expect(fixture.engine.dropped[.noSenderKey] == nil)
        #expect(fixture.engine.profileOversizeRefused == 1)
    }

    // MARK: Stored proofs

    @Test func theSweepDeletesAnOverCapProofAndTheCacheNeverServesOne() throws {
        // A pin and its proof kept by a build without the cap.
        let stores = MeshStores.inMemory()
        stores.peers.upsert(PeerRecord(nodeId: bob.nodeId, name: "", status: "", publicKey: bob.keys.bundle.encoded, updatedAt: 1))
        let kept = try profile(of: bob, signed: Self.cap + 1, publishedAt: EngineFixture.start - 1)
        stores.peers.recordProfileFrame(kept.wire, of: bob.nodeId, sentAt: kept.envelope.sentAt)
        let fixture = EngineFixture(alice, stores: stores, started: false)
        // Before any sweep has run, a key request for bob finds nothing to serve: the pin store's copy is over the cap.
        #expect(fixture.engine.keyExchange.serveKey(bob.nodeId) == nil)
        #expect(fixture.engine.keyExchange.cachedProfile(of: bob.nodeId) == nil)
        fixture.engine.start()
        #expect(stores.peers.profileFrame(of: bob.nodeId) == nil, "the start's sweep deletes it")
        #expect(stores.peers.peer(bob.nodeId)?.publicKey == bob.keys.bundle.encoded, "the pin stays")
    }
}
