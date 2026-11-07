import Testing

@testable import KnitMesh

/// ``DeadlineHeap``, the min-heap ``AdvertAliases`` expires its claims, announced tags and voids from (Kotlin's
/// `PriorityQueue` in `AdvertAliases.kt` at `cad69c77b`, which knit-next tests only through the resolver): due deadlines
/// come out earliest first, however they went in, and none comes out early.
@Suite struct DeadlineHeapTests {
    @Test func dueDeadlinesComeOutEarliestFirstWhateverOrderTheyWentIn() {
        var heap = DeadlineHeap<Int>()
        var random = SeededGenerator(seed: 7)
        let deadlines = (0..<200).map { _ in Int64.random(in: 0..<1000, using: &random) }
        for (index, at) in deadlines.enumerated() {
            heap.push(index, at: at)
        }
        #expect(heap.count == deadlines.count)
        var popped: [Int64] = []
        while let index = heap.popDue(.max) {
            popped.append(deadlines[index])
        }
        #expect(popped == deadlines.sorted())
    }

    @Test func nothingComesOutBeforeItIsDue() {
        var heap = DeadlineHeap<String>()
        for (value, at) in [("late", Int64(30)), ("soon", 10), ("middle", 20), ("last", 40)] {
            heap.push(value, at: at)
        }
        #expect(heap.popDue(9) == nil)
        #expect(heap.popDue(20) == "soon")
        #expect(heap.popDue(20) == "middle")
        #expect(heap.popDue(29) == nil, "the next is due at 30")
        #expect(heap.count == 2)
        heap.removeAll()
        #expect(heap.popDue(.max) == nil)
    }
}
