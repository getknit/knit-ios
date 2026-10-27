import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// What a want made for an asker may cost, one engine's books at a time (knit-ios #20, from knit-next's malicious-fork
/// review, H3 and H2's prefix item): an echo never evicts a want of ours, one asker has at most 16, the echo budget holds
/// an echo's fetch back and reserves room only for an echo with an ask standing on a holder or bytes on their way, and a
/// want of ours takes an echo over. The engine's half is ``MeshEngineEchoBudgetTests``.
@Suite struct BlobEchoBoundsTests {
    private let bob = TestPeer(seed: 2).nodeId
    private let carol = TestPeer(seed: 3).nodeId
    private let dave = TestPeer(seed: 4).nodeId

    private func hash(_ index: Int) -> BlobHash {
        BlobHash(of: Array("blob \(index)".utf8))
    }

    private func own(_ exchange: inout BlobExchange, _ hash: BlobHash, at now: Int64 = 0) {
        _ = exchange.recordWant(
            hash, now: now, wall: wallAt(now), author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: true))
    }

    private func echo(_ exchange: inout BlobExchange, _ hash: BlobHash, for asker: NodeId, at now: Int64 = 0) {
        _ = exchange.recordWant(hash, now: now, wall: wallAt(now), author: nil, via: nil, asker: asker, reach: .asked(pull: 3, until: nil))
    }

    // MARK: The want set

    @Test func aFullSetOfOurOwnTurnsEveryEchoAwayAndKeepsEachWant() {
        var exchange = BlobExchange(queriesHolders: true)
        for index in 0..<BlobExchange.maxWanted {
            own(&exchange, hash(index))
        }
        for index in 1000..<1300 {
            #expect(exchange.echoRefusal(hash(index)) == "every want is ours")
            echo(&exchange, hash(index), for: bob)
        }
        #expect(exchange.wanted == (0..<BlobExchange.maxWanted).map(hash), "not one of ours dropped, the order kept")
        #expect(exchange.ownWanted.count == BlobExchange.maxWanted)
        #expect(exchange.echoRefusal(hash(0)) == nil, "an ask for a hash wanted already only joins it")
        #expect(exchange.fairVictim(adding: bob, excluding: nil, arriving: []) == nil, "no echo to take an echo's room")
        #expect(exchange.fairVictim(adding: nil, excluding: nil, arriving: []) == hash(0), "ours alone: our oldest")
    }

    @Test func aFullSetDropsItsOldestEchoBeforeAnyWantOfOurs() {
        var exchange = BlobExchange(queriesHolders: true)
        own(&exchange, hash(0))
        echo(&exchange, hash(1), for: bob)
        echo(&exchange, hash(2), for: carol)
        for index in 3..<BlobExchange.maxWanted {
            own(&exchange, hash(index))
        }
        own(&exchange, hash(9000))
        #expect(!exchange.isWanted(hash(1)) && exchange.isWanted(hash(0)), "the oldest echo went, not the oldest want")
        echo(&exchange, hash(9001), for: dave)
        #expect(!exchange.isWanted(hash(2)) && exchange.isWanted(hash(9001)), "an echo takes an echo's place")
        own(&exchange, hash(9002))
        #expect(!exchange.isWanted(hash(9001)), "the last echo goes before a want of ours")
        own(&exchange, hash(9003))
        #expect(!exchange.isWanted(hash(0)) && exchange.isWanted(hash(9003)), "with no echo left, the oldest want of ours goes")
        #expect(exchange.wanted.count == BlobExchange.maxWanted)
    }

    /// A set of `own` wants of ours, then each asker's echoes in turn, `echoes` of each, so later tests fill it to the brim.
    private func filled(own count: Int, _ echoes: [(NodeId, Range<Int>)]) -> BlobExchange {
        var exchange = BlobExchange(queriesHolders: true)
        for (asker, range) in echoes {
            for index in range {
                echo(&exchange, hash(index), for: asker)
            }
        }
        for index in 0..<count {
            own(&exchange, hash(5000 + index))
        }
        return exchange
    }

    @Test func aFullSetDropsAnEchoOfTheAskerHoldingTheMostItsOldestFirst() {
        var exchange = filled(own: BlobExchange.maxWanted - 5, [(bob, 0..<2), (carol, 10..<13)])
        #expect(exchange.fairVictim(adding: nil, excluding: nil, arriving: []) == hash(10), "carol holds three to bob's two")
        own(&exchange, hash(9000))
        #expect(!exchange.isWanted(hash(10)) && exchange.isWanted(hash(0)))
        #expect(exchange.takeEvicted().map(\.hash) == [hash(10)])
    }

    @Test func aTieGoesToTheAskerWhoseOldestEchoIsOldestAndTheNewEchoCountsTowardItsAsker() {
        let exchange = filled(own: BlobExchange.maxWanted - 4, [(bob, 0..<2), (carol, 10..<12)])
        #expect(exchange.fairVictim(adding: nil, excluding: nil, arriving: []) == hash(0), "a tie: bob's oldest is the older")
        #expect(exchange.fairVictim(adding: carol, excluding: nil, arriving: []) == hash(10), "carol's new one makes her three")
        #expect(exchange.fairVictim(adding: dave, excluding: nil, arriving: []) == hash(0), "dave holds none to give")
    }

    @Test func ofTheLargestAskersEchoesOneWithNothingOnItsWayGoesFirst() {
        var exchange = filled(own: BlobExchange.maxWanted - 3, [(bob, 0..<3)])
        #expect(exchange.fairVictim(adding: nil, excluding: nil, arriving: [hash(0)]) == hash(1), "the oldest's bytes are arriving")
        _ = exchange.park(hash(1), for: carol, bytes: 1, reached: BlobExchange.Reached(), now: 0)
        #expect(exchange.fairVictim(adding: nil, excluding: nil, arriving: [hash(0)]) == hash(2), "an ask for the next is parked")
        #expect(exchange.fairVictim(adding: nil, excluding: nil, arriving: [hash(0), hash(2)]) == hash(0), "else its oldest")
        exchange.makeRoom(for: hash(9000), asker: nil, arriving: [hash(0)])
        #expect(exchange.takeEvicted().map(\.hash) == [hash(2)] && !exchange.isWanted(hash(2)))
        exchange.makeRoom(for: hash(0), asker: nil, arriving: [])
        #expect(exchange.takeEvicted().isEmpty, "a hash wanted already needs no room")
    }

    /// A fork flooding a full set churns its own echoes: a root that asks for fewer keeps every one of its.
    @Test func aForkFloodingAFullSetChurnsItsOwnEchoesAndLeavesTheRootsAndOurs() {
        var exchange = filled(own: 100, [(carol, 0..<40)])
        for index in 1000..<1300 {
            exchange.makeRoom(for: hash(index), asker: bob, arriving: [])
            echo(&exchange, hash(index), for: bob)
        }
        #expect((0..<40).allSatisfy { exchange.isWanted(hash($0)) }, "the root's forty all stand")
        #expect((0..<100).allSatisfy { exchange.isWanted(hash(5000 + $0)) }, "and every want of ours")
        #expect(exchange.wanted.count == BlobExchange.maxWanted)
        #expect(exchange.wants.values.count { $0.echoFor == bob } == BlobExchange.maxWanted - 140)
    }

    @Test func aWantDroppedForAFullSetIsHandedBackWithTheAsksStandingOnIt() {
        var exchange = BlobExchange(queriesHolders: true)
        let holder = [BlobExchange.Candidate(id: dave, streaming: false, capable: true)]
        echo(&exchange, hash(0), for: bob)
        _ = exchange.decide(hash(0), among: holder, now: 0, wall: wallAt(0))
        _ = exchange.recordAnswers(BlobHasContent(items: [BlobHasItem(hash: hash(0).string, state: .have)]), from: dave, now: 1)
        let fetch = exchange.decide(hash(0), among: holder, now: 1, wall: wallAt(1))
        #expect(fetch.asks == [BlobExchange.Ask(to: dave, line: .fetch)])
        for index in 1...BlobExchange.maxWanted {
            own(&exchange, hash(index))
        }
        let evicted = exchange.takeEvicted()
        #expect(evicted.map(\.hash) == [hash(0)] && evicted.first?.asks == [dave])
        #expect(exchange.takeEvicted().isEmpty, "handed back once")
    }

    @Test func aWantOfOursTakesAnEchoOverAndAReaskFromZeroIsOurs() {
        var exchange = BlobExchange(queriesHolders: true)
        echo(&exchange, hash(1), for: bob)
        #expect(exchange.isEcho(hash(1)) && exchange.ownWanted.isEmpty)
        own(&exchange, hash(1), at: 10)
        #expect(!exchange.isEcho(hash(1)) && exchange.ownWanted == [hash(1)])
        #expect(exchange.wants[hash(1)]?.budget == BlobExchange.pullBudget)
        echo(&exchange, hash(1), for: carol)
        #expect(!exchange.isEcho(hash(1)), "an ask never turns ours back into an echo")

        echo(&exchange, hash(2), for: bob)
        let first = exchange.promote(hash(2))
        let second = exchange.promote(hash(2))
        #expect(first && !second, "promoted once")
        #expect(exchange.wants[hash(2)]?.budget == 2, "its budget left for the next re-arm")
        let none = exchange.promote(hash(3))
        #expect(!none, "nothing wanted, nothing promoted")

        exchange.restartFromZero(hash(4), failing: nil, now: 0, wall: wallAt(0))
        #expect(exchange.ownWanted.contains(hash(4)) && exchange.wants[hash(4)]?.budget == 0)
    }

    // MARK: The budget

    @Test func onlyAnEchoAskingAHolderOrArrivingReservesRoom() {
        var exchange = BlobExchange(queriesHolders: true)
        let file = Int64(FileIntake.maxFileBytes)
        let linked = [BlobExchange.Candidate(id: dave, streaming: false, capable: true)]
        echo(&exchange, hash(1), for: bob)
        echo(&exchange, hash(2), for: bob)
        echo(&exchange, hash(3), for: bob)
        own(&exchange, hash(4))
        // Each queries dave: the first two he holds, the third nobody does.
        for index in 1...4 {
            _ = exchange.decide(hash(index), among: linked, now: 0, wall: wallAt(0))
        }
        let items = [
            BlobHasItem(hash: hash(1).string, state: .have), BlobHasItem(hash: hash(2).string, state: .have),
            BlobHasItem(hash: hash(3).string, state: .notHeld), BlobHasItem(hash: hash(4).string, state: .have),
        ]
        _ = exchange.recordAnswers(BlobHasContent(items: items), from: dave, now: 10)
        #expect(exchange.echoReservedBytes(arriving: [], excluding: nil) == 0, "no ask made yet")
        for index in 1...4 {
            _ = exchange.decide(hash(index), among: linked, now: 10, wall: wallAt(10))
        }
        #expect(
            exchange.echoReservedBytes(arriving: [], excluding: nil) == 2 * file,
            "two echoes fetching; the dead one and ours reserve nothing")
        #expect(exchange.echoReservedBytes(arriving: [], excluding: hash(1)) == file)
        #expect(
            exchange.echoReservedBytes(arriving: [hash(3), hash(4)], excluding: nil) == 3 * file, "an echo's bytes arriving reserve too")

        var blind = BlobExchange(queriesHolders: true)
        echo(&blind, hash(5), for: bob)
        let plan = blind.decide(
            hash(5), among: [BlobExchange.Candidate(id: dave, streaming: false, capable: false)], now: 0, wall: wallAt(0))
        #expect(plan.asks.map(\.line) == [.first])
        #expect(blind.echoReservedBytes(arriving: [], excluding: nil) == 0, "a blind ask reserves nothing")
    }

    @Test func anEchoWithNoRoomAsksNobodyNewWhileOneOfOursAndAStandingAskGoOn() {
        var exchange = BlobExchange(queriesHolders: true)
        let linked = [BlobExchange.Candidate(id: dave, streaming: false, capable: true)]
        echo(&exchange, hash(1), for: bob)
        own(&exchange, hash(2))
        let held = exchange.decide(hash(1), among: linked, now: 0, wall: wallAt(0), echoRoom: false)
        #expect(held.query.isEmpty && held.asks.isEmpty && held.wake == nil)
        #expect(held.notes == ["blob no-fetch \(hash(1).string.prefix(8))… for \(bob) (over budget)"])
        let again = exchange.decide(hash(1), among: linked, now: 1, wall: wallAt(1), echoRoom: false)
        #expect(again.notes.isEmpty, "logged once a cycle")
        #expect(exchange.counts.echoFetchesHeld == 1)
        let ours = exchange.decide(hash(2), among: linked, now: 0, wall: wallAt(0), echoRoom: false)
        #expect(ours.query == [dave], "a want of ours ignores the echo budget")

        // With room, the echo queries and fetches; then the room goes, and its ask stands to its floor.
        _ = exchange.decide(hash(1), among: linked, now: 2, wall: wallAt(2))
        _ = exchange.recordAnswers(BlobHasContent(items: [BlobHasItem(hash: hash(1).string, state: .have)]), from: dave, now: 3)
        let fetch = exchange.decide(hash(1), among: linked, now: 3, wall: wallAt(3))
        #expect(fetch.asks == [BlobExchange.Ask(to: dave, line: .fetch)])
        let standing = exchange.decide(hash(1), among: linked, now: 4, wall: wallAt(4), echoRoom: false)
        #expect(standing.wake != nil && exchange.wants[hash(1)]?.fetch?.peer == dave, "the ask stands")
    }

    @Test func theBudgetReadsHighUntilItIsMeasuredAndRemembersWhatItRefused() {
        var budget = EchoBudget()
        let limit = BlobExchange.echoBudgetBytes
        #expect(!budget.isSpent(reserved: limit - 1) && budget.isSpent(reserved: limit))
        #expect(budget.fits(limit, reserved: 0) && !budget.fits(limit + 1, reserved: 0))
        budget.landed(limit - 10)
        #expect(budget.fits(10, reserved: 0) && !budget.fits(11, reserved: 0))
        #expect(budget.isSpent(reserved: 10))
        #expect(budget.mayRemeasure(now: 0), "never measured")
        budget.measured(5, at: 1000)
        #expect(budget.heldForOthers == 5)
        #expect(!budget.mayRemeasure(now: 1000 + BlobExchange.echoRemeasureMilliseconds - 1))
        budget.tried(at: 50_000)
        #expect(budget.heldForOthers == 5, "a failed measure keeps the last")
        #expect(budget.mayRemeasure(now: 50_000 + BlobExchange.echoRemeasureMilliseconds))

        budget.refuse(hash(0))
        budget.refuse(hash(0))
        for index in 1..<BlobExchange.maxRefusedEchoes {
            budget.refuse(hash(index))
        }
        #expect(budget.hasRefused(hash(0)), "a hash refused twice takes one place, so the bound still holds it")
        budget.refuse(hash(BlobExchange.maxRefusedEchoes))
        #expect(!budget.hasRefused(hash(0)) && budget.hasRefused(hash(1)) && budget.hasRefused(hash(BlobExchange.maxRefusedEchoes)))
        budget.forgetRefused()
        #expect(!budget.hasRefused(hash(1)))
    }
}
