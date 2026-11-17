import KnitStore
import KnitWire
import Testing

@testable import KnitCrypto
@testable import KnitMesh

/// The DM half of knit-next's `RatchetSessionsExportTest` (`mesh/crypto/ratchet/`, at `0832b8462`; ADR 2026-11.adrq),
/// over two real session facades: which sessions hand the spool a scope, that both sides of a pair derive the same live
/// and retiring scopes, when the retiring one ends, and that a store that cannot answer hands out `nil`, never an empty
/// table.
///
/// Left out: `rootChanges`, which is not ported, and every case of our own unanswered reset that Kotlin exports
/// (`ourResetOverAConfirmedSessionExports…`, `aResetRaceEnds…`, `aSecondResetOverOurUnansweredOne…`,
/// `theReplacedErasOwnInit…`, `theReplacedErasInitSealedSinceOurReset…`, `thePendingResetRuleReadsTheRowAlone`): that
/// exception (knit-next ADR 2026-10.j67x) is deferred with the slot and race rules it needs, so such a reset exports
/// nothing here, as ``ourOwnUnansweredResetExportsNothingUntilItIsAnswered()`` pins. Also left out: the restore's
/// `ownPendingResets` cases, and the scope config's confirmed-only seal (ctl 7 is never sent).
@Suite struct RatchetSessionsScopesTests {
    static let t0: Int64 = 100_000_000
    static let t1 = t0 + 600_000
    static let drain = RatchetEngine.previousRootMilliseconds

    /// A session both sides confirmed at `t0`, the first side the initiator.
    private func established() throws -> (RatchetSessionSide, RatchetSessionSide) {
        let (alice, bob) = try RatchetSessionSide.pair()
        #expect(plaintext(try bob.open(alice.seal("hello", now: Self.t0), now: Self.t0)) != nil)
        #expect(plaintext(try alice.open(bob.seal("hello back", now: Self.t0 + 1), now: Self.t0 + 1)) != nil)
        return (alice, bob)
    }

    /// The scope `root` derives for the pair, independently of the facade.
    private func scope(_ root: [UInt8], _ one: NodeId, _ other: NodeId) -> ScopeKeys {
        ScopeCrypto.dmScope(pairwiseRoot: RatchetCrypto.exportRoot(root), one, other)
    }

    private func only(
        _ scopes: [RatchetSessions.DMScopes]?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> RatchetSessions.DMScopes {
        let all = try #require(scopes, sourceLocation: sourceLocation)
        #expect(all.count == 1, sourceLocation: sourceLocation)
        return try #require(all.first, sourceLocation: sourceLocation)
    }

    private func same(_ one: ScopeKeys, _ other: ScopeKeys) -> Bool {
        one.id == other.id && one.sealKey == other.sealKey && one.nonceKey == other.nonceKey
    }

    @Test func aConfirmedPairDerivesOneScopeOnBothSides() throws {
        let (alice, bob) = try established()
        let ours = try only(alice.sessions.dmScopes(now: Self.t0 + 2))
        let theirs = try only(bob.sessions.dmScopes(now: Self.t0 + 2))
        #expect(ours.peerId == bob.nodeId && theirs.peerId == alice.nodeId)
        #expect(same(ours.live, theirs.live))
        #expect(ours.retiring == nil && theirs.retiring == nil)
        let root = try #require(alice.session).root
        #expect(same(ours.live, scope(root, alice.nodeId, bob.nodeId)), "the root's export, with both ids")
    }

    /// `aFirstContactInitExportsNothingUntilAnswered`: our init waits for its answer, while the responder, a stranger to
    /// us until its first open, is confirmed and exports at once, as Android's does.
    @Test func aFirstContactInitExportsNothingUntilAnswered() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        #expect(alice.sessions.dmScopes(now: Self.t0)?.isEmpty == true, "no session")
        let first = try alice.seal("hello", now: Self.t0)
        #expect(alice.sessions.dmScopes(now: Self.t0)?.isEmpty == true, "an initiator waits for its answer")

        #expect(plaintext(try bob.open(first, now: Self.t0)) != nil)
        let theirs = try only(bob.sessions.dmScopes(now: Self.t0))
        #expect(theirs.peerId == alice.nodeId)

        #expect(plaintext(try alice.open(bob.seal("hi", now: Self.t0 + 1), now: Self.t0 + 1)) != nil)
        #expect(same(try only(alice.sessions.dmScopes(now: Self.t0 + 1)).live, theirs.live))
    }

