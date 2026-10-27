import KnitMesh
import KnitTestSupport
import KnitWire
import Testing

/// Recovering a missing key hop by hop, ported from knit-next's `KeyExchangeTest`.
@Suite struct KeyExchangeTests {
    private let me = fixtureNodeId(1)
    private let wanted = fixtureNodeId(2)
    private let neighbor = fixtureNodeId(3)

    /// The `n`th of many distinct node ids; `fixtureNodeId` wraps at 256 seeds.
    private func nodeId(_ n: Int) -> NodeId {
        guard let id = NodeId(bytes: [0xAB, UInt8(n >> 8), UInt8(n & 0xFF)] + Array(repeating: 0, count: 13)) else {
            fatalError("any 16 bytes are a node id")
        }
        return id
    }

    private func profile(_ seed: UInt8) -> WireEnvelope {
        WireEnvelope(sig: [seed], signed: [seed, seed])
    }

    @Test func aWantAsksNowThenWaitsOutTheCooldown() {
        var exchange = KeyExchange()
        let first = exchange.want(wanted, me: me, now: 0)
        let repeated = exchange.want(wanted, me: me, now: 29_999)
        let afterCooldown = exchange.want(wanted, me: me, now: 30_000)
        #expect(first)
        #expect(!repeated)
        #expect(afterCooldown)
        #expect(exchange.missingIds == [wanted])
    }

    @Test func ourOwnKeyAndAHeldKeyAreNeverWanted() {
        var exchange = KeyExchange()
        _ = exchange.onProfilePinned(wanted, wire: profile(1), now: 0)
        let own = exchange.want(me, me: me, now: 0)
        let held = exchange.want(wanted, me: me, now: 0)
        #expect(!own && !held)
        #expect(exchange.missingIds.isEmpty)
    }

