import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// What the reset heuristic takes as evidence (`maybeRequestReset`, `InboundPipeline.kt:1835-1856`): the era gate runs
/// inside ``RatchetSessions/noteUndecryptable(from:frameId:sentAt:now:)``, on the session it reads in a unit, before a
/// frame touches the heuristic's ids, and a unit that cannot read the session counts nothing (knit-next `d7487392`, ADR
/// 024 and ADR 026). `sentAt` is the stamp as signed, never clamped to our clock (knit-next `cf447a9b`).
@Suite struct RatchetSessionsEvidenceTests {
    static let t0: Int64 = 100_000_000
    static let skew = WireProtocol.maxFutureSkewMilliseconds
    static let tail = RatchetResetPolicy.strandedTailMilliseconds

    /// A store that cannot read the session counts nothing: a pre-era frame let in on its fallback would join the ids,
    /// and three of them would re-root on evidence from the era a reset abandons.
    @Test func aSessionTheStoreCannotReadCountsNothing() throws {
        let refusing = RefusingRatchetStore()
        let (alice, bob) = try RatchetSessionSide.pair(refusing: refusing)
        refusing.refuse(.reads)
        for id in ["a", "b", "c", "d"] {
            #expect(!note(alice, id, sentAt: Self.t0, now: Self.t0))
        }
        #expect(alice.sessions.floors(for: bob.nodeId).undecryptableIds == 0)

        refusing.refuse([])
        #expect(!note(alice, "a", sentAt: Self.t0, now: Self.t0))
        #expect(!note(alice, "b", sentAt: Self.t0, now: Self.t0))
        #expect(note(alice, "c", sentAt: Self.t0, now: Self.t0), "three ids, every one counted once the store reads again")
    }

    /// A responder's era starts at the peer's own `init.at`. A frame the peer stamped before it is the tail of an era left
    /// behind, unreadable by construction: it never reaches the ids, where a re-served tail would evict the live failures.
    @Test func aFrameFromBeforeTheEraLeavesTheIdsAlone() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        #expect(plaintext(try alice.open(bob.seal("hello", now: Self.t0), now: Self.t0)) != nil)
        let held = try #require(alice.session)
        #expect(!held.weAreInitiator && held.establishedAt == Self.t0)
        // Long past every window: a responder compares one clock, and has no escape.
        let later = Self.t0 + 2 * Self.tail
        #expect(!note(alice, "live", sentAt: Self.t0, now: later))
        for id in ["tail-a", "tail-b", "tail-c"] {
            #expect(!note(alice, id, sentAt: Self.t0 - 1, now: later))
        }
        #expect(alice.sessions.floors(for: bob.nodeId).undecryptableIds == 1, "the tail never joined the ids")
        #expect(!note(alice, "live-b", sentAt: Self.t0 + 1, now: later))
        #expect(note(alice, "live-c", sentAt: Self.t0 + 2, now: later))
    }

    /// A peer whose clock runs ten minutes fast: the era we answered starts at its own `init.at`, ten minutes ahead of our
    /// clock, and a live failure it stamps after that counts as stamped. Clamped to our clock, as the message row keeps
    /// it (`clampFuture`), the same stamp would read as before the era, and the heuristic would never fire toward it.
    @Test func aFastClockPeersLiveFailureCountsAsItWasStamped() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        let ahead = Self.t0 + 10 * 60_000
        #expect(plaintext(try alice.open(bob.seal("hello", now: ahead), now: Self.t0)) != nil)
        let held = try #require(alice.session)
        #expect(!held.weAreInitiator && held.establishedAt == ahead)
        let stamped = held.establishedAt + 1
        let clamped = min(stamped, Self.t0 + Self.skew)
        #expect(!RatchetResetPolicy.isLiveEvidence(sentAt: clamped, session: held, now: Self.t0), "clamped, it is pre-era")
        #expect(!note(alice, "a", sentAt: stamped, now: Self.t0))
        #expect(!note(alice, "b", sentAt: stamped, now: Self.t0))
        #expect(note(alice, "c", sentAt: stamped, now: Self.t0))
    }

    /// An initiator's `establishedAt` is our own clock: five minutes of the peer's skew are absorbed, an earlier stamp is
    /// the tail of an era left behind, and once the era is 48 h old every failure counts, whatever the peer's clock says,
    /// as `RatchetResetPolicyTests` pins for the rule alone (knit-next ADR 026).
    @Test func anInitiatorsGateAbsorbsSkewAndOpensOnceTheTailIsGone() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        #expect(plaintext(try bob.open(alice.seal("hello", now: Self.t0), now: Self.t0)) != nil)
        #expect(plaintext(try alice.open(bob.seal("hello back", now: Self.t0 + 1), now: Self.t0 + 1)) != nil)
        let held = try #require(alice.session)
        #expect(held.weAreInitiator && held.establishedAt == Self.t0)
        let young = Self.t0 + Self.tail - 1
        #expect(!note(alice, "early", sentAt: Self.t0 - Self.skew - 1, now: young))
        #expect(alice.sessions.floors(for: bob.nodeId).undecryptableIds == 0, "past the skew bound, a frame is the tail")
        #expect(!note(alice, "skewed", sentAt: Self.t0 - Self.skew, now: young))
        #expect(alice.sessions.floors(for: bob.nodeId).undecryptableIds == 1, "inside it, live")
        #expect(!note(alice, "old-a", sentAt: 0, now: Self.t0 + Self.tail))
        #expect(note(alice, "old-b", sentAt: 0, now: Self.t0 + Self.tail), "past 48 h no tail is left to protect")
    }

    /// Inside a caller's unit nothing counts: a joined open or reset clears the ids only once that unit commits, where
    /// Kotlin clears them as an open commits and as a reset is sealed (`RatchetSessions.kt:207-211`, `:435`, `:466`), so
    /// a frame counted before then would join the ids of the era the reset abandons. The same frames count once noted
    /// outside any unit.
    @Test func aCallInsideACallersUnitCountsNothing() throws {
        let (alice, bob) = try RatchetSessionSide.pair()
        var counted: [Bool] = []
        let outer = alice.transactor.atomically { () -> Int? in
            for id in ["a", "b", "c"] {
                counted.append(note(alice, id, sentAt: Self.t0, now: Self.t0))
            }
            return 1
        }
        #expect(outer == .committed(1))
        #expect(counted == [false, false, false])
        #expect(alice.sessions.floors(for: bob.nodeId).undecryptableIds == 0)

        #expect(!note(alice, "a", sentAt: Self.t0, now: Self.t0))
        #expect(!note(alice, "b", sentAt: Self.t0, now: Self.t0))
        #expect(note(alice, "c", sentAt: Self.t0, now: Self.t0))
    }

    /// Notes an undecryptable frame from `side`'s peer at `side`.
    private func note(_ side: RatchetSessionSide, _ frameId: String, sentAt: Int64, now: Int64) -> Bool {
        side.sessions.noteUndecryptable(from: side.peer.nodeId, frameId: frameId, sentAt: sentAt, now: now)
    }
}
