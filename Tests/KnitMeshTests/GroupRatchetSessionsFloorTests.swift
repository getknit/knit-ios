import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The group facade's floors held in memory, Kotlin's (`GroupRatchetSessions.kt:36-43`, `:218-290`, at `cbf2a487`), which
/// die with the process as Kotlin's do: at most four fresh adoptions a day per group and sender, the skipped-key pump's
/// bound, and the key-request heuristic, three distinct undecryptable frames from a group's sender, under an hour's floor
/// and behind the 48 h age gate (`InboundPipeline.kt:1700-1701`). Every key is a group, by its bytes, and a sender.
@Suite struct GroupRatchetSessionsFloorTests {
    static let kinds = GroupSessionKind.allCases
    static let group = "g-0123456789abcdef01234567"
    static let now: Int64 = 1_700_000_000_000
    static let day = GroupRatchetSessions.adoptionWindowMilliseconds
    static let hour = GroupRatchetSessions.keyRequestMilliseconds

    let alice = fixtureNodeId(1)
    let bob = fixtureNodeId(2)
    let carol = fixtureNodeId(3)

    func seed(_ epoch: Int, mintedAt: Int64 = Self.now) -> GroupSeed {
        GroupSeed(epoch: epoch, seed: fixtureBytes(32, seed: epoch), mintedAt: mintedAt)
    }

    /// Four fresh chains a day per group and sender, the ones a call makes counted as it makes them; the fifth is floored,
    /// neither stored nor acknowledged, until the oldest is a day old. A re-serve and a stale mint cost nothing, and
    /// another sender, or the same sender in another group, has a floor of its own.
    @Test(arguments: kinds)
    func atMostFourFreshAdoptionsADayPerGroupAndSender(kind: GroupSessionKind) throws {
        let made = try kind.make()
        let sessions = made.sessions(bob)
        let five = sessions.adoptSeeds((1...5).map { seed($0) }, in: Self.group, from: alice, now: Self.now)
        let floored = GroupRatchetSessions.Adoption(
            ackEpoch: 4, freshChains: 4, verdicts: [.adopted, .adopted, .adopted, .adopted, .floored])
        #expect(five == .settled(floored))
        #expect(made.store.recvChains(Self.group, from: alice, epoch: 5).isEmpty, "the floored seed was not stored")
        #expect(sessions.floors(in: Self.group, for: alice, now: Self.now).adoptions == 4)

        let reServed = sessions.adoptSeeds([seed(1), seed(2, mintedAt: Self.now - 1)], in: Self.group, from: alice, now: Self.now + 1)
        #expect(reServed == .settled(GroupRatchetSessions.Adoption(ackEpoch: 1, freshChains: 0, verdicts: [.alreadyKnown, .stale])))
        let stillFloored = GroupRatchetSessions.Adoption(ackEpoch: nil, freshChains: 0, verdicts: [.floored])
        #expect(sessions.adoptSeeds([seed(5)], in: Self.group, from: alice, now: Self.now + Self.day - 1) == .settled(stillFloored))

        #expect(sessions.adoptSeeds([seed(5)], in: Self.group, from: carol, now: Self.now).freshChains == 1, "another sender")
        _ = sessions.adoptSeeds((1...4).map { seed($0) }, in: "g-K", from: alice, now: Self.now)
        #expect(sessions.adoptSeeds([seed(5)], in: "g-K", from: alice, now: Self.now).freshChains == 0)
        #expect(sessions.adoptSeeds([seed(5)], in: "g-\u{212A}", from: alice, now: Self.now).freshChains == 1, "a group Swift calls equal")

        let nextDay = sessions.adoptSeeds([seed(5)], in: Self.group, from: alice, now: Self.now + Self.day)
        #expect(nextDay == .settled(GroupRatchetSessions.Adoption(ackEpoch: 5, freshChains: 1, verdicts: [.adopted])))
        #expect(sessions.floors(in: Self.group, for: alice, now: Self.now + Self.day).adoptions == 1, "the day's first four aged out")
    }

