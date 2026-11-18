import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The edges of our own profile's one signing per stamp (ADR 2026-11.xfcq): a ring that moves within one process, an edit
/// after an eviction, and a kept frame the store cannot read, which is never a reason to sign a stamp again.
@Suite struct MeshEngineOwnProfileFrameEdgeTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let laterTag = MeshEngineOwnProfileFrameTests.laterTag

    /// The prekey `frame`'s profile names.
    private func prekeyId(_ frame: WireEnvelope?) throws -> Int? {
        let signed = try #require(frame?.signed)
        return try ProfileContent(decoding: try RelayEnvelope(decoding: signed).payload).prekey?.id
    }

    /// Test 2. Signed, evicted, then the prekey the profile names drops out of the ring with no heal to move the stamp: a
    /// link-up still pushes the first bytes, naming the first prekey. A restart in that state mints exactly one new stamp.
    @Test func aRingThatMovesWithinOneProcessChangesNoBytesUnderTheStamp() throws {
        let keychain = KeptSecretStore(alice.keys.storedForm)
        let stores = MeshStores.inMemory()
        let fixture = try EngineFixture.ratcheting(alice, stores: stores, keychain: keychain)
        let stamp = stores.ownProfile.load().publishedAt
        let id = fixture.ownProfileId
        let first = try #require(fixture.ownRow)
        let prekey = try #require(try prekeyId(first))
        stores.custody.remove(id)
        fixture.engine.prekeyRing = nil
        let signedThen = try RelayEnvelope(decoding: first.signed).encoded
        #expect(fixture.engine.currentProfileEnvelope(of: stores.ownProfile.load()).encoded != signedThen, "a signing now differs")

        fixture.link(bob)
        let pushed = fixture.writes(of: id)
        #expect(pushed.count == 1 && pushed.allSatisfy { $0.sameBytes(as: first) }, "the first bytes")
        #expect(try prekeyId(pushed.first) == prekey, "still naming the first prekey")
        #expect(fixture.ownRow?.sameBytes(as: first) == true, "put back into custody as they were")
        #expect(stores.ownProfile.load().publishedAt == stamp)

        let restarted = EngineFixture(
            alice, stores: stores, configuration: MeshConfiguration(ratchet: true), wall: EngineFixture.start + 60_000, seed: 9)
        let ours = stores.custody.liveFrames(now: restarted.clock.wallMilliseconds()).filter { frame in
            frame.envelope.type == .profile && ExactKey(frame.envelope.senderId) == ExactKey(alice.nodeId.string)
        }
        let minted = ours.map(\.envelope.id).filter { ExactKey($0) != ExactKey(id) }
        #expect(minted == [restarted.ownProfileId], "one new stamp, \(minted)")
        let restartedPrekey = try prekeyId(restarted.ownRow)
        #expect(stores.ownProfile.load().publishedAt > stamp && restartedPrekey == nil)
        #expect(restarted.keptFrame?.sameBytes(as: restarted.ownRow) == true)
    }

    /// Test 4. An eviction alone, in this process and across a restart, mints and seals nothing; an edit after it mints one
    /// stamp, floods it once, and sends one sealed copy to the confirmed session.
    @Test func anEditAfterAnEvictionMintsOnceAndAnEvictionAloneMintsNothing() throws {
        let keychain = KeptSecretStore(alice.keys.storedForm)
        let stores = MeshStores.inMemory()
        let fixture = try EngineFixture.ratcheting(alice, stores: stores, keychain: keychain)
        let android = try AndroidPeer(bob)
        try fixture.pin(android)
        fixture.deliver(
            try android.dm("hello", to: alice, prekey: try fixture.ourPrekey(), id: frameIdOf("dm-1"), sentAt: EngineFixture.start),
            from: android)
        #expect(fixture.ratchetRecords(of: bob).session?.confirmed == true)
        fixture.advance(MeshConfiguration().healMilliseconds)
        let stamp = stores.ownProfile.load().publishedAt
        let first = try #require(fixture.ownRow)
        stores.custody.remove(fixture.ownProfileId)
        fixture.transport.clear()
        fixture.unlink(bob)
        fixture.link(bob)
        #expect(fixture.answers(to: android).isEmpty && fixture.ownRow?.sameBytes(as: first) == true, "this process: nothing sealed")

        stores.custody.remove(fixture.ownProfileId)
        let wall = fixture.clock.wallMilliseconds() + 60_000
        let restarted = try EngineFixture.ratcheting(alice, stores: stores, keychain: keychain, wall: wall, seed: 9, deviceTag: laterTag)
        restarted.link(bob)
        restarted.advance(MeshConfiguration().healMilliseconds)
        let profiles = restarted.transport.written(.profile)
        #expect(stores.ownProfile.load().publishedAt == stamp, "a restart after an eviction mints nothing")
        #expect(profiles.allSatisfy { $0.wire.sameBytes(as: first) }, "and sends only the first bytes")
        let answered = restarted.answerIds
        #expect(!restarted.answers(to: android).contains { !answered.contains(ExactKey($0.envelope.id)) }, "and seals nothing")

        restarted.transport.clear()
        restarted.engine.updateProfile(name: "Alice", status: "edited", openToChat: true)
        let edited = restarted.ownProfileId
        #expect(stores.ownProfile.load().publishedAt > stamp)
        let floods = restarted.transport.written(.profile).filter { $0.to == nil }
        #expect(floods.map(\.envelope.id) == [edited], "one stamp, flooded once")
        let sealed = restarted.answers(to: android).filter { !answered.contains(ExactKey($0.envelope.id)) }
        #expect(sealed.count == 1, "one sealed copy to the confirmed session")
    }

    /// Test 6. A kept frame the store cannot read, custody evicted, and a fresh process: no profile at the start's seed or
    /// a link-up, and nothing signed. Once the store reads again, the next link-up sends the kept bytes. With the read
    /// failing again, an edit still floods its new stamp, which nothing can have signed before, and a later link-up sends
    /// this process's copy of it rather than signing it again.
    @Test func aKeptFrameThatCannotBeReadSignsNothingAndAnEditStillFloods() throws {
        let (stores, profiles) = MeshStores.refusingOwnProfile()
        let first = EngineFixture(alice, stores: stores)
        let id = first.ownProfileId
        let row = try #require(first.ownRow)
        stores.custody.remove(id)
        profiles.failsKeptReads = true

        let restarted = EngineFixture(alice, stores: stores, wall: EngineFixture.start + 60_000, seed: 9, deviceTag: laterTag)
        #expect(restarted.engine.ownProfile() == nil)
        #expect(restarted.ownRow == nil, "nothing signed, nothing put back")
        restarted.link(bob)
        #expect(restarted.transport.written(.profile).isEmpty, "the link-up pushes nothing")
        #expect(restarted.log.all.contains("warning mesh has no profile frame to send: our custody or the kept frame could not be read"))

        profiles.failsKeptReads = false
        restarted.unlink(bob)
        restarted.link(bob)
        let pushed = restarted.writes(of: id)
        #expect(pushed.count == 1 && pushed.allSatisfy { $0.sameBytes(as: row) }, "the next link-up sends the kept bytes")

        profiles.failsKeptReads = true
        profiles.refusesKeeps = true
        restarted.transport.clear()
        restarted.clock.advance(1000)
        restarted.engine.updateProfile(name: "Alice", status: "edited", openToChat: false)
        let edit = restarted.ownProfileId
        let flooded = try #require(restarted.transport.written(.profile).first { $0.to == nil })
        #expect(flooded.envelope.id == edit, "the edit floods on a failing read")
        #expect(restarted.log.all.contains("warning mesh could not keep our profile frame"))

        stores.custody.remove(edit)
        var drifted = profiles.load()
        drifted.status = "drifted under the same stamp"
        profiles.save(drifted)
        restarted.transport.clear()
        restarted.unlink(bob)
        restarted.link(bob)
        let again = restarted.writes(of: edit)
        #expect(again.count == 1 && again.allSatisfy { $0.sameBytes(as: flooded.wire) }, "this process's copy, not a second signing")
        #expect(restarted.ownRow?.sameBytes(as: flooded.wire) == true, "put back into custody too")
    }

    /// A save that does not land leaves the store on the stamp before the edit, which may have been signed already: the edit
    /// signs nothing new, and floods the frame that stamp already has.
    @Test func anEditWhoseSaveDidNotLandSignsTheOldStampNoSecondTime() throws {
        let (stores, profiles) = MeshStores.refusingOwnProfile()
        let fixture = EngineFixture(alice, stores: stores)
        let stamp = profiles.load().publishedAt
        let row = try #require(fixture.ownRow)
        profiles.refusesSaves = true
        fixture.transport.clear()
        fixture.clock.advance(1000)
        fixture.engine.updateProfile(name: "Alice", status: "never saved", openToChat: false)
        #expect(profiles.load().publishedAt == stamp)
        let warning = "warning mesh signed no new profile: our profile does not read the stamp \(stamp + 1000) saved"
        #expect(fixture.log.all.contains(warning))
        let profilesWritten = fixture.transport.written(.profile)
        #expect(!profilesWritten.isEmpty && profilesWritten.allSatisfy { $0.wire.sameBytes(as: row) }, "the old stamp's own bytes")
    }
}
