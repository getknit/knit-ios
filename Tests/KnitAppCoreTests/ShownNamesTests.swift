import KnitSync
import Testing

@testable import KnitAppCore

/// The name screen's verdicts as the directory reads them (`ShownNames.kt`): cached by text and audience, within a
/// bound, and drawn blank when flagged.
@Suite struct ShownNamesTests {
    /// A screen that flags "bad" for everyone and "worse" for members too, counting what it was asked.
    private final class Counting: Sendable {
        let asked = Lock<[String]>([])

        func check(_ text: String, _ audience: NameScreen.Audience) -> Bool {
            asked.withLock { $0.append("\(audience):\(text)") }
            return text.contains("worse") || audience == .everyone && text.contains("bad")
        }
    }

    @Test func aFlaggedNameDrawsBlankAndTheGroupReadsItsOwnRules() {
        let names = ShownNames(
            screen: NameScreen(
                slurs: ["pikey"], profanity: ["fuck"], embeddable: [], exclusions: [], allowedNames: []))
        #expect(names.person("Fuck69").isEmpty)
        #expect(names.person("Alice") == "Alice")
        #expect(names.group("Fuck Mondays") == "Fuck Mondays", "a group's members read the slur list alone")
        #expect(names.group("Pikey club").isEmpty)
        #expect(!names.flagged("   ", audience: .everyone), "blank is never flagged")
    }

    @Test func aVerdictIsWorkedOutOncePerTextAndAudience() {
        let screen = Counting()
        let names = ShownNames { screen.check($0, $1) }
        for _ in 0..<3 {
            #expect(names.flagged("bad", audience: .everyone))
            #expect(!names.flagged("bad", audience: .members))
        }
        #expect(screen.asked.withLock { $0 } == ["everyone:bad", "members:bad"])
    }

    @Test func aComposedAndADecomposedTextAreTwoKeys() {
        let screen = Counting()
        let names = ShownNames { screen.check($0, $1) }
        _ = names.flagged("D\u{ED}ck", audience: .everyone)
        _ = names.flagged("Di\u{301}ck", audience: .everyone)
        #expect(screen.asked.withLock(\.count) == 2, "Swift's string equality would have made them one")
    }

    @Test func theCacheKeepsWithinItsBoundAndKeepsWhatIsReadOften() {
        let screen = Counting()
        let names = ShownNames(capacity: 4) { screen.check($0, $1) }
        for text in ["a", "b", "c", "d", "e", "f"] {
            _ = names.flagged(text, audience: .everyone)
            // "a", read after every new name, keeps moving to the newer generation.
            _ = names.flagged("a", audience: .everyone)
        }
        let asked = screen.asked.withLock { $0 }
        #expect(asked.filter { $0 == "everyone:a" }.count == 1, "read often, never asked again")
        _ = names.flagged("b", audience: .everyone)
        #expect(screen.asked.withLock(\.count) == asked.count + 1, "the oldest generation went whole")
    }

    @Test func aSetReadOnEveryRebuildStaysWithinTheBound() {
        // Every round reads the whole table again, as a directory rebuild does, and adds a name. Were a move from the
        // older generation exempt from the bound, every name would stay and none would be asked twice.
        let screen = Counting()
        let names = ShownNames(capacity: 4) { screen.check($0, $1) }
        var table: [String] = []
        for round in 0..<10 {
            table.append("name\(round)")
            for text in table {
                _ = names.flagged(text, audience: .everyone)
            }
        }
        #expect(screen.asked.withLock(\.count) > table.count, "a table larger than the bound is asked again")
    }
}
