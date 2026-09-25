import KnitMesh
import Testing

/// The seen set, ported from knit-next's two `SeenSetTest`s. Restoring a set across launches is the LoRa
/// plane's need and is not ported. `#expect` cannot call a mutating method, so each step is recorded first.
@Suite struct SeenSetTests {
    /// Inserts each `(id, now)` in turn and returns whether each was new.
    private static func insert(_ steps: [(String, Int64)], into seen: inout SeenSet) -> [Bool] {
        steps.map { seen.insert($0.0, now: $0.1) }
    }

    @Test func theFirstSightIsNewAndARepeatIsNot() {
        var seen = SeenSet()
        #expect(Self.insert([("x", 0), ("x", 0)], into: &seen) == [true, false])
        #expect(seen.contains("x", now: 0))
        #expect(!seen.contains("y", now: 0))
    }

    @Test func anIdIsNewAgainOnceItsWindowHasPassed() {
        var seen = SeenSet(windowMilliseconds: 1000)
        #expect(Self.insert([("a", 0), ("a", 500)], into: &seen) == [true, false])
        #expect(!seen.contains("a", now: 1000))
        #expect(Self.insert([("a", 1000)], into: &seen) == [true], "the window lapsed")
    }

    @Test func theOldestInsertedIdIsEvictedPastTheCapacity() {
        var seen = SeenSet(capacity: 2)
        let steps = Self.insert([("a", 0), ("b", 0), ("c", 0), ("a", 0), ("c", 0)], into: &seen)
        #expect(steps == [true, true, true, true, false], "c evicts a, so a is new again and c is still held")
    }

    /// Kotlin's insertion-ordered map keeps a restamped id in its place, so a busy id is still evicted first.
    @Test func restampingAnIdKeepsItsPlaceInLine() {
        var seen = SeenSet(capacity: 2, windowMilliseconds: 10)
        let steps = Self.insert([("a", 0), ("b", 1), ("a", 20), ("c", 21)], into: &seen)
        #expect(steps == [true, true, true, true])
        #expect(seen.contains("b", now: 5), "c evicted a, the oldest inserted, not b")
        #expect(!seen.contains("a", now: 21))
    }

    @Test func anIdCanBeReopenedOnceInsideItsWindowAndNotAgain() {
        var seen = SeenSet(windowMilliseconds: 10_000)
        let now: Int64 = 1000
        let first = Self.insert([("dm", now), ("dm", now)], into: &seen)
        let reopened = seen.reopen("dm", now: now)
        let afterReopen = Self.insert([("dm", now)], into: &seen)
        let reopenedTwice = seen.reopen("dm", now: now)
        let afterRefusal = Self.insert([("dm", now)], into: &seen)
        let unknown = seen.reopen("other", now: now)
        #expect(first == [true, false], "the copy custody served is a repeat")
        #expect(reopened && afterReopen == [true], "the first reopen admits the sender's re-seal")
        #expect(!reopenedTwice && afterRefusal == [false], "a second reopen inside the window is refused")
        #expect(!unknown, "an id the set never saw has nothing to reopen")

        let later = now + 10_001
        let newWindow = Self.insert([("dm", later)], into: &seen)
        let newReopen = seen.reopen("dm", now: later)
        #expect(newWindow == [true] && newReopen, "a new window, and a new reopen")
    }

    @Test func aReopenedIdGoesToTheBackOfTheLine() {
        var seen = SeenSet(capacity: 2)
        _ = Self.insert([("a", 0), ("b", 0)], into: &seen)
        let reopened = seen.reopen("a", now: 0)
        let steps = Self.insert([("a", 0), ("c", 0)], into: &seen)
        #expect(reopened && steps == [true, true])
        #expect(!seen.contains("b", now: 0), "c evicted b, because a went to the back")
        #expect(seen.contains("a", now: 0))
    }

    @Test func aLongRunStaysBounded() {
        var seen = SeenSet(capacity: 8)
        let steps = Self.insert((0..<10_000).map { ("id-\($0)", Int64($0)) }, into: &seen)
        let allNew = steps.allSatisfy(\.self)
        #expect(allNew)
        #expect(seen.contains("id-9999", now: 9999))
        #expect(seen.contains("id-9992", now: 9999))
        #expect(!seen.contains("id-9991", now: 9999))
    }
}
