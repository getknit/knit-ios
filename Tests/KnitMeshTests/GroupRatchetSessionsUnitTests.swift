import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The group facade's store unit and the floors it holds in memory (ADR 2026-10.5sk9, phase P6a1): a call inside a unit
/// its caller opened answers `.joined`, stands only with that unit, and moves its floor only once the caller settles
/// after the outermost commit (P4c's lesson); a store that fails answers `.failed` and changes nothing; and the floors
/// are Kotlin's, held in memory as Kotlin holds them (`GroupRatchetSessions.kt:36-43`, `:218-290`): four fresh adoptions a
/// day per group and sender, and the key-request heuristic's three distinct frames under an hour's floor.
@Suite struct GroupRatchetSessionsUnitTests {
    static let kinds = GroupSessionKind.allCases
    static let group = "g-0123456789abcdef01234567"
    static let now: Int64 = 1_700_000_000_000

    let alice = fixtureNodeId(1)
    let bob = fixtureNodeId(2)

    func seed(_ epoch: Int, mintedAt: Int64 = Self.now) -> GroupSeed {
        GroupSeed(epoch: epoch, seed: fixtureBytes(32, seed: epoch), mintedAt: mintedAt)
    }

    @Test(arguments: kinds)
    func aJoinedAdoptionMovesItsFloorOnlyOnceTheOuterUnitCommits(kind: GroupSessionKind) throws {
        let made = try kind.make()
        let sessions = made.sessions(bob)
        var inside: GroupRatchetSessions.Floors?
        let outer = made.transactor.atomically { () -> GroupRatchetSessions.Settlement? in
            guard case .joined(let adoption, let settlement) = sessions.adoptSeeds([seed(1)], in: Self.group, from: alice, now: Self.now),
                adoption.verdicts == [.adopted]
            else {
                return nil
            }
            inside = sessions.floors(in: Self.group, for: alice, now: Self.now)
            return settlement
        }
        #expect(inside?.adoptions == 0, "nothing moves inside the caller's unit")
        guard case .committed(let settlement) = outer else {
            Issue.record("the outer unit commits: \(outer)")
            return
        }
        #expect(sessions.floors(in: Self.group, for: alice, now: Self.now).adoptions == 0, "nor once it commits, before the settlement")
        sessions.settle(settlement)
        #expect(sessions.floors(in: Self.group, for: alice, now: Self.now).adoptions == 1)
        #expect(made.store.recvChains(Self.group, from: alice, epoch: 1).count == 1, "the chain stood with the outer unit")
    }

    @Test(arguments: kinds)
    func aJoinedAdoptionWhoseOuterUnitFailsStoresNothingAndMovesNoFloor(kind: GroupSessionKind) throws {
        let made = try kind.make()
        let sessions = made.sessions(bob)
        var joined = false
        let outer = made.transactor.atomically { () -> Int? in
            if case .joined = sessions.adoptSeeds([seed(1)], in: Self.group, from: alice, now: Self.now) {
                joined = true
            }
            made.failCurrentUnit()
            return 1
        }
        #expect(joined && outer == .failed)
        #expect(made.store.holdings(of: Self.group) == .empty, "the adoption rolled back with the unit")
        #expect(sessions.floors(in: Self.group, for: alice, now: Self.now).adoptions == 0)
    }

