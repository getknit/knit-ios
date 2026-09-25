import KnitMesh
import Testing

/// One write per link per frame, forgotten with the link; ported from knit-next's `LinkCrossingsTest`.
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
}
