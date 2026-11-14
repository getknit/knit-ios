import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitAppCore

/// knit-next's name screen contract (`vectors/name-screen-v1.json`, its ADR 2026-11.y4pc), checked as
/// `NameScreenVectorTest` checks it on Android: the same lists, and the same verdict on every name.
@Suite struct NameScreenVectorTests {
    private static let file = NameScreenVectors.file

    @Test func theBundledListsAreTheOnesTheVectorsWereMadeFrom() {
        #expect(Set(Self.file.lists.keys) == Set(ShippedNameLists.files.keys))
        for (android, ours) in ShippedNameLists.files {
            // Kotlin sorts by UTF-16 unit, and joins with no newline after the last term.
            let terms = ShippedNameLists.terms(ours).sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            let digest = BlobHash(of: Array(terms.joined(separator: "\n").utf8)).string
            #expect(digest == Self.file.lists[android], "App/Models/\(ours) is not the \(android) the vectors were made from")
        }
    }

    @Test func everyNameGetsItsVerdict() throws {
        #expect(Self.file.cases.count == 31)
        for entry in Self.file.cases {
            let audience = try #require(Self.audiences[entry.audience], "\(entry.audience)")
            let verdict = ShippedNameLists.screen.check(entry.name, audience: audience)
            #expect(Self.verdicts[verdict] == entry.verdict, "\(entry.name) for \(entry.audience)")
        }
    }

    private static let audiences: [String: NameScreen.Audience] = ["PUBLIC": .everyone, "MEMBERS": .members]
    private static let verdicts: [NameScreen.Verdict: String] = [.allowed: "NONE", .slur: "SLUR", .profanity: "PROFANITY"]
}