    @Test func aHolderServesTheCachedProfilePointToPoint() {
        var exchange = KeyExchange()
        let cached = profile(7)
        _ = exchange.onProfilePinned(wanted, wire: cached, now: 0)
        let answer = exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0)
        #expect(answer.serve == [WireEnvelope(relay: false, sig: cached.sig, signed: cached.signed)])
        #expect(answer.ask.isEmpty)
        #expect(exchange.cachedProfile(of: wanted) == cached)
    }

    @Test func aHolderWhoseCacheARestartEmptiedAnswersFromItsPinStore() {
        // Only the signed frame its pin came from is left (knit-next ADR 2026-09.g64k): the request is answered from
        // there, asks nobody else, and the frame is cached on the way out.
        let kept = profile(9)
        var exchange = KeyExchange { [wanted] in $0 == wanted ? kept : nil }
        let answer = exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0)
        #expect(answer.serve == [WireEnvelope(relay: false, sig: kept.sig, signed: kept.signed)])
        #expect(answer.ask.isEmpty)
        #expect(exchange.missingIds.isEmpty)
        #expect(exchange.cachedProfile(of: wanted) == kept)
    }

    @Test func serveKeyHandsTheHeldProfileOverPointToPointAndNothingWhenNoneIsHeld() {
        let pinned = profile(1)
        let stored = profile(2)
        var exchange = KeyExchange { [wanted] in $0 == wanted ? stored : nil }
        #expect(exchange.serveKey(wanted) == WireEnvelope(relay: false, sig: stored.sig, signed: stored.signed), "from the pin store")
        #expect(exchange.serveKey(neighbor) == nil, "no key held for it")
        _ = exchange.onProfilePinned(wanted, wire: pinned, now: 0)
        #expect(exchange.serveKey(wanted) == WireEnvelope(relay: false, sig: pinned.sig, signed: pinned.signed), "the cache first")
    }

    @Test func aNonHolderAsksOnTheRequestersBehalfAndServesItLater() {
        var exchange = KeyExchange()
        let answer = exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0)
        #expect(answer.serve.isEmpty)
        #expect(answer.ask == [wanted])
        let waiting = exchange.onProfilePinned(wanted, wire: profile(4), now: 0)
        #expect(waiting == [neighbor])
        #expect(exchange.missingIds.isEmpty, "the want is settled")
        let again = exchange.onProfilePinned(wanted, wire: profile(4), now: 0)
        #expect(again.isEmpty, "each wanter is served once")
    }

    @Test func aRequestSkipsOurOwnIdTheCapAndAnythingNotANodeId() {
        var exchange = KeyExchange()
        let flood = (0..<200).map { nodeId($0).string }
        let answer = exchange.onRequest([me.string, "not-a-node-id"] + flood, from: neighbor, me: me, now: 0)
        #expect(answer.ask.count == KeyExchange.maxRequestIds - 2)
        #expect(!answer.ask.contains(me))
    }

    @Test func theWantedListEvictsItsOldestPastTheCap() {
        var exchange = KeyExchange()
        for n in 0...KeyExchange.maxMissing {
            _ = exchange.want(nodeId(n), me: me, now: 0)
        }
        #expect(exchange.missingIds.count == KeyExchange.maxMissing)
        #expect(exchange.missingIds.first == nodeId(1))
    }

    @Test func theWantersListEvictsItsOldestPastTheCap() {
        var exchange = KeyExchange()
        let ids = (0...KeyExchange.maxWanters).map(nodeId)
        for id in ids {
            _ = exchange.onRequest([id.string], from: neighbor, me: me, now: 0)
        }
        let dropped = exchange.onProfilePinned(ids[0], wire: profile(1), now: 0)
        let kept = exchange.onProfilePinned(ids[1], wire: profile(1), now: 0)
        #expect(dropped.isEmpty, "the oldest relayed want was dropped")
        #expect(kept == [neighbor])
    }

    @Test func theSweepDropsOnlyStaleWants() {
        var exchange = KeyExchange()
        _ = exchange.want(wanted, me: me, now: 0)
        _ = exchange.want(neighbor, me: me, now: 80)
        let swept = exchange.sweep(now: KeyExchange.missingMilliseconds + 1)
        #expect(swept == 1)
        #expect(exchange.missingIds == [neighbor])
    }

    @Test func requestsAreChunkedToTheirCap() {
        let ids = (0..<300).map(nodeId)
        let chunks = KeyExchange.chunked(ids)
        #expect(chunks.map(\.count) == [128, 128, 44])
        #expect(chunks.flatMap(\.self) == ids)
        #expect(KeyExchange.chunked([]).isEmpty)
    }

    @Test func twoNeighboursWaitingForOneKeyAreBothServed() {
        var exchange = KeyExchange()
        let other = fixtureNodeId(4)
        let first = exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0)
        let second = exchange.onRequest([wanted.string], from: other, me: me, now: 1)
        #expect(first.ask == [wanted])
        #expect(second.ask.isEmpty, "inside the cooldown")
        let waiting = exchange.onProfilePinned(wanted, wire: profile(2), now: 0)
        #expect(waiting == [neighbor, other])
    }

    // MARK: The answer budget (ADR 2026-10.f5zs, rule 5)

    /// A profile whose signed bytes are `bytes` long.
    private func profile(_ seed: UInt8, bytes: Int) -> WireEnvelope {
        WireEnvelope(sig: [seed], signed: Array(repeating: seed, count: bytes))
    }

    /// The bytes a held profile costs to serve, as the link writes it.
    private func cost(_ wire: WireEnvelope) -> Int {
        KeyExchange.served(wire).encoded.count
    }

    /// When a bucket charged `debt` bytes past empty is back at zero, in ms after the charge: one ms later it is above.
    private func repaid(_ debt: Int) -> Int64 {
        Int64(debt) * 1000 / Int64(KeyExchange.answerRefillBytesPerSecond)
    }

    @Test func aProfilePastTheBurstGoesOnceOnDebtThenWaitsForTheRefill() {
        var exchange = KeyExchange()
        let large = profile(5, bytes: 300 * 1024)
        _ = exchange.onProfilePinned(wanted, wire: large, now: 0)
        let first = exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0)
        #expect(first.serve == [KeyExchange.served(large)], "a profile past the burst still goes once")
        let debt = cost(large) - KeyExchange.answerBurstBytes
        #expect(debt > 0)
        let owed = exchange.onRequest([wanted.string], from: neighbor, me: me, now: 1)
        #expect(owed.serve.isEmpty && owed.skipped == 1)
        let stillOwed = exchange.onRequest([wanted.string], from: neighbor, me: me, now: repaid(debt))
        #expect(stillOwed.serve.isEmpty, "a balance back at zero serves nothing")
        let refilled = exchange.onRequest([wanted.string], from: neighbor, me: me, now: repaid(debt) + 1)
        #expect(refilled.serve == [KeyExchange.served(large)])
        #expect(exchange.skippedAnswers == 2)
    }

    @Test func aFullRequestOfSmallProfilesFitsTheBurst() {
        var exchange = KeyExchange()
        let ids = (0..<KeyExchange.maxRequestIds).map(nodeId)
        var bytes = 0
        for (index, id) in ids.enumerated() {
            let small = profile(UInt8(truncatingIfNeeded: index), bytes: 2000)
            bytes += cost(small)
            _ = exchange.onProfilePinned(id, wire: small, now: 0)
        }
        #expect(bytes < KeyExchange.answerBurstBytes, "128 profiles of about 2 KiB: \(bytes) bytes")
        let answer = exchange.onRequest(ids.map(\.string), from: neighbor, me: me, now: 0)
        #expect(answer.serve.count == KeyExchange.maxRequestIds)
        #expect(answer.skipped == 0 && exchange.skippedAnswers == 0)
    }

    @Test func aSkippedKeyIsNeitherWantedNorAskedOn() {
        var exchange = KeyExchange()
        let large = profile(5, bytes: 300 * 1024)
        let small = profile(6)
        _ = exchange.onProfilePinned(wanted, wire: large, now: 0)
        _ = exchange.onProfilePinned(fixtureNodeId(4), wire: small, now: 0)
        _ = exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0)
        let answer = exchange.onRequest([fixtureNodeId(4).string, nodeId(1).string], from: neighbor, me: me, now: 0)
        #expect(answer.serve.isEmpty && answer.skipped == 1, "the held key is skipped")
        #expect(answer.ask == [nodeId(1)], "a key we lack is still asked on: it costs no profile bytes")
        #expect(exchange.missingIds == [nodeId(1)], "the held key is not wanted")
        #expect(exchange.onProfilePinned(fixtureNodeId(4), wire: small, now: 0).isEmpty, "nor its asker made a wanter")
    }

    @Test func twoPeersBudgetsAreIndependent() {
        var exchange = KeyExchange()
        let other = fixtureNodeId(4)
        let large = profile(5, bytes: 300 * 1024)
        _ = exchange.onProfilePinned(wanted, wire: large, now: 0)
        _ = exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0)
        #expect(exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0).serve.isEmpty)
        #expect(exchange.onRequest([wanted.string], from: other, me: me, now: 0).serve == [KeyExchange.served(large)])
    }

    @Test func theBudgetsForgetTheirLeastRecentlyChargedPastTheirCap() {
        var exchange = KeyExchange()
        let large = profile(5, bytes: 300 * 1024)
        let small = profile(6)
        _ = exchange.onProfilePinned(wanted, wire: large, now: 0)
        _ = exchange.onProfilePinned(fixtureNodeId(4), wire: small, now: 0)
        _ = exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0)
        for n in 0..<(KeyExchange.maxAnswerPeers - 1) {
            _ = exchange.onRequest([fixtureNodeId(4).string], from: nodeId(n), me: me, now: 0)
        }
        #expect(exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0).serve.isEmpty, "still remembered in debt")
        for n in 100..<(100 + KeyExchange.maxAnswerPeers) {
            _ = exchange.onRequest([fixtureNodeId(4).string], from: nodeId(n), me: me, now: 0)
        }
        let forgotten = exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0)
        #expect(forgotten.serve == [KeyExchange.served(large)], "forgotten, it comes back full")
    }

    @Test func wantersAreChargedWhenTheKeyPinsAndOnePastItsBudgetIsNotServed() {
        var exchange = KeyExchange()
        let other = fixtureNodeId(4)
        let held = fixtureNodeId(5)
        let large = profile(5, bytes: 300 * 1024)
        _ = exchange.onProfilePinned(held, wire: large, now: 0)
        _ = exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0)
        _ = exchange.onRequest([wanted.string], from: other, me: me, now: 0)
        _ = exchange.onRequest([held.string], from: neighbor, me: me, now: 0)
        let waiting = exchange.onProfilePinned(wanted, wire: profile(7, bytes: 300 * 1024), now: 0)
        #expect(waiting == [other], "the neighbour in debt is not served now")
        #expect(exchange.skippedAnswers == 1)
        #expect(exchange.onRequest([held.string], from: other, me: me, now: 0).serve.isEmpty, "the pin charged its wanter")
        #expect(exchange.onProfilePinned(wanted, wire: profile(7), now: 0).isEmpty, "a skipped wanter is not kept waiting")
    }

    @Test func aProfileTheLinkAlreadyCarriedIsNeitherServedNorCharged() throws {
        var exchange = KeyExchange()
        let large = profile(5, bytes: 300 * 1024)
        let small = profile(6)
        let other = fixtureNodeId(4)
        _ = exchange.onProfilePinned(wanted, wire: large, now: 0)
        _ = exchange.onProfilePinned(other, wire: small, now: 0)
        let largeKey = try #require(FrameKey.ofSigned(large))
        let answer = exchange.onRequest([wanted.string, other.string], from: neighbor, me: me, now: 0) { $0 == largeKey }
        #expect(answer.serve == [KeyExchange.served(small)], "charged for the large one, the small one would be skipped")
        #expect(answer.crossed == 1 && answer.skipped == 0 && exchange.skippedAnswers == 0)
        #expect(answer.ask.isEmpty && exchange.missingIds.isEmpty, "the link has it: neither wanted nor asked on")
        let later = exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0)
        #expect(later.serve == [KeyExchange.served(large)], "the crossed one cost nothing")
    }

    @Test func aWanterWhoseLinkAlreadyCarriedTheProfileIsNeitherServedNorCharged() throws {
        var exchange = KeyExchange()
        let other = fixtureNodeId(4)
        let held = fixtureNodeId(5)
        let large = profile(7, bytes: 300 * 1024)
        _ = exchange.onProfilePinned(held, wire: profile(8), now: 0)
        _ = exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0)
        _ = exchange.onRequest([wanted.string], from: other, me: me, now: 0)
        let key = try #require(FrameKey.ofSigned(large))
        let waiting = exchange.onProfilePinned(wanted, wire: large, now: 0) { crossedKey, peer in crossedKey == key && peer == neighbor }
        #expect(waiting == [other])
        #expect(exchange.skippedAnswers == 0, "a crossed wanter is not skipped")
        #expect(exchange.onRequest([held.string], from: neighbor, me: me, now: 0).serve.count == 1, "nor charged")
        #expect(exchange.onRequest([held.string], from: other, me: me, now: 0).serve.isEmpty, "the served wanter was")
    }
}

extension KeyExchangeTests {
    @Test func aProfileWithNoSignatureHasNoFrameKeySoNoWanterCountsAsCrossed() {
        // The pin store holds verified profiles, so this is a guard: with no key to ask after, every wanter is served.
        var exchange = KeyExchange()
        let other = fixtureNodeId(4)
        _ = exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0)
        _ = exchange.onRequest([wanted.string], from: other, me: me, now: 0)
        let unsigned = WireEnvelope(sig: [], signed: [7, 7])
        var asked = 0
        let waiting = exchange.onProfilePinned(wanted, wire: unsigned, now: 0) { _, _ in
            asked += 1
            return true
        }
        #expect(waiting == [neighbor, other])
        #expect(asked == 0, "no frame key, so the link is never asked")
        #expect(exchange.skippedAnswers == 0)
    }
}
