import Foundation
import Testing

@testable import KnitAppCore

/// The room's word list (`LexicalTextFilterTest.kt`), and the positions taken out before it reads (`GeoUri.strip`).
@Suite struct WordFilterTests {
    private let filter = WordFilter(words: ["shit", "fuck", "ass", "bullshit"])

    @Test func cleanTextPasses() {
        #expect(!filter.flags("hello there, how are you?"))
        #expect(!filter.flags(""))
        #expect(!filter.flags("    "))
    }

    @Test func aListedWordIsFlagged() {
        #expect(filter.flags("this is shit"))
        #expect(filter.flags("FUCK that"))
        #expect(filter.flags("bullshit"))
    }

    @Test func leetspeakReadsAsLetters() {
        #expect(filter.flags("sh1t"))
        #expect(filter.flags("$h!t"))
        #expect(filter.flags("a$$"))
        #expect(filter.flags("5h1t"))
    }

    @Test func accentsAndWideLettersFold() {
        #expect(filter.flags("shít"))
        #expect(filter.flags("ＦＵＣＫ"))
    }

    @Test func stretchedLettersCollapse() {
        #expect(filter.flags("shiiiit"))
        #expect(filter.flags("fuuuuck"))
    }

    @Test func spacedLettersJoin() {
        #expect(filter.flags("f u c k you"))
        #expect(filter.flags("s.h.i.t"))
        #expect(filter.flags("f-u-c-k"))
        #expect(filter.flags("you f u c k"), "a run at the very end is tested too")
    }

    @Test func onlyWholeWordsMatch() {
        // The Scunthorpe problem: part of a fine word never trips the list.
        #expect(!filter.flags("classic assistant in the grass"))
        #expect(!filter.flags("pass the salt"))
        #expect(!filter.flags("as soon as possible"), "a pair is not a run, so 'as' never becomes 'ass'")
        #expect(!filter.flags("Scunthorpe"))
        #expect(filter.flags("you ass"))
    }

    @Test func anAllowedWordPassesAndAnEmptyListFlagsNothing() {
        #expect(!WordFilter(words: ["ass"], allowed: ["ass"]).flags("you ass"))
        #expect(!WordFilter(words: []).flags("shit fuck ass"))
    }

    @Test func theListReadsOneWordALine() {
        let list = WordFilter(list: "# a comment\n\nshit\n  fuck  \r\n")
        #expect(list.flags("oh shit") && list.flags("fuck"))
        #expect(!list.flags("comment"))
    }

    @Test func theShippedListIsAndroidsAndFlagsItsOwnWords() throws {
        let text = try String(contentsOf: CopyTests.root.appendingPathComponent("App/Models/Profanity.txt"), encoding: .utf8)
        let words = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        #expect(words.count > 300)
        let list = WordFilter(list: text)
        #expect(words.allSatisfy(list.flags), "every listed word trips its own list")
        #expect(!list.flags("have a lovely evening, see you at the north gate"))
    }

    // MARK: Positions

    @Test func aRunOfCoordinatesCanSpellAListedWordWhichIsWhyPositionsComeOut() {
        // 4 reads as a and 5 as s, so the latitude's "9455" is "ass".
        #expect(filter.flags("geo:37.9455,-122.1"))
        #expect(!filter.flags(GeoTokens.strip("meet here geo:37.9455,-122.1")))
    }

    @Test func positionsComeOutAndTheirLinesWithThem() {
        #expect(GeoTokens.strip("meet here geo:37.9455,-122.1") == "meet here")
        #expect(GeoTokens.strip("(geo:-41.2865,174.7762;u=12.5), by the gate.") == "(), by the gate.", "only the token goes")
        #expect(GeoTokens.strip("first\ngeo:1,2\nlast") == "first\nlast")
        #expect(GeoTokens.strip("GEO:1.5,2.5?q=cafe  and   more") == "and more")
        #expect(GeoTokens.strip("geo:1,2").isEmpty)
    }

    @Test func whatIsNoPositionStays() {
        #expect(GeoTokens.strip("no position here") == "no position here")
        #expect(GeoTokens.strip("geo:91,0 geo:0,181 geo:abc") == "geo:91,0 geo:0,181 geo:abc", "out of range or not a position")
        #expect(GeoTokens.strip("geo:١,٢") == "geo:١,٢", "digits are ASCII, as Java's are")
        #expect(GeoTokens.strip("ageo:1,2") == "ageo:1,2")
    }
}