    /// `aResetFromNoSessionExportsNothing`: a reset that replaced no root is an unconfirmed init like any other.
    @Test func aResetFromNoSessionExportsNothing() throws {
        let (alice, _) = try established()
        alice.wipe()
        #expect(try sealedReset(alice.reset(now: Self.t1)).reRooted)
        #expect(alice.sessions.dmScopes(now: Self.t1)?.isEmpty == true)
    }

    /// Kotlin exports our own reset over a confirmed session while it waits (knit-next ADR 2026-10.j67x); this port
    /// defers that with the slot and race rules (ADR 2026-11.adrq), so the scope goes until the peer answers. The peer,
    /// which adopts the reset, holds the new root as live and the replaced one as retiring, and once its answer opens here
    /// both sides hold the same two.
    @Test func ourOwnUnansweredResetExportsNothingUntilItIsAnswered() throws {
        let (alice, bob) = try established()
        let before = try #require(alice.session).root
        let seal = try sealedReset(alice.reset(now: Self.t1))
        #expect(seal.reRooted)
        #expect(try #require(alice.session).confirmed == false)
        #expect(alice.sessions.dmScopes(now: Self.t1)?.isEmpty == true, "our reset, unanswered")

        #expect(plaintext(try bob.open(seal.envelope, now: Self.t1 + 1)) != nil)
        let theirs = try only(bob.sessions.dmScopes(now: Self.t1 + 1))
        let after = try #require(bob.session).root
        #expect(after != before)
        #expect(same(theirs.live, scope(after, alice.nodeId, bob.nodeId)))
        #expect(same(try #require(theirs.retiring), scope(before, alice.nodeId, bob.nodeId)), "the replaced root drains")

        #expect(plaintext(try alice.open(bob.seal("answer", now: Self.t1 + 2), now: Self.t1 + 2)) != nil)
        let ours = try only(alice.sessions.dmScopes(now: Self.t1 + 2))
        #expect(same(ours.live, theirs.live))
        #expect(same(try #require(ours.retiring), try #require(theirs.retiring)))
    }

    /// The retiring scope lasts exactly while `prevRoot` opens frames: up to `prevRootExpiresAt` on our own clock, and
    /// not at it.
    @Test func theRetiringScopeEndsAtItsRootsExpiry() throws {
        let (alice, bob) = try established()
        let seal = try sealedReset(alice.reset(now: Self.t1))
        #expect(plaintext(try bob.open(seal.envelope, now: Self.t1 + 1)) != nil)
        let expires = try #require(bob.session).prevRootExpiresAt
        #expect(expires == Self.t1 + 1 + Self.drain)
        #expect(try only(bob.sessions.dmScopes(now: expires - 1)).retiring != nil)
        let ended = try only(bob.sessions.dmScopes(now: expires))
        #expect(ended.retiring == nil)
        #expect(same(ended.live, try only(bob.sessions.dmScopes(now: Self.t1 + 1)).live), "the live scope stays")
        #expect(try only(bob.sessions.dmScopes(now: expires + 1)).retiring == nil)
    }

