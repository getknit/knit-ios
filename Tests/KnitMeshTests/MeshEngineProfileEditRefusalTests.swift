import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// What an edit of our profile does when the profile's row cannot be read now (ADR 2026-10.5sk9, ADR 2026-11.xfcq):
/// `load()` would answer a fresh profile, and an edit over it would save and sign a blank name under a version every
/// receiver takes. The edit is dropped, logged, and nothing is saved, signed, pushed or sealed; once the row reads, the same
/// edit publishes.
@Suite struct MeshEngineProfileEditRefusalTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)

    private let jpeg: [UInt8] = Array("a 256-pixel JPEG, in spirit".utf8)
    private let newer: [UInt8] = Array("another photo".utf8)

    /// Our profile frames in custody, under any stamp.
    private func ownFrames(_ fixture: EngineFixture) -> [String] {
        fixture.stores.custody.liveFrames(now: fixture.clock.wallMilliseconds())
            .filter { $0.envelope.type == .profile && ExactKey($0.envelope.senderId) == ExactKey(alice.nodeId.string) }
            .map(\.envelope.id)
    }

    @Test func aRenameOverAnUnreadableRowIsDropped() throws {
        let (stores, profiles) = MeshStores.refusingOwnProfile()
        let fixture = EngineFixture(alice, stores: stores)
        fixture.engine.updateProfile(name: "Alice", status: "here", openToChat: true)
        fixture.link(bob)
        let row = profiles.held.load()
        let frames = ownFrames(fixture)
        let shown = try #require(fixture.engine.ownProfile())
        fixture.transport.clear()
        profiles.failsLoads = true
        fixture.clock.advance(1000)

        fixture.engine.updateProfile(name: "Renamed", status: "edited", openToChat: false)
        profiles.failsLoads = false
        #expect(profiles.held.load() == row, "the row as it was")
        #expect(ownFrames(fixture) == frames, "nothing signed into custody")
        #expect(fixture.transport.written(.profile).isEmpty, "nothing on the transport")
        #expect(fixture.engine.ownProfile()?.wire.sameBytes(as: shown.wire) == true, "the profile we serve unchanged")
        #expect(fixture.log.all.contains("warning mesh left our profile as it was: our profile could not be read"))

        fixture.engine.updateProfile(name: "Renamed", status: "edited", openToChat: false)
        let edited = profiles.held.load()
        #expect(edited.name == "Renamed" && edited.version > row.version, "the same edit once the row reads")
        let flooded = try #require(fixture.transport.written(.profile).first)
        #expect(try ProfileContent(decoding: flooded.envelope.payload).name == "Renamed")
    }

    @Test func aPhotoOverAnUnreadableRowIsDropped() throws {
        let (stores, profiles) = MeshStores.refusingOwnProfile()
        let fixture = EngineFixture(alice, stores: stores)
        fixture.engine.updateProfile(name: "Alice", status: "here", openToChat: true)
        fixture.engine.setAvatar(jpeg)
        fixture.link(bob)
        let row = profiles.held.load()
        let frames = ownFrames(fixture)
        fixture.transport.clear()
        profiles.failsLoads = true
        fixture.clock.advance(1000)

        fixture.engine.setAvatar(newer)
        profiles.failsLoads = false
        let hash = BlobHash(of: newer)
        #expect(!stores.blobs.contains(hash), "no blob that nothing names")
        #expect(stores.blobs.bytes(of: BlobHash(of: jpeg)) == jpeg, "the photo it would replace stays")
        #expect(profiles.held.load() == row, "the row as it was")
        #expect(ownFrames(fixture) == frames, "nothing signed into custody")
        #expect(fixture.transport.written.isEmpty && fixture.transport.files.isEmpty, "nothing pushed, flooded or sealed")
        let warning = "warning mesh left our photo as it was: our profile could not be read"
        #expect(fixture.log.all.filter { $0 == warning }.count == 1)

        fixture.engine.setAvatar(newer)
        let edited = profiles.held.load()
        #expect(edited.avatarHash == hash && edited.name == "Alice" && edited.version > row.version, "the photo once the row reads")
        #expect(stores.blobs.bytes(of: hash) == newer)
        #expect(fixture.transport.files.map(\.hash) == [hash] && fixture.transport.files.map(\.to) == [bob.nodeId])
        let flooded = try #require(fixture.transport.written(.profile).first)
        #expect(try ProfileContent(decoding: flooded.envelope.payload).avatarHash == hash.string)
    }

    /// A clear over an unreadable row, with a photo held: `load()`'s fresh profile names no photo, so the old read took the
    /// clear for no change and returned silently. No state tells the two reads apart; the warning does, and the clear once
    /// the row reads shows the photo was ours to clear.
    @Test func aClearOverAnUnreadableRowKeepsThePhoto() throws {
        let (stores, profiles) = MeshStores.refusingOwnProfile()
        let fixture = EngineFixture(alice, stores: stores)
        fixture.engine.updateProfile(name: "Alice", status: "here", openToChat: true)
        fixture.engine.setAvatar(jpeg)
        fixture.link(bob)
        let hash = BlobHash(of: jpeg)
        let row = profiles.held.load()
        #expect(row.avatarHash == hash)
        let frames = ownFrames(fixture)
        fixture.transport.clear()
        profiles.failsLoads = true
        fixture.clock.advance(1000)

        fixture.engine.setAvatar(nil)
        profiles.failsLoads = false
        #expect(stores.blobs.bytes(of: hash) == jpeg, "the photo's bytes stay, unreleased")
        #expect(profiles.held.load() == row && profiles.held.load().avatarHash == hash, "the row still names the photo")
        #expect(ownFrames(fixture) == frames, "nothing signed into custody")
        #expect(fixture.transport.written.isEmpty && fixture.transport.files.isEmpty, "nothing pushed, flooded or sealed")
        #expect(fixture.log.all.contains("warning mesh left our photo as it was: our profile could not be read"))

        fixture.engine.setAvatar(nil)
        let cleared = profiles.held.load()
        #expect(cleared.avatarHash == nil && cleared.version > row.version, "the clear once the row reads")
        #expect(!stores.blobs.contains(hash), "and the photo released")
        let flooded = try #require(fixture.transport.written(.profile).first)
        #expect(try ProfileContent(decoding: flooded.envelope.payload).avatarHash == nil)
    }
}
