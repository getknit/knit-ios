import Foundation
import Testing

@testable import KnitAppCore

/// The word lists the name screen reads, as the app bundles them from `App/Models/`, each knit-next's file byte for byte.
enum ShippedNameLists {
    /// Each list by its file name in knit-next's `assets/moderation/`, and its own here.
    static let files = [
        "slurs_en.txt": "Slurs.txt",
        "profanity_en.txt": "Profanity.txt",
        "name_embeddable_en.txt": "NameEmbeddable.txt",
        "name_exclusions_en.txt": "NameExclusions.txt",
        "name_allowed_en.txt": "NameAllowed.txt",
    ]

    /// The terms of `App/Models/<file>`, read as the app reads them.
    static func terms(_ file: String) -> [String] {
        let url = CopyTests.root.appendingPathComponent("App/Models/\(file)")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("App/Models/\(file) is missing")
        }
        return WordFilter.terms(in: text)
    }

    /// The screen over the shipped lists.
    static let screen = NameScreen(
        slurs: terms("Slurs.txt"),
        profanity: terms("Profanity.txt"),
        embeddable: terms("NameEmbeddable.txt"),
        exclusions: terms("NameExclusions.txt"),
        allowedNames: terms("NameAllowed.txt")
    )
}

/// The three generated name lists (`gen-name-screen-lists.py` in knit-next, its ADR 2026-11.y4pc) and the screen built
/// from them (`NameListsTest.kt`). The lists come from name data outside both repositories, so these checks are what
/// stop a regeneration from shipping an allowed slur, a dead entry or a lost case.
@Suite struct NameListsTests {
    private let slurs = Set(ShippedNameLists.terms("Slurs.txt"))
    private let profanity = Set(ShippedNameLists.terms("Profanity.txt"))
    private let embeddable = ShippedNameLists.terms("NameEmbeddable.txt")
    private let exclusions = ShippedNameLists.terms("NameExclusions.txt")
    private let allowed = ShippedNameLists.terms("NameAllowed.txt")
    private let screen = ShippedNameLists.screen

    @Test func everyListIsASortedUniqueSetOfLowercaseTokens() {
        for list in [embeddable, exclusions, allowed] {
            #expect(!list.isEmpty)
            #expect(Array(Set(list)).sorted() == list)
            for term in list {
                #expect(!term.isEmpty && term.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }, "\(term)")
            }
        }
    }

    @Test func anEmbeddableTermIsAListTermOfFourLettersOrMore() {
        for term in embeddable {
            #expect(slurs.contains(term) || profanity.contains(term), "\(term) is on neither word list")
            #expect(term.count >= 4, "\(term) is too short to look for inside a word")
        }
    }

    @Test func noAllowedNameIsASlurAndEveryOneIsAProfanityTerm() {
        for name in allowed {
            #expect(!slurs.contains(name), "a slur is never allowed as a name: \(name)")
            #expect(profanity.contains(name), "\(name) is not a profanity term, so allowing it does nothing")
        }
    }

    @Test func everyExclusionHoldsAnEmbeddableTerm() {
        for word in exclusions {
            #expect(embeddable.contains { word.contains($0) }, "a dead exclusion: \(word)")
        }
    }

    @Test func realNamesPass() {
        for name in ["Dick Smith", "Shota Tanaka", "Haji Ali", "Mary Cumming", "Cassandra", "Benedick", "Dickson", "Hancock"] {
            #expect(!screen.check(name, audience: .everyone).flagged, "\(name)")
        }
    }

    @Test func theBenignWordsHandLabellingFoundPass() {
        for name in ["spikeyboy", "darkeyes", "stranny2004", "Dildora", "phonkyd", "2 x 3"] {
            #expect(!screen.check(name, audience: .everyone).flagged, "\(name)")
        }
    }

    @Test func handleShapesAreCaught() {
        for name in ["BigD1ck69", "big_d1ck", "xXFuckXx", "fuck_lord", "bigfuckboy", "Sh1tHead"] {
            #expect(screen.check(name, audience: .everyone).flagged, "\(name)")
        }
    }

    @Test func aGroupNameIsReadAgainstTheSlurListAlone() {
        #expect(!screen.check("Fuck Mondays", audience: .members).flagged)
        #expect(screen.check("Fuck Mondays", audience: .everyone).flagged)
    }
}