    /// A store that cannot read answers `nil`, which a caller keeps its scopes on, and so does a call inside a caller's
    /// unit; neither answers an empty table, which would drop every scope.
    @Test func aStoreThatCannotAnswerHandsOutNil() throws {
        let refusing = RefusingRatchetStore()
        let (alice, bob) = try RatchetSessionSide.pair(refusing: refusing)
        #expect(plaintext(try bob.open(alice.seal("hello", now: Self.t0), now: Self.t0)) != nil)
        #expect(plaintext(try alice.open(bob.seal("back", now: Self.t0 + 1), now: Self.t0 + 1)) != nil)
        #expect(alice.sessions.dmScopes(now: Self.t0 + 2)?.count == 1)

        refusing.refuse(.reads)
        #expect(alice.sessions.dmScopes(now: Self.t0 + 2) == nil)
        refusing.refuse([])
        var inside: [RatchetSessions.DMScopes]?? = .none
        let outer = alice.transactor.atomically { () -> Void? in
            inside = .some(alice.sessions.dmScopes(now: Self.t0 + 2))
            return ()
        }
        guard case .committed = outer else {
            Issue.record("the outer unit commits: \(outer)")
            return
        }
        #expect(inside.map { $0 == nil } == true, "inside a caller's unit it answers nil")
    }

    /// The rule alone, over rows: a confirmed session exports whatever its role, and an unconfirmed one never, our own
    /// reset included.
    @Test func theExportRuleIsConfirmedAlone() {
        let peer = IdentityKeys.generate().nodeId
        let root = [UInt8](repeating: 1, count: 32)
        for weAreInitiator in [false, true] {
            #expect(
                RatchetSessions.exports(
                    RatchetSessionRecord(peerId: peer, confirmed: true, weAreInitiator: weAreInitiator, root: root, establishedAt: 1)))
            #expect(
                !RatchetSessions.exports(
                    RatchetSessionRecord(peerId: peer, confirmed: false, weAreInitiator: weAreInitiator, root: root, establishedAt: 1)))
        }
        let ownReset = RatchetSessionRecord(
            peerId: peer,
            confirmed: false,
            weAreInitiator: true,
            root: root,
            prevRoot: [UInt8](repeating: 2, count: 32),
            prevRootExpiresAt: 10,
            establishedAt: 5,
            initEphPub: [UInt8](repeating: 3, count: 32),
            lastResetSentAt: 5
        )
        #expect(!RatchetSessions.exports(ownReset), "Kotlin's pendingResetInit exception is deferred")
    }

    /// The generation the spool plane reads (ADR 2026-11.adrq, P4a) moves with each settlement that may move a row's scopes,
    /// and with nothing else.
    @Test func theGenerationMovesOnlyWhenARowsScopesMay() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let opener = try alice.seal("hello", now: Self.t0)
        #expect(alice.sessions.generation == 0, "a plain seal: 0")
        #expect(plaintext(try bob.open(opener, now: Self.t0)) != nil)
        #expect(bob.sessions.generation == 1, "a responder's first open: +1")
        #expect(plaintext(try alice.open(bob.seal("hi", now: Self.t0 + 1), now: Self.t0 + 1)) != nil)
        #expect(alice.sessions.generation == 1 && bob.sessions.generation == 1, "an init answered: +1, the reply's seal: 0")
        #expect(plaintext(try bob.open(opener, now: Self.t0 + 2)) == nil)
        #expect(bob.sessions.generation == 1, "a refused open: 0")

        let (carol, dave) = try RatchetSessionSide.pair()
        let fromCarol = try carol.seal("carol opens", now: Self.t0)
        let fromDave = try dave.seal("dave opens", now: Self.t0)
        let roots = [carol.session?.root, dave.session?.root]
        _ = try carol.open(fromDave, now: Self.t0 + 1)
        _ = try dave.open(fromCarol, now: Self.t0 + 1)
        let sides = [carol, dave]
        let losers = sides.indices.filter { sides[$0].session?.root != roots[$0] }
        #expect(losers.count == 1, "one side lost the race")
        for index in losers {
            #expect(sides[index].sessions.generation == 1, "a lost race: +1")
        }
    }
}