    /// A seal and an open inside the caller's unit join it: their chains stand only once it commits, and with it fail.
    @Test(arguments: kinds)
    func aJoinedSealAndAJoinedOpenStandOnlyWithTheOuterUnit(kind: GroupSessionKind) throws {
        for fails in [true, false] {
            let sending = try kind.make()
            let receiving = try kind.make()
            let aliceSessions = sending.sessions(alice)
            let sealed = sending.transactor.atomically { () -> GroupRatchetSessions.Answer<GroupRatchetSessions.Sealing>? in
                let answer = aliceSessions.sealGroup(plaintext: Array("hi".utf8), aad: [1], in: Self.group, now: Self.now)
                if fails {
                    sending.failCurrentUnit()
                }
                return answer
            }
            guard !fails else {
                #expect(sealed == .failed)
                #expect(sending.store.holdings(of: Self.group) == .empty, "the mint rolled back with the unit")
                continue
            }
            guard case .committed(.joined(.sealed(let envelope, let minted?), let settlement)) = sealed else {
                Issue.record("a seal inside the caller's unit joins it: \(sealed)")
                return
            }
            aliceSessions.settle(settlement)
            #expect(sending.store.sendChain(Self.group)?.count == 1)
            let bobSessions = receiving.sessions(bob)
            _ = bobSessions.adoptSeeds([minted], in: Self.group, from: alice, now: Self.now)
            let frame = try #require(GroupRatchetSessions.Frame(envelope: envelope, aad: [1]))
            for opensFail in [true, false] {
                let opened = receiving.transactor.atomically { () -> GroupRatchetSessions.Answer<GroupRatchetSessions.Opening<Int>>? in
                    let answer = bobSessions.open(frame, in: Self.group, from: alice, now: Self.now + 1) { _ in 1 }
                    if opensFail {
                        receiving.failCurrentUnit()
                    }
                    return answer
                }
                let next = receiving.store.recvChains(Self.group, from: alice, epoch: 1).map(\.next)
                if opensFail {
                    #expect(opened == .failed && next == [0], "the open rolled back with the unit")
                } else {
                    #expect(opened == .committed(.joined(.opened(plaintext: Array("hi".utf8), work: 1), .unchanged)) && next == [1])
                }
            }
        }
    }

    /// A store that fails answers `.failed` from every call, a read's failure as much as a write's, and nothing moves: no
    /// row, no floor, and no decision on the store's fallback, such as `NO_KEY` or no seeds.
    @Test func aStoreThatFailsAnswersFailedAndChangesNothing() throws {
        let refusing = RefusingGroupRatchetStore()
        let sessions = GroupRatchetSessions(nodeId: bob, store: refusing, transactor: refusing.transactor)
        let sealing = sessions.sealGroup(plaintext: [1], aad: [2], in: Self.group, now: Self.now)
        guard case .settled(.sealed(let envelope, let minted?)) = sealing else {
            Issue.record("the store heals first: \(sealing)")
            return
        }
        _ = sessions.adoptSeeds([minted], in: Self.group, from: bob, now: Self.now)
        let before = refusing.held.holdings(of: Self.group)
        let frame = try #require(GroupRatchetSessions.Frame(envelope: envelope, aad: [2]))

        refusing.refuse(.writes)
        #expect(sessions.sealGroup(plaintext: [1], aad: [2], in: Self.group, now: Self.now) == .failed)
        #expect(sessions.adoptSeeds([seed(2)], in: Self.group, from: alice, now: Self.now) == .failed)
        #expect(sessions.open(frame, in: Self.group, from: bob, now: Self.now) { _ in 1 } == .failed)
        #expect(sessions.markKeySent(1, to: alice, in: Self.group, now: Self.now) == .failed)
        #expect(sessions.onKeyAck(1, from: alice, in: Self.group, now: Self.now) == .failed)
        #expect(!sessions.sweep(now: Self.now), "a sweep the store refused stood not")
        refusing.refuse(.reads)
        #expect(sessions.currentSeeds(of: Self.group) == .failed, "never no seeds")
        #expect(sessions.keySend(to: alice, in: Self.group) == .failed)
        #expect(sessions.open(frame, in: Self.group, from: bob, now: Self.now) { _ in 1 } == .failed, "never NO_KEY")
        #expect(sessions.adoptSeeds([seed(2)], in: Self.group, from: alice, now: Self.now) == .failed)

        refusing.refuse([])
        #expect(refusing.held.holdings(of: Self.group) == before)
        #expect(sessions.floors(in: Self.group, for: alice, now: Self.now).adoptions == 0)
        #expect(sessions.floors(in: Self.group, for: bob, now: Self.now).adoptions == 1, "only the adoption that stood")
        #expect(sessions.open(frame, in: Self.group, from: bob, now: Self.now) { _ in 1 } == .settled(.opened(plaintext: [1], work: 1)))
    }

    /// The sweep runs in a unit of its own and says whether it stood, inside a caller's unit too.
    @Test(arguments: kinds)
    func theSweepStandsInAUnitOfItsOwnOrJoined(kind: GroupSessionKind) throws {
        let made = try kind.make()
        let sessions = made.sessions(bob)
        #expect(sessions.sweep(now: Self.now))
        let outer = made.transactor.atomically { () -> Int? in sessions.sweep(now: Self.now) ? 1 : 0 }
        #expect(outer == .committed(1))
    }
}
