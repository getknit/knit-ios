import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A reset's re-seal goes out twice, the second past the routers' dedup window (knit-next ADR 2026-10.dmgw, #171):
/// knit-next's `MeshManagerTest` cases of `458c2eee`, under their Kotlin names (`MeshManagerTest.kt` at `4f3cd995`). A relay
/// that saw an id in its ten-minute window drops the re-seal, so the same ids are sealed once more
/// ``ResetReseal/secondPassMilliseconds`` later, only those still unacked, once. The 60-second re-offer drains the pass;
/// here it is called after the clock moves, as Kotlin calls `reofferToNeighbors`. Three engines in a line are
/// `RatchetResealReachTests`'.
@Suite struct MeshEngineResetResealSecondPassTests {
    private let me: TestPeer
    private let alice: TestPeer
    private var now: Int64 { EngineFixture.start }

    init() {
        let pair = [TestPeer(seed: 1), TestPeer(seed: 2)].sorted { $0.nodeId < $1.nodeId }
        me = pair[0]
        alice = pair[1]
    }

    /// Every distinct seal of `id` that went out: a re-seal keeps the original id, so count by bytes.
    private func seals(_ fixture: EngineFixture, _ id: String) -> Int {
        Set(fixture.transport.written(.chat).filter { $0.envelope.id == id }.map(\.wire.signed)).count
    }

    /// The tick, as the clock moves `milliseconds` on.
    private func tick(_ fixture: EngineFixture, after milliseconds: Int64) {
        fixture.clock.advance(milliseconds)
        fixture.engine.reoffer()
    }

    @Test func aResetsResealGoesOutOnceMoreAfterTheDedupWindow() throws {
        let iphone = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        let ids = try (0..<3).map { try #require(iphone.engine.sendDirectMessage("dm \($0)", to: alice.nodeId)).id }
        let (acked, stillOwed, alsoOwed) = (ids[0], ids[1], ids[2])

        iphone.engine.resealRecentDirectMessages(to: alice.nodeId)
        #expect(ids.map { seals(iphone, $0) } == [2, 2, 2], "the reset re-seals each at once")
        #expect(iphone.engine.resetReseal.owed(to: alice.nodeId)?.ids.count == 3, "recorded with the first pass")

        tick(iphone, after: ResetReseal.secondPassMilliseconds - 1)
        #expect(ids.map { seals(iphone, $0) } == [2, 2, 2], "nothing before the window has passed")

        // Since the reset: one acked, and a new DM sent under the fresh session.
        #expect(iphone.stores.messages.markDelivered(acked))
        let afterReset = try #require(iphone.engine.sendDirectMessage("after the reset", to: alice.nodeId)).id
        tick(iphone, after: 1)
        #expect(seals(iphone, acked) == 2, "the acked one is left alone")
        #expect([seals(iphone, stillOwed), seals(iphone, alsoOwed)] == [3, 3], "the still-unacked ones go once more")
        #expect(seals(iphone, afterReset) == 1, "a DM sent after the reset is not the reset's to re-seal")
        #expect(iphone.engine.resetReseal.owed(to: alice.nodeId) == nil)

        tick(iphone, after: ResetReseal.secondPassMilliseconds)
        #expect([acked, stillOwed, alsoOwed, afterReset].map { seals(iphone, $0) } == [2, 3, 3, 1], "once per reset: it never re-arms")

        // Android reads the last seal of each, under the one session it holds.
        let last = try #require(iphone.transport.written(.chat).last { $0.envelope.id == stillOwed })
        #expect(plaintext(try android.open(last, from: me, now: now + 2 * ResetReseal.secondPassMilliseconds)) != nil)
    }

    /// The second pass honours a block that landed after the reset, as the first pass does.
    @Test func aResetsSecondResealSkipsAPeerBlockedSince() throws {
        let iphone = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        let id = try #require(iphone.engine.sendDirectMessage("hello", to: alice.nodeId)).id
        iphone.engine.resealRecentDirectMessages(to: alice.nodeId)
        let written = iphone.transport.written.count

        iphone.engine.block(alice.nodeId)
        tick(iphone, after: ResetReseal.secondPassMilliseconds)
        #expect(iphone.transport.written.count == written, "nothing sealed to a blocked peer")
        #expect(seals(iphone, id) == 2)
    }

    /// This port's: a later reset of the same peer replaces the pass owed rather than adding one, a reset with nothing
    /// unacked leaves a pass owed as it was, and the pass goes with nobody linked, since the re-offer runs it first.
    @Test func aLaterResetReplacesThePassOwedAndThePassGoesWithNobodyLinked() throws {
        let iphone = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try iphone.pin(android)
        iphone.unlink(alice)
        let first = try #require(iphone.engine.sendDirectMessage("one", to: alice.nodeId)).id
        iphone.engine.resealRecentDirectMessages(to: alice.nodeId)
        let firstDue = try #require(iphone.engine.resetReseal.owed(to: alice.nodeId)).dueAt

        iphone.clock.advance(60_000)
        let second = try #require(iphone.engine.sendDirectMessage("two", to: alice.nodeId)).id
        iphone.engine.resealRecentDirectMessages(to: alice.nodeId)
        let replaced = try #require(iphone.engine.resetReseal.owed(to: alice.nodeId))
        #expect(replaced.dueAt == firstDue + 60_000 && replaced.ids == [ExactKey(first), ExactKey(second)])
        #expect([seals(iphone, first), seals(iphone, second)] == [3, 2])

        _ = iphone.stores.messages.markDelivered(first)
        _ = iphone.stores.messages.markDelivered(second)
        iphone.engine.resealRecentDirectMessages(to: alice.nodeId)
        #expect(iphone.engine.resetReseal.owed(to: alice.nodeId) == replaced, "nothing unacked records nothing")

        tick(iphone, after: ResetReseal.secondPassMilliseconds - 60_000)
        #expect(iphone.engine.resetReseal.owed(to: alice.nodeId) == replaced, "the first reset's due time no longer counts")
        tick(iphone, after: 60_000)
        #expect(iphone.engine.resetReseal.owed(to: alice.nodeId) == nil, "drained with nobody linked")
        #expect([seals(iphone, first), seals(iphone, second)] == [3, 2], "both were acked since")
    }
}
