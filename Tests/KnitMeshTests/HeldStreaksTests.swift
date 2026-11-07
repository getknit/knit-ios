import KnitWire
import Testing

@testable import KnitMesh

/// ``HeldStreaks`` alone (knit-next ADR 2026-09.hj4a's amendment of 2026-11-06), ported case for case from
/// `HeldStreaksTest.kt` at `cad69c77b`. Kotlin's `ended` clears the book itself; here it answers the keys to clear, so each
/// case reads what is left as the book less those.
@Suite struct HeldStreaksTests {
    private let stranger = SightingKey.node(BlindFixture.id("stranger"))
    private let age = HeldStreaks<String>.confirmByAgeMilliseconds

    private func key(_ name: String) -> DialKey {
        .address(RadioAddress(name))
    }

    private var held: DialRecord {
        DialRecord(kind: .ordinary, peerKey: stranger, linkedAtStart: true)
    }

    /// What is left of `book` once `link` ends after `heldMilliseconds`.
    private static func left(_ book: Set<DialKey>, _ streaks: inout HeldStreaks<String>, _ link: String, _ held: Int64) -> Set<DialKey> {
        book.subtracting(streaks.ended(link, heldMilliseconds: held))
    }

    @Test func aLinkClearsOnlyTheKeysItEarnedAndOnlyPastTheConfirmAge() {
        let book: Set = [key("earned"), key("another address")]
        var streaks = HeldStreaks<String>()
        streaks.dialFailed(held, dialKey: key("earned")) { _ in "held" }
        #expect(Self.left(book, &streaks, "held", age - 1) == book, "too young to clear, and forgotten")
        #expect(Self.left(book, &streaks, "held", age) == book)
        streaks.dialFailed(held, dialKey: key("earned")) { _ in "held" }
        #expect(Self.left(book, &streaks, "held", age) == [key("another address")])
    }

    @Test func onlyADialThatBeganHeldEarnsAndOnlyWhileItsLinkStands() {
        var streaks = HeldStreaks<String>()
        let crossing = DialRecord(kind: .ordinary, peerKey: stranger, linkedAtStart: false)
        streaks.dialFailed(crossing, dialKey: key("key")) { _ in "held" }
        streaks.dialFailed(nil, dialKey: key("key")) { _ in "held" }
        streaks.dialFailed(held, dialKey: key("key")) { _ in nil }
        #expect(Self.left([key("key")], &streaks, "held", age) == [key("key")], "nothing earned")
    }

    @Test func aReplacedLinkHandsWhatItEarnedToItsSuccessor() {
        var streaks = HeldStreaks<String>()
        streaks.dialFailed(held, dialKey: key("key")) { _ in "first" }
        streaks.moved(from: "first", to: "second", fromHeldMilliseconds: 0)
        #expect(Self.left([key("key")], &streaks, "first", age) == [key("key")], "the peer is still held")
        #expect(Self.left([key("key")], &streaks, "second", age).isEmpty)
    }

    @Test func aReplacementChainIsAgedWhole() {
        func chain(first: Int64, second: Int64) -> Set<DialKey> {
            var streaks = HeldStreaks<String>()
            streaks.dialFailed(held, dialKey: key("key")) { _ in "first" }
            streaks.moved(from: "first", to: "second", fromHeldMilliseconds: first)
            return Self.left([key("key")], &streaks, "second", second)
        }
        #expect(chain(first: 600_000, second: 1).isEmpty, "ten minutes, then a young successor")
        #expect(chain(first: age / 2, second: age / 2 - 1) == [key("key")], "a chain under the age in total clears nothing")
    }

    @Test func anAgeSurvivesEveryLinkOfAChain() {
        var streaks = HeldStreaks<String>()
        streaks.dialFailed(held, dialKey: key("key")) { _ in "0" }
        streaks.moved(from: "0", to: "1", fromHeldMilliseconds: 600_000)
        streaks.moved(from: "1", to: "2", fromHeldMilliseconds: 1)
        #expect(Self.left([key("key")], &streaks, "2", 1).isEmpty, "ten minutes, then two young successors")
    }

    @Test func aLinkThatEarnedNothingStillPassesOnItsAge() {
        var streaks = HeldStreaks<String>()
        streaks.moved(from: "first", to: "second", fromHeldMilliseconds: 600_000)
        streaks.dialFailed(held, dialKey: key("key")) { _ in "second" }
        #expect(Self.left([key("key")], &streaks, "second", 1).isEmpty)
    }

    @Test func aLinkPastTheCapKeepsItsNewestKeysAndLeavesTheOldestToItsBackoff() {
        let keys = (1...17).map { key("key\($0)") }
        var streaks = HeldStreaks<String>()
        for each in keys {
            streaks.dialFailed(held, dialKey: each) { _ in "held" }
        }
        #expect(Self.left(Set(keys), &streaks, "held", age) == [key("key1")], "the 17th landed, and the first stands uncleared")
    }

    @Test func aKeyFailedAgainCountsAsNewestAtTheCap() {
        let keys = (1...17).map { key("key\($0)") }
        var streaks = HeldStreaks<String>()
        for each in keys.prefix(16) {
            streaks.dialFailed(held, dialKey: each) { _ in "held" }
        }
        streaks.dialFailed(held, dialKey: key("key1")) { _ in "held" }
        streaks.dialFailed(held, dialKey: key("key17")) { _ in "held" }
        #expect(Self.left(Set(keys), &streaks, "held", age) == [key("key2")], "key1 was failed again, so key2 is the oldest")
    }
}
