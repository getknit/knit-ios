import KnitWire
import Testing

@testable import KnitCrypto

/// Reordering, holes and re-serves, and the rules that move a sender to a fresh epoch.
extension RatchetEngineTests {
    // MARK: Reordering, duplicates, holes

    @Test func outOfOrderArrivalUsesSkippedKeysExactlyOnce() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        let m0 = try alice.seal("m0", now: Self.now)
        let m1 = try alice.seal("m1", now: Self.now)
        let m2 = try alice.seal("m2", now: Self.now)

        #expect(try text(bob.open(m2, now: Self.now)) == "m2")
        #expect(bob.rows.skippedKeys.count == 2)

        #expect(try text(bob.open(m0, now: Self.now)) == "m0")
        #expect(bob.rows.skippedKeys.count == 1)
        #expect(try bob.open(m0, now: Self.now).failure == .duplicate)

        #expect(try text(bob.open(m1, now: Self.now)) == "m1")
        #expect(bob.rows.skippedKeys.isEmpty)
    }

    @Test func skippedKeyStillOpensAfterItsEpochRowWasSwept() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        let m0 = try alice.seal("m0", now: Self.now)
        let m1 = try alice.seal("m1", now: Self.now)
        _ = try alice.seal("m2", now: Self.now)
        _ = try bob.open(m1, now: Self.now)

        bob.rows.chains = [:]
        #expect(try text(bob.open(m0, now: Self.now)) == "m0")
        #expect(bob.rows.chains.isEmpty)
    }

    @Test func aWhollyLostEpochLosesOnlyItself() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try alice.seal("lost-0", now: Self.now)
        _ = try alice.seal("lost-1", now: Self.now)

        let fresh = try alice.seal("epoch-2", now: Self.now, force: true)
        #expect(fresh.header.se == 2)
        #expect(try text(bob.open(fresh, now: Self.now)) == "epoch-2")
    }

    // MARK: Epoch advance rules

    @Test func epochAdvancesAtTheMessageCountCap() throws {
        let (alice, _) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        for index in 0..<RatchetEngine.maxEpochMessages {
            #expect(try alice.seal("m\(index)", now: Self.now).header.se == 1)
        }
        #expect(try alice.seal("overflow", now: Self.now).header.se == 2)
    }

    @Test func epochAdvancesAtTheAgeCap() throws {
        let (alice, _) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        #expect(try alice.seal("young", now: Self.now).header.se == 1)
        #expect(try alice.seal("old", now: Self.now + RatchetEngine.maxEpochAgeMilliseconds).header.se == 2)
    }

    @Test func epochAdvancesOnTheFirstSendAfterAPeerContribution() throws {
        let (alice, bob) = try RatchetSide.pair()
        try alice.initiate(now: Self.now)
        _ = try bob.open(alice.seal("hello", now: Self.now), now: Self.now)
        _ = try alice.open(bob.seal("reply", now: Self.now), now: Self.now)

        let healed = try alice.seal("healed", now: Self.now)
        #expect(healed.header.se == 2)
        #expect(healed.header.pe == 1)
        #expect(try text(bob.open(healed, now: Self.now)) == "healed")
    }
}
