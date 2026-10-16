import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// An open inside a unit its caller opened answers `.joined`, and the floors it would move stay where they were until the
/// caller's outermost unit commits and hands its `Settlement` to `settle`; when that unit fails, neither the rows nor the
/// floors move (ADR 2026-10.5sk9's P4c amendment, owed to P5 by its review). A joined settlement applied early would start
/// a floor for a replacement that rolled back.
@Suite struct RatchetSessionsNestingTests {
    static let now: Int64 = 1_700_000_000_000

    /// Bob's open of `envelope` from Alice inside a unit of his own, which fails when `fails` asks: the outer unit's
    /// answer, and the floors Bob held inside it, after the open.
    private func nestedOpen(
        _ envelope: EncEnvelope,
        by bob: RatchetSessionSide,
        from alice: RatchetSessionSide,
        at now: Int64,
        failing fails: Bool
    ) throws -> (outer: Transacted<RatchetSessions.Settlement>, inside: RatchetSessions.Floors?) {
        let frame = try #require(RatchetSessions.Frame(envelope: envelope, aad: RatchetSessionSide.aad))
        let prekeys = bob.prekeys
        var inside: RatchetSessions.Floors?
        let outer = bob.transactor.atomically { () -> RatchetSessions.Settlement? in
            let answer = bob.sessions.open(frame, from: alice.identity.bundle, now: now, prekeys: { prekeys[$0] }, alongside: { _ in () })
            guard case .joined(.opened, let settlement) = answer else {
                return nil
            }
            inside = bob.sessions.floors(for: alice.nodeId)
            if fails {
                bob.transactor.failCurrentUnit()
            }
            return settlement
        }
        return (outer, inside)
    }

    @Test func anAnswerToOurInitConfirmsItOnlyOnceTheOuterUnitCommits() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let opener = try bob.seal("hi", now: Self.now)
        #expect(plaintext(try alice.open(opener, now: Self.now)) == Array("hi".utf8))
        let answer = try alice.seal("hello", now: Self.now + 1)

        let (outer, inside) = try nestedOpen(answer, by: bob, from: alice, at: Self.now + 2, failing: false)
        #expect(inside?.confirmedAt == nil, "nothing moves inside the caller's unit")
        guard case .committed(let settlement) = outer else {
            Issue.record("the outer unit commits: \(outer)")
            return
        }
        #expect(bob.sessions.floors(for: alice.nodeId).confirmedAt == nil, "nor once it commits, before the settlement")
        bob.sessions.settle(settlement)
        #expect(bob.sessions.floors(for: alice.nodeId).confirmedAt == Self.now + 2)
        #expect(bob.session?.confirmed == true)
    }

    @Test func anAnswerWhoseOuterUnitFailsConfirmsNothing() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let opener = try bob.seal("hi", now: Self.now)
        _ = try alice.open(opener, now: Self.now)
        let answer = try alice.seal("hello", now: Self.now + 1)

        let (outer, inside) = try nestedOpen(answer, by: bob, from: alice, at: Self.now + 2, failing: true)
        #expect(inside != nil, "it opened, joined to the caller's unit")
        #expect(outer == .failed)
        #expect(bob.sessions.floors(for: alice.nodeId).confirmedAt == nil)
        #expect(bob.session?.confirmed == false, "the open rolled back with the unit")
    }

    @Test func aReplacementsFloorStartsOnlyOnceTheOuterUnitCommits() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        _ = try bob.open(alice.seal("first", now: Self.now), now: Self.now)
        let before = try #require(bob.session)
        alice.wipe()
        let reinit = try alice.seal("again", now: Self.now + 10)

        let (outer, inside) = try nestedOpen(reinit, by: bob, from: alice, at: Self.now + 20, failing: false)
        #expect(inside?.lastReplacementAt == nil)
        guard case .committed(let settlement) = outer else {
            Issue.record("the outer unit commits: \(outer)")
            return
        }
        #expect(bob.sessions.floors(for: alice.nodeId).lastReplacementAt == nil)
        bob.sessions.settle(settlement)
        #expect(bob.sessions.floors(for: alice.nodeId).lastReplacementAt == Self.now + 20)
        #expect(bob.session?.root != before.root)
    }

    @Test func aReplacementWhoseOuterUnitFailsStartsNoFloorAndKeepsTheSession() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        _ = try bob.open(alice.seal("first", now: Self.now), now: Self.now)
        let before = try #require(bob.session)
        alice.wipe()
        let reinit = try alice.seal("again", now: Self.now + 10)

        let (outer, _) = try nestedOpen(reinit, by: bob, from: alice, at: Self.now + 20, failing: true)
        #expect(outer == .failed)
        let floors = bob.sessions.floors(for: alice.nodeId)
        #expect(floors.lastReplacementAt == nil && floors.confirmedAt == nil, "neither floor moves")
        #expect(bob.session?.root == before.root, "the replacement was undone with its unit")
    }
}
