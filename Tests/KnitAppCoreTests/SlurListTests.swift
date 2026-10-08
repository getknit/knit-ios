import Foundation
import Testing

@testable import KnitAppCore

/// The shipped slur list, `App/Models/Slurs.txt` (knit-next's `slurs_en.txt`, its ADR 2026-10.d62w): the list every
/// conversation runs, DMs and groups included, as knit-next's `SlurListTest` pins it. Because it holds back messages in
/// private chats too, what it leaves out is pinned as hard as what it holds: an in-group or everyday word here would
/// stop someone talking to a friend.
@Suite struct SlurListTests {
    private static func terms() throws -> [String] {
        let text = try String(contentsOf: CopyTests.root.appendingPathComponent("App/Models/Slurs.txt"), encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func list() throws -> WordFilter {
        WordFilter(list: try String(contentsOf: CopyTests.root.appendingPathComponent("App/Models/Slurs.txt"), encoding: .utf8))
    }

    @Test func everyTermIsASortedUniqueWordOfThreeLettersOrMore() throws {
        let terms = try Self.terms()
        #expect(!terms.isEmpty)
        #expect(terms.allSatisfy { $0.count >= 3 && $0.unicodeScalars.allSatisfy { ("a"..."z").contains($0) } })
        #expect(Set(terms).count == terms.count)
        #expect(terms == terms.sorted(), "sorted, so a regeneration diffs cleanly")
    }

    @Test func theSlursTheModelMissesAreListedWithTheirPlurals() throws {
        let terms = Set(try Self.terms())
        for slur in ["nigger", "niggers", "kike", "kikes", "spic", "spics", "wetback", "faggot", "faggots", "tranny"] {
            #expect(terms.contains(slur), "\(slur) should be on the list")
        }
    }

    @Test func inGroupEverydayAndSelfDescriptiveWordsAreNot() throws {
        let terms = Set(try Self.terms())
        let kept = [
            "nigga", "niggas", "coon", "coons", "fag", "fagot", "dyke", "queer", "gay", "trans", "twink", "negro", "haji",
            "hajji", "swastika", "jap", "black", "jew", "jewish", "muslim", "mexican",
        ]
        for word in kept {
            #expect(!terms.contains(word), "\(word) must not be held back in private chats")
        }
    }

    @Test func aSlurIsCaughtThroughTheEvasionsTheMatcherSeesThrough() throws {
        let list = try Self.list()
        for text in ["you are a nigger", "N1GG3R", "k i k e", "dirty spics", "f.a.g.g.o.t"] {
            #expect(list.flags(text), "\(text) should be caught")
        }
    }

    @Test func ordinaryPrivateSpeechGoesThrough() throws {
        let list = try Self.list()
        for text in ["fuck off, mate", "this is shit", "nigga what's up", "went coon hunting", "got a fag?"] {
            #expect(!list.flags(text), "\(text) should pass in a DM")
        }
    }
}
