import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The DM frame rules (`ScopeFramesTest.kt` at knit-next `0832b8462`, the DM cases): the §4.4 set both ways, the refill
/// rule with no reset exception (ADR 2026-11.adrq), the outward dead-on-arrival guard and the pull side's lateness, both
/// overflow-safe, and `open`'s ordered checks down to a candidate that becomes a frame only through its signature.
@Suite struct ScopeFramesTests {
    private typealias Fixture = ScopeFixture
    private let alice = ScopeFixture.alice.nodeId
    private let bob = ScopeFixture.bob.nodeId

    private func profile(_ peer: TestPeer) throws -> TestFrame {
        try peer.profile(publishedAt: ScopeFixture.wall)
    }

    /// `sealed` as a blob the spool served for the pair's scope, opened by Alice.
    private func open(
        _ sealed: SealedBlob, in scope: SpoolScope = ScopeFixture.scope(for: ScopeFixture.alice), source: ScopeCandidate.Source = .pulled
    ) -> ScopeCandidate? {
        let arrival = SpoolArrival(scope: scope.id, blobId: sealed.id, data: sealed.blob)
        return ScopeFrames.open(arrival, in: scope, me: alice, source: source, now: ScopeFixture.wall)
    }

    @Test func aRatchetedDMBetweenThePairRidesEitherWayInV2AndV3() {
        for version in [2, 3] {
            #expect(ScopeFrames.eligible(Fixture.dm(1, version: version).envelope, me: alice, peer: bob))
            #expect(
                ScopeFrames.eligible(Fixture.dm(1, from: Fixture.bob, to: Fixture.alice, version: version).envelope, me: alice, peer: bob))
        }
    }

    @Test func aThirdPartyAGroupAV1OrAHeaderlessDMDoesNot() throws {
        #expect(!ScopeFrames.eligible(Fixture.dm(1, from: Fixture.carol, to: Fixture.bob).envelope, me: alice, peer: bob))
        #expect(!ScopeFrames.eligible(Fixture.dm(1, from: Fixture.alice, to: Fixture.carol).envelope, me: alice, peer: bob))
        #expect(!ScopeFrames.eligible(Fixture.dm(1, version: 1).envelope, me: alice, peer: bob))
        #expect(!ScopeFrames.eligible(Fixture.dm(1, ratchet: false).envelope, me: alice, peer: bob))
        var grouped = Fixture.dm(1).envelope
        grouped.group = GroupInfo(id: "g-x", members: [alice.string, bob.string], createdBy: alice.string)
        #expect(!ScopeFrames.eligible(grouped, me: alice, peer: bob))
        let room = try Fixture.alice.roomPost("hi", id: FrameId.text(for: fixtureBytes(16, seed: 9)), sentAt: Fixture.wall)
        #expect(!ScopeFrames.eligible(room.envelope, me: alice, peer: bob))
        let receipt = try Fixture.alice.receipt(for: "x", id: FrameId.text(for: fixtureBytes(16, seed: 8)))
        #expect(!ScopeFrames.eligible(receipt.envelope, me: alice, peer: bob))
    }

    @Test func eitherMembersProfileRidesAndAThirdPartysDoesNot() throws {
        #expect(ScopeFrames.eligible(try profile(Fixture.alice).envelope, me: alice, peer: bob))
        #expect(ScopeFrames.eligible(try profile(Fixture.bob).envelope, me: alice, peer: bob))
        #expect(!ScopeFrames.eligible(try profile(Fixture.carol).envelope, me: alice, peer: bob))
    }

    @Test func membersAreComparedByTheirBytes() {
        var envelope = Fixture.dm(1).envelope
        envelope.recipientId = bob.string.uppercased()
        #expect(!ScopeFrames.eligible(envelope, me: alice, peer: bob))
    }

    @Test func ourOwnFlaggedResetIsPushedIntoNoScopeLiveOrRetiring() {
        let reset = Fixture.dm(1, reset: true).envelope
        let live = Fixture.scope(for: Fixture.alice)
        let retiring = Fixture.scope(for: Fixture.alice, retiring: true)
        #expect(ScopeFrames.ownResetInit(reset, me: alice, peer: bob) != nil)
        #expect(!ScopeFrames.mayRefill(reset, me: alice, scope: live))
        #expect(!ScopeFrames.mayRefill(reset, me: alice, scope: retiring))
        // The peer's reset is not ours, and an ordinary frame goes into a live scope alone (C-3.1-3).
        let peers = Fixture.dm(2, from: Fixture.bob, to: Fixture.alice, reset: true).envelope
        #expect(ScopeFrames.mayRefill(peers, me: alice, scope: live))
        #expect(ScopeFrames.mayRefill(Fixture.dm(3).envelope, me: alice, scope: live))
        #expect(!ScopeFrames.mayRefill(Fixture.dm(3).envelope, me: alice, scope: retiring))
    }

    @Test func aFlaggedHeaderWithNoInitIsNoResetAndRefillsALiveScope() {
        let flaggedBare = Fixture.dm(1, bareFlag: true).envelope
        #expect(ScopeFrames.ownResetInit(flaggedBare, me: alice, peer: bob) == nil)
        #expect(ScopeFrames.mayRefill(flaggedBare, me: alice, scope: Fixture.scope(for: Fixture.alice)))
    }

    @Test func anUnflaggedDMCarryingOurPendingInitRefillsALiveScopeAndNeverARetiringOne() {
        let carrying = Fixture.dm(1, pendingInit: true).envelope
        #expect(ScopeFrames.ownResetInit(carrying, me: alice, peer: bob) == nil)
        #expect(ScopeFrames.mayRefill(carrying, me: alice, scope: Fixture.scope(for: Fixture.alice)))
        #expect(!ScopeFrames.mayRefill(carrying, me: alice, scope: Fixture.scope(for: Fixture.alice, retiring: true)))
    }

    @Test func deadOnArrivalTripsAtTheScopesTTLAndNeverOnAnOverflow() {
        let ttl = ScopeFrames.ttlMilliseconds
        let sent = Fixture.dm(1, sentAt: 1000).envelope
        #expect(!ScopeFrames.deadOnArrival(sent, ttl: ttl, now: 1000 + ttl - 1))
        #expect(ScopeFrames.deadOnArrival(sent, ttl: ttl, now: 1000 + ttl))
        #expect(!ScopeFrames.deadOnArrival(Fixture.dm(1, sentAt: .max).envelope, ttl: ttl, now: .max))
        #expect(ScopeFrames.deadOnArrival(Fixture.dm(1, sentAt: .min).envelope, ttl: ttl, now: 0))
    }

    @Test func aPulledFrameIsLatePastItsScopeTTLOrFiveMinutesAhead() {
        let now = Fixture.wall
        #expect(!ScopeFrames.isLate(Fixture.dm(1, sentAt: now).envelope, now: now))
        #expect(ScopeFrames.isLate(Fixture.dm(1, sentAt: now - ScopeFrames.ttlMilliseconds).envelope, now: now))
        #expect(!ScopeFrames.isLate(Fixture.dm(1, sentAt: now + WireProtocol.maxFutureSkewMilliseconds).envelope, now: now))
        #expect(ScopeFrames.isLate(Fixture.dm(1, sentAt: now + WireProtocol.maxFutureSkewMilliseconds + 1).envelope, now: now))
        #expect(ScopeFrames.isLate(Fixture.dm(1, sentAt: .max).envelope, now: now))
        #expect(ScopeFrames.isLate(Fixture.dm(1, sentAt: .min).envelope, now: now))
        #expect(!ScopeFrames.isLate(Fixture.dm(1, sentAt: .max).envelope, now: .max))
    }

    @Test func aBlobOpensToACandidateThatOnlyItsSendersKeyMakesAFrame() throws {
        let frame = Fixture.dm(1, from: Fixture.bob, to: Fixture.alice)
        let sealed = Fixture.sealed(frame)
        let scope = Fixture.scope(for: Fixture.alice)
        let candidate = try #require(
            open(sealed, in: scope))
        #expect(candidate.claimedSender == bob && !candidate.isLate)
        #expect(candidate.verified(by: Fixture.carol.keys.bundle) == nil, "another node's key")
        #expect(candidate.verified(by: Fixture.alice.keys.bundle) == nil, "a member's, but not the sender's")
        let opened = try #require(candidate.verified(by: Fixture.bob.keys.bundle))
        #expect(opened.wire == WireEnvelope(sig: frame.wire.sig, signed: frame.wire.signed), "re-served: ttl 8, hops 0")
        #expect(opened.envelope == frame.envelope && opened.bridges)
    }

    @Test func aForgedSignatureNeverBecomesAFrame() throws {
        var frame = Fixture.dm(1, from: Fixture.bob, to: Fixture.alice)
        frame.wire.sig = try Fixture.carol.keys.signature(for: frame.wire.signed)
        let sealed = Fixture.sealed(frame)
        let candidate = try #require(
            open(sealed, source: .live))
        #expect(candidate.verified(by: Fixture.bob.keys.bundle) == nil)
    }

    @Test func openRefusesTheWrongAddressATamperAForeignScopeAndAFrameOutsideTheRule() throws {
        let scope = Fixture.scope(for: Fixture.alice)
        let sealed = Fixture.sealed(Fixture.dm(1))
        func opens(_ id: SpoolID, _ blob: [UInt8], in scope: SpoolScope = scope) -> Bool {
            open(SealedBlob(id: id, blob: blob), in: scope) != nil
        }
        #expect(opens(sealed.id, sealed.blob))
        #expect(!opens(SpoolSessionFixture.id(3), sealed.blob))
        var tampered = sealed.blob
        tampered[tampered.count - 1] ^= 1
        #expect(!opens(try #require(SpoolID(ScopeCrypto.blobId(of: tampered))), tampered))
        #expect(!opens(sealed.id, sealed.blob, in: Fixture.scope(for: Fixture.alice, seed: 41)))
        let third = Fixture.sealed(Fixture.dm(2, from: Fixture.carol, to: Fixture.alice))
        #expect(!opens(third.id, third.blob))
        let v1 = Fixture.sealed(Fixture.dm(3, version: 1))
        #expect(!opens(v1.id, v1.blob))
    }

    @Test func openRefusesAnIdNotInItsMintedShape() {
        let sealed = Fixture.sealed(Fixture.dm(1, id: "not-a-canonical-id"))
        #expect(
            open(sealed)
                == nil)
    }

    @Test func aLateFrameOpensMarkedLateAndNeverBridges() throws {
        let frame = Fixture.dm(1, from: Fixture.bob, to: Fixture.alice, sentAt: Fixture.wall - ScopeFrames.ttlMilliseconds - 1)
        let sealed = Fixture.sealed(frame)
        let candidate = try #require(
            open(sealed))
        #expect(candidate.isLate)
        #expect(try #require(candidate.verified(by: Fixture.bob.keys.bundle)).bridges == false)
    }

    @Test func aCandidatePrintsPrefixesAlone() throws {
        let sealed = Fixture.sealed(Fixture.dm(1))
        let candidate = try #require(
            open(sealed))
        let printed = "\(candidate) \(String(reflecting: candidate))"
        #expect(!printed.contains(bob.string) && !printed.contains(alice.string))
        #expect(Mirror(reflecting: candidate).children.isEmpty)
    }

    @Test func theSealCacheSealsOnlyWhatTheCheapRuleLetsThroughAndHoldsItsBound() throws {
        var cache = ScopeSealCache()
        let scope = Fixture.scope(for: Fixture.alice)
        let frames = [
            Fixture.dm(1), Fixture.dm(2, from: Fixture.carol, to: Fixture.bob), Fixture.dm(3, version: 1), try profile(Fixture.bob),
        ]
        let held = cache.held(frames.map(Fixture.carried), in: scope, me: alice)
        #expect(held.map(\.id) == [Fixture.sealed(frames[0]).id, Fixture.sealed(frames[3]).id])
        #expect(cache.count == 3, "the v1 DM's refusal is remembered; the third party's frame is never looked at")
        for number in 0..<(ScopeSealCache.maxEntries + 10) {
            _ = cache.held([Fixture.carried(Fixture.dm(10 + number))], in: scope, me: alice)
        }
        #expect(cache.count == ScopeSealCache.maxEntries)
    }
}
