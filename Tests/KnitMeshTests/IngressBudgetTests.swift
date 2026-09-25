import KnitMesh
import KnitWire
import Testing

/// The room-post budget per link, ported from knit-next's `IngressBudgetTest`. `#expect` cannot call a
/// mutating method, so each admission is recorded first.
@Suite struct IngressBudgetTests {
    private func envelope(type: FrameType = .chat, recipientId: String? = nil, group: GroupInfo? = nil) -> RelayEnvelope {
        RelayEnvelope(type: type, id: "x", senderId: "s", recipientId: recipientId, group: group, payload: [])
    }

    /// Admits each `(link, now)` in turn and returns which were admitted.
    private static func admit<Link>(_ steps: [(Link, Int64)], to budget: inout IngressBudget<Link>) -> [Bool] {
        steps.map { budget.admit(link: $0.0, now: $0.1) }
    }

    @Test func onlyTheCleartextRoomPostIsMetered() {
        #expect(IngressBudget<String>.meters(envelope()))
        #expect(!IngressBudget<String>.meters(envelope(recipientId: "peer")), "a DM")
        #expect(!IngressBudget<String>.meters(envelope(group: GroupInfo(id: "g-1", members: ["s", "t"], createdBy: "s"))))
        #expect(!IngressBudget<String>.meters(envelope(type: .profile)))
        #expect(!IngressBudget<String>.meters(envelope(type: .receipt)))
    }

    @Test func aLinkSpendsItsBurstThenWaitsForTheRefill() {
        var budget = IngressBudget<String>(burst: 3, perMinute: 60)
        let steps = Self.admit([("link", 0), ("link", 0), ("link", 0), ("link", 0), ("link", 1000), ("link", 1000)], to: &budget)
        #expect(steps == [true, true, true, false, true, false], "60 a minute is one token a second")
    }

    @Test func theRefillNeverOvershootsTheBurst() {
        var budget = IngressBudget<String>(burst: 3, perMinute: 60)
        _ = Self.admit(Array(repeating: ("link", 0), count: 3), to: &budget)
        let steps = Self.admit(Array(repeating: ("link", 3_600_000), count: 10), to: &budget)
        let admitted = steps.filter(\.self).count
        #expect(admitted == 3)
    }

    @Test func linksAreBudgetedIndependently() {
        var budget = IngressBudget<String>(burst: 3, perMinute: 60)
        let mallory = Self.admit(Array(repeating: ("mallory", 0), count: 4), to: &budget)
        let bob = Self.admit([("bob", 0)], to: &budget)
        #expect(mallory == [true, true, true, false])
        #expect(bob == [true], "a new link starts full")
    }

    @Test func withNoRefillTheBurstIsTheWholeBudget() {
        var budget = IngressBudget<String>(burst: 2, perMinute: 0)
        #expect(Self.admit([("link", 0), ("link", 0), ("link", 86_400_000)], to: &budget) == [true, true, false])
    }

    @Test func aClockThatStepsBackRefillsNothing() {
        var budget = IngressBudget<String>(burst: 1, perMinute: 60)
        #expect(Self.admit([("link", 10_000), ("link", 0)], to: &budget) == [true, false])
    }

    @Test func theLeastRecentlyUsedLinkIsForgottenPastSixtyFour() {
        var budget = IngressBudget<Int>(burst: 1, perMinute: 0)
        let first = Self.admit((0...64).map { ($0, 0) }, to: &budget)
        let again = Self.admit([(0, 0), (64, 0)], to: &budget)
        let allAdmitted = first.allSatisfy(\.self)
        #expect(allAdmitted)
        #expect(again == [true, false], "link 0 was evicted and comes back full; link 64 is held, and empty")
    }
}
