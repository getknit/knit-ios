import KnitMesh
import Testing

/// One write per link per frame, forgotten with the link; ported from knit-next's `LinkCrossingsTest`, with this
/// port's split of what we wrote from what the link gave us (ADR 2026-10.f5zs).
/// `#expect` cannot call a mutating method, so each crossing is recorded first.
@Suite struct LinkCrossingsTests {
    private static func crossings() -> LinkCrossings<String> {
        LinkCrossings(maxPerLink: 4, windowMilliseconds: 10_000)
    }

    private struct Crossing {
        let link: String
        let key: String
        let now: Int64

        init(_ link: String, _ key: String, _ now: Int64) {
            self.link = link
            self.key = key
            self.now = now
        }
    }

    /// Crosses each step in turn and returns which were first crossings.
    private static func cross(_ steps: [Crossing], over crossings: inout LinkCrossings<String>) -> [Bool] {
        steps.map { crossings.firstCrossing(link: $0.link, key: $0.key, now: $0.now) }
    }

    @Test func theCountIsEveryLinksIdsAndGoesWithTheLink() {
        var crossings = Self.crossings()
        _ = Self.cross([Crossing("bob", "k1", 1000), Crossing("bob", "k2", 1000), Crossing("carol", "k1", 1000)], over: &crossings)
        #expect(crossings.count == 3)
        crossings.forget(link: "bob")
        #expect(crossings.count == 1)
    }

    @Test func theFirstCrossingWritesAndTheSecondSkips() {
        var crossings = Self.crossings()
        #expect(Self.cross([Crossing("bob", "k1", 1000), Crossing("bob", "k1", 1000)], over: &crossings) == [true, false])
    }

    @Test func linksAreIndependent() {
        var crossings = Self.crossings()
        let steps = Self.cross(
            [Crossing("bob", "k1", 1000), Crossing("carol", "k1", 1000), Crossing("carol", "k1", 1000)], over: &crossings)
        #expect(steps == [true, true, false])
    }

    @Test func forgettingALinkStartsItClean() {
        var crossings = Self.crossings()
        let before = Self.cross([Crossing("bob", "k1", 1000)], over: &crossings)
        crossings.forget(link: "bob")
        let after = Self.cross([Crossing("bob", "k1", 1000)], over: &crossings)
        #expect(before == [true] && after == [true])
    }

    @Test func aCrossingExpiresWithTheWindow() {
        var crossings = Self.crossings()
        let steps = Self.cross(
            [Crossing("bob", "k1", 1000), Crossing("bob", "k1", 10_999), Crossing("bob", "k1", 11_000)], over: &crossings)
        #expect(steps == [true, false, true])
    }

    @Test func theOldestCrossingIsEvictedAtTheCap() {
        var crossings = Self.crossings()
        let filled = Self.cross((0..<4).map { Crossing("bob", "k\($0)", 1000) }, over: &crossings)
        let steps = Self.cross([Crossing("bob", "k4", 1000), Crossing("bob", "k0", 1000), Crossing("bob", "k4", 1000)], over: &crossings)
        let allFirst = filled.allSatisfy(\.self)
        #expect(allFirst)
        #expect(steps == [true, true, false], "k4 evicts k0, so k0 is new again")
    }

    // MARK: What the link gave us, apart from what we wrote (ADR 2026-10.f5zs)

    @Test func a1025thInboundStampLeavesEveryOutboundStampInPlace() {
        var crossings = LinkCrossings<String>(windowMilliseconds: 10_000)
        let written = Self.cross((0..<4).map { Crossing("bob", "w\($0)", 1000) }, over: &crossings)
        for index in 0..<1025 {
            crossings.arrived(link: "bob", key: "junk\(index)", now: 1000)
        }
        let again = Self.cross((0..<4).map { Crossing("bob", "w\($0)", 2000) }, over: &crossings)
        let allFirst = written.allSatisfy(\.self)
        #expect(allFirst)
        #expect(again == [false, false, false, false], "a flood inbound evicts only inbound stamps")
        #expect(crossings.count == 4 + 1024, "the inbound memo stops at its cap")
    }

    @Test func anInboundStampBlocksTheWriteAndEvictsOnlyItsOwnOldestAtTheCap() {
        var crossings = Self.crossings()
        let wrote = Self.cross([Crossing("bob", "w0", 1000)], over: &crossings)
        for index in 0..<4 {
            crossings.arrived(link: "bob", key: "in\(index)", now: 1000)
        }
        let blocked = Self.cross([Crossing("bob", "in0", 1000)], over: &crossings)
        crossings.arrived(link: "bob", key: "in4", now: 1000)
        let steps = Self.cross([Crossing("bob", "w0", 1000), Crossing("bob", "in1", 1000), Crossing("bob", "in0", 1000)], over: &crossings)
        #expect(wrote == [true])
        #expect(blocked == [false], "the link gave us that frame")
        #expect(steps == [false, false, true], "in4 evicts in0 alone: the write and in1 stay")
    }

    @Test func hasCrossedReadsBothMemosAndRecordsNothing() {
        var crossings = Self.crossings()
        _ = Self.cross([Crossing("bob", "out", 1000)], over: &crossings)
        crossings.arrived(link: "bob", key: "in", now: 1000)
        #expect(crossings.hasCrossed(link: "bob", key: "out", now: 1000))
        #expect(crossings.hasCrossed(link: "bob", key: "in", now: 1000))
        #expect(!crossings.hasCrossed(link: "bob", key: "new", now: 1000))
        #expect(!crossings.hasCrossed(link: "carol", key: "out", now: 1000))
        #expect(crossings.count == 2)
        #expect(Self.cross([Crossing("bob", "new", 1000)], over: &crossings) == [true], "asking did not record it")
    }

    @Test func eachMemoExpiresWithTheWindow() {
        var crossings = Self.crossings()
        _ = Self.cross([Crossing("bob", "out", 1000)], over: &crossings)
        crossings.arrived(link: "bob", key: "in", now: 1000)
        #expect(crossings.hasCrossed(link: "bob", key: "out", now: 10_999))
        #expect(crossings.hasCrossed(link: "bob", key: "in", now: 10_999))
        #expect(!crossings.hasCrossed(link: "bob", key: "out", now: 11_000))
        #expect(!crossings.hasCrossed(link: "bob", key: "in", now: 11_000))
        let steps = Self.cross(
            [Crossing("bob", "in", 10_999), Crossing("bob", "in", 11_000), Crossing("bob", "out", 11_000)], over: &crossings)
        #expect(steps == [false, true, true])
    }

    @Test func forgettingALinkClearsBothMemosAndTheCountSumsThem() {
        var crossings = Self.crossings()
        _ = Self.cross([Crossing("bob", "out", 1000), Crossing("carol", "out", 1000)], over: &crossings)
        crossings.arrived(link: "bob", key: "in", now: 1000)
        crossings.arrived(link: "bob", key: "out", now: 1000)
        #expect(crossings.count == 4, "a key in both memos counts in each")
        crossings.forget(link: "bob")
        #expect(crossings.count == 1)
        #expect(!crossings.hasCrossed(link: "bob", key: "in", now: 1000))
        #expect(Self.cross([Crossing("bob", "in", 1000), Crossing("bob", "out", 1000)], over: &crossings) == [true, true])
    }
}
