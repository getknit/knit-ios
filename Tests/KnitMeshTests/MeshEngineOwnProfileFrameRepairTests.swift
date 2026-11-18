import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// What a store that fails does to our own profile's one signing per stamp (ADR 2026-11.xfcq): a profile row that cannot
/// be read is no fresh profile to sign, a failed custody read is no missing row, a keep that failed is mended by the next
/// read that shows it, and a kept frame of ours under an older stamp is replaced, never forgotten first.
@Suite struct MeshEngineOwnProfileFrameRepairTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let laterTag = MeshEngineOwnProfileFrameTests.laterTag

    /// Our profile's row fails to read while the frame's table still reads: `load()` would answer a fresh profile at stamp
    /// 0. Nothing is signed, nothing goes out and the kept frame stays; once the row reads, the next link-up sends it.
    @Test func aProfileRowThatCannotBeReadIsNoBlankProfileToSign() throws {
        let (stores, profiles) = MeshStores.refusingOwnProfile()
        let first = EngineFixture(alice, stores: stores)
        let id = first.ownProfileId
        let row = try #require(first.ownRow)
        stores.custody.remove(id)
        profiles.failsLoads = true
        let keepsBefore = profiles.keeps.count

        let restarted = EngineFixture(alice, stores: stores, wall: EngineFixture.start + 60_000, seed: 9, deviceTag: laterTag)
        #expect(restarted.engine.ownProfile() == nil)
        restarted.link(bob)
        #expect(restarted.transport.written(.profile).isEmpty, "nothing on the transport")
        #expect(restarted.keptFrame?.sameBytes(as: row) == true && profiles.keeps.count == keepsBefore, "the kept frame untouched")
        let ours = stores.custody.liveFrames(now: restarted.clock.wallMilliseconds()).filter { $0.envelope.type == .profile }
        #expect(!ours.contains { ExactKey($0.envelope.senderId) == ExactKey(alice.nodeId.string) }, "nothing signed")
        #expect(restarted.log.all.contains("warning mesh has no profile frame to send: our profile could not be read"))

        profiles.failsLoads = false
        restarted.unlink(bob)
        restarted.link(bob)
        let pushed = restarted.writes(of: id)
        #expect(pushed.count == 1 && pushed.allSatisfy { $0.sameBytes(as: row) }, "the same bytes once the row reads")
    }

    /// A keep refused when the frame was signed leaves this process's copy alone holding it: the next link-up that reads the
    /// kept frame as other bytes writes the copy, and a restart after an eviction serves it.
    @Test func theCachedCopyMendsAKeepThatFailed() throws {
        let (stores, profiles) = MeshStores.refusingOwnProfile()
        let fixture = EngineFixture(alice, stores: stores)
        profiles.refusesKeeps = true
        fixture.clock.advance(1000)
        fixture.engine.updateProfile(name: "Alice", status: "edited", openToChat: false)
        let edited = try #require(fixture.ownRow)
        #expect(fixture.keptFrame?.sameBytes(as: edited) != true, "the keep was refused")
        profiles.refusesKeeps = false
        stores.custody.remove(fixture.ownProfileId)
        fixture.link(bob)
        #expect(fixture.keptFrame?.sameBytes(as: edited) == true, "the link-up kept this process's copy")

        stores.custody.remove(fixture.ownProfileId)
        let restarted = EngineFixture(alice, stores: stores, wall: fixture.clock.wallMilliseconds() + 60_000, seed: 9, deviceTag: laterTag)
        #expect(restarted.ownRow?.sameBytes(as: edited) == true, "a restart serves it")
    }

    /// Custody's read fails inside the unit with the row evicted and no copy in memory: no profile, nothing signed. Once
    /// custody reads, the kept bytes go out.
    @Test func aCustodyReadThatFailsIsNoMissingRow() throws {
        let failable = FailableStores()
        let first = EngineFixture(alice, stores: failable.stores)
        let id = first.ownProfileId
        let row = try #require(first.ownRow)
        failable.custody.held.remove(id)
        failable.custody.failsReads = true

        let restarted = EngineFixture(alice, stores: failable.stores, wall: EngineFixture.start + 60_000, seed: 9, deviceTag: laterTag)
        #expect(restarted.engine.ownProfile() == nil)
        #expect(!failable.custody.held.contains(id), "nothing signed or put back")
        #expect(failable.stores.ownProfile.keptFrame() == .kept(row))

        failable.custody.failsReads = false
        restarted.link(bob)
        let pushed = restarted.writes(of: id)
        #expect(pushed.count == 1 && pushed.allSatisfy { $0.sameBytes(as: row) })
        #expect(failable.custody.held.contains(id), "the kept bytes are back in custody for the next digest")
        #expect(restarted.ownRow?.sameBytes(as: row) == true)
    }

    /// A kept frame of ours under an older stamp, as a stamp moved by a save outside the engine leaves it: not forgotten
    /// first, but replaced by the one fresh signing of the new stamp.
    @Test func aKeptFrameUnderAnOlderStampIsReplacedNotForgotten() throws {
        let (stores, profiles) = MeshStores.refusingOwnProfile()
        let firstId = EngineFixture(alice, stores: stores).ownProfileId
        var own = profiles.load()
        own.publishedAt += 1000
        profiles.save(own)
        let keepsBefore = profiles.keeps.count

        let restarted = EngineFixture(alice, stores: stores, wall: EngineFixture.start + 60_000, seed: 9, deviceTag: laterTag)
        let fresh = try #require(restarted.ownRow)
        #expect(restarted.ownProfileId != firstId)
        #expect(profiles.keeps.dropFirst(keepsBefore).map { $0?.signed } == [fresh.signed], "one keep, the fresh frame, no forget")
        #expect(restarted.keptFrame?.sameBytes(as: fresh) == true)
    }
}