    /// Three distinct frames fire a request, a re-serve of one never counts twice, and the ids held stop at eight; once
    /// the request goes, the ids clear and the next waits an hour (`noteUndecryptable` and `markKeyRequested`,
    /// `GroupRatchetSessions.kt:232-267`).
    @Test func aKeyRequestIsDueAtThreeDistinctFramesAndThenWaitsAnHour() {
        let sessions = GroupRatchetSessions(nodeId: bob, store: MemoryGroupRatchetStore(), transactor: MemoryTransactor(stores: []))
        func note(
            _ id: String, at now: Int64 = Self.now, sentAt: Int64 = Self.now, from sender: NodeId? = nil, in group: String = Self.group
        ) -> Bool {
            sessions.noteUndecryptable(in: group, from: sender ?? alice, frameId: id, sentAt: sentAt, now: now)
        }
        #expect(!note("f1") && !note("f2") && !note("f1"), "a re-serve of one frame never counts twice")
        #expect(note("f3"))
        #expect(note("f4"), "still due until the request goes")
        #expect(!(5...12).map { note("f\($0)") }.contains(false), "each later frame finds it due")
        #expect(sessions.floors(in: Self.group, for: alice, now: Self.now).undecryptableIds == GroupRatchetSessions.requestTrackedFrames)

        sessions.markKeyRequested(in: Self.group, from: alice, now: Self.now)
        #expect(
            sessions.floors(in: Self.group, for: alice, now: Self.now)
                == GroupRatchetSessions.Floors(
                    adoptions: 0, undecryptableIds: 0, lastKeyRequestAt: Self.now))
        #expect(
            !note("g1", at: Self.now + 1) && !note("g2", at: Self.now + 2) && !note("g3", at: Self.now + Self.hour - 1), "inside the hour")
        #expect(note("g4", at: Self.now + Self.hour))

        // Each group and sender holds its own, a group by its bytes.
        #expect(!note("h1", from: carol) && !note("h2", from: carol))
        #expect(!note("k1", in: "g-K") && !note("k2", in: "g-\u{212A}") && !note("k3", in: "g-K"))
    }

    /// The age gate (`InboundPipeline.kt:1700`): a frame more than two days older than our clock by its own stamp counts
    /// nothing and joins no id, so an ancient replay never spends the budget; one exactly two days old counts, and one
    /// from a clock running fast counts too.
    @Test func aFrameOlderThanTwoDaysByItsOwnStampCountsNothing() {
        let sessions = GroupRatchetSessions(nodeId: bob, store: MemoryGroupRatchetStore(), transactor: MemoryTransactor(stores: []))
        let limit = GroupRatchetSessions.requestMaxFrameAgeMilliseconds
        for id in ["a", "b", "c"] {
            #expect(!sessions.noteUndecryptable(in: Self.group, from: alice, frameId: id, sentAt: Self.now - limit - 1, now: Self.now))
        }
        #expect(sessions.floors(in: Self.group, for: alice, now: Self.now).undecryptableIds == 0)
        #expect(!sessions.noteUndecryptable(in: Self.group, from: alice, frameId: "d", sentAt: Self.now - limit, now: Self.now))
        #expect(!sessions.noteUndecryptable(in: Self.group, from: alice, frameId: "e", sentAt: Self.now + 600_000, now: Self.now))
        #expect(sessions.noteUndecryptable(in: Self.group, from: alice, frameId: "f", sentAt: Self.now, now: Self.now))
    }

    /// A settlement that adopted nothing moves nothing.
    @Test func aSettlementOfNoAdoptionMovesNothing() {
        let sessions = GroupRatchetSessions(nodeId: bob, store: MemoryGroupRatchetStore(), transactor: MemoryTransactor(stores: []))
        sessions.settle(.unchanged)
        sessions.settle(GroupRatchetSessions.Settlement(adopter: .init(Self.group, alice), adoptions: 0, at: Self.now))
        #expect(
            sessions.floors(in: Self.group, for: alice, now: Self.now)
                == GroupRatchetSessions.Floors(
                    adoptions: 0, undecryptableIds: 0, lastKeyRequestAt: nil))
    }
}
