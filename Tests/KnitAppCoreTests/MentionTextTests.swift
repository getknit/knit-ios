import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// Android's mention rules, each case from knit-next's `MentionTextTest.kt` (ADR 2026-10.nbhj): the "@" word the cursor
/// sits in, whom a query finds, where a body's names are highlighted, and how the composer keeps a picked name whole.
@Suite struct MentionTextTests {
    private func candidate(_ id: String, _ name: String, alias: String, discriminator: String? = nil) -> MentionCandidate {
        MentionCandidate(
            label: PeerLabel(nodeId: id, name: name, alias: alias, discriminator: discriminator),
            face: .person(id, name: name, photo: nil)
        )
    }

    private let walter = [MessageMention(nodeId: "w", name: "Walter")]

    // MARK: The "@" word

    @Test func findsTokenWhenCursorInsideAtWord() {
        let query = MentionText.activeQuery(in: "hey @Joy", cursor: 8)
        #expect(query == MentionQuery(start: 4, end: 8, query: "Joy"))
    }

    @Test func triggersWhenAtIsAtStringStart() {
        #expect(MentionText.activeQuery(in: "@Jo", cursor: 3) == MentionQuery(start: 0, end: 3, query: "Jo"))
    }

    @Test func bareAtYieldsEmptyQuery() {
        #expect(MentionText.activeQuery(in: "hi @", cursor: 4)?.query.isEmpty == true)
    }

    @Test func closedTokenAfterSpaceIsNull() {
        #expect(MentionText.activeQuery(in: "hi @Joy ", cursor: 8) == nil)
    }

    @Test func atMidWordDoesNotTrigger() {
        #expect(MentionText.activeQuery(in: "email foo@bar", cursor: 13) == nil)
    }

    @Test func nearestAtBeforeCursorWins() {
        #expect(MentionText.activeQuery(in: "@a @b", cursor: 5) == MentionQuery(start: 3, end: 5, query: "b"))
    }

    @Test func theCursorAfterAnInsertedDiscriminatedTokenIsOutsideAnyMentionQuery() {
        let text = "hey @Alice (JoyfulFerret) "
        #expect(MentionText.activeQuery(in: text, cursor: text.utf16.count) == nil)
        #expect(MentionText.activeQuery(in: text, cursor: text.utf16.count - 3) == nil)
    }

    /// Whitespace is ART's (ADR 2026-10.7uyt): a no-break space opens a word and ends one, U+0085 does neither, and a
    /// cursor off the text is no cursor.
    @Test func whitespaceIsWhatArtSays() {
        #expect(MentionText.activeQuery(in: "hi\u{A0}@Jo", cursor: 6)?.query == "Jo")
        #expect(MentionText.activeQuery(in: "hi\u{85}@Jo", cursor: 6) == nil)
        #expect(MentionText.activeQuery(in: "@Jo\u{3000}x", cursor: 5) == nil)
        #expect(MentionText.activeQuery(in: "@Jo", cursor: 4) == nil)
        #expect(MentionText.activeQuery(in: "@Jo", cursor: -1) == nil)
        #expect(MentionText.activeQuery(in: "", cursor: 0) == nil)
    }

    /// Offsets count UTF-16 units, as a text view's do: an emoji before the "@" moves it by two.
    @Test func offsetsCountUTF16Units() {
        #expect(MentionText.activeQuery(in: "😀 @Jo", cursor: 6) == MentionQuery(start: 3, end: 6, query: "Jo"))
        // Half of a surrogate pair is no whitespace, so an "@" right after an emoji sits inside a word.
        #expect(MentionText.activeQuery(in: "😀@Jo", cursor: 5) == nil)
    }

    // MARK: Whom a query finds

    private var candidates: [MentionCandidate] {
        [candidate("n1", "Joyful Ferret", alias: "SoftlyMossyLark"), candidate("n2", "Coral", alias: "GentlyPolarNewt")]
    }

    @Test func filterMatchesAcrossSpacesCaseInsensitively() {
        #expect(MentionText.filter(candidates, query: "joy").map(\.id) == ["n1"])
        #expect(MentionText.filter(candidates, query: "ferret").map(\.id) == ["n1"])
    }

    @Test func emptyQueryReturnsAll() {
        #expect(MentionText.filter(candidates, query: "").count == 2)
        #expect(MentionText.filter(candidates, query: "  ").count == 2)
    }

    @Test func filterMatchesTheAliasSoATypedAliasNarrowsTwoSameNamedCandidates() {
        let twins = [
            candidate("a1", "Alice", alias: "JoyfulFerret", discriminator: "JoyfulFerret"),
            candidate("a2", "Alice", alias: "CozyJade", discriminator: "CozyJade"),
            candidate("b", "Bob", alias: "SharpOnyx"),
        ]
        #expect(MentionText.filter(twins, query: "ali").map(\.id) == ["a1", "a2"])
        #expect(MentionText.filter(twins, query: "cozy").map(\.id) == ["a2"])
        #expect(MentionText.filter(twins, query: "sharp").map(\.id) == ["b"])
    }

    @Test func aQueryMatchesAnAliasWithItsSpacesRemoved() {
        let grown = [
            candidate(
                "a1", "Alice", alias: "ReallyJoyfulFerret QuietlyBoldCedar", discriminator: "ReallyJoyfulFerret QuietlyBoldCedar"),
            candidate("b", "Bob", alias: "SharplyKeenOnyx"),
        ]
        #expect(MentionText.filter(grown, query: "ferretquietly").map(\.id) == ["a1"])
        #expect(MentionText.filter(grown, query: "quietly").map(\.id) == ["a1"])
    }

    @Test func aPickInsertsTheLabelAndASpace() {
        let alice = candidate("a1", "Alice", alias: "JoyfulFerret", discriminator: "JoyfulFerret")
        #expect(MentionText.insertion(for: alice) == "@Alice (JoyfulFerret) ")
        #expect(alice.mention == MessageMention(nodeId: "a1", name: "Alice (JoyfulFerret)"))
    }

    // MARK: Where a body's names sit

    @Test func highlightsEveryOccurrenceOfMentionedName() {
        #expect(MentionText.spans(in: "@Coral hi @Coral", mentions: [MessageMention(nodeId: "n2", name: "Coral")]) == [0..<6, 10..<16])
    }

    @Test func longestNameWinsOverPrefix() {
        let mentions = [MessageMention(nodeId: "a", name: "Jay"), MessageMention(nodeId: "b", name: "Jaylene")]
        #expect(MentionText.spans(in: "hi @Jaylene", mentions: mentions) == [3..<11])
    }

    @Test func spansAreSortedAndLongestNameWins() {
        let mentions = [MessageMention(nodeId: "a", name: "Jay"), MessageMention(nodeId: "b", name: "Jaylene")]
        #expect(MentionText.spans(in: "@Jaylene and @Jay", mentions: mentions) == [0..<8, 13..<17])
    }

    @Test func aDiscriminatedTokenIsHighlightedWholeAndBeatsThePlainNamePrefix() {
        let body = "hey @Alice (JoyfulFerret) and @Alice"
        let mentions = [MessageMention(nodeId: "a1", name: "Alice (JoyfulFerret)"), MessageMention(nodeId: "a2", name: "Alice")]
        let length = body.utf16.count
        #expect(MentionText.spans(in: body, mentions: mentions) == [4..<(4 + "@Alice (JoyfulFerret)".utf16.count), (length - 6)..<length])
    }

    @Test func noMentionsLeavesTextUnstyled() {
        #expect(MentionText.spans(in: "plain @text", mentions: []).isEmpty)
        #expect(MentionText.spans(in: "", mentions: walter).isEmpty)
    }

    @Test func nameWithoutAtIsNotStyled() {
        #expect(MentionText.spans(in: "Coral is here", mentions: [MessageMention(nodeId: "n2", name: "Coral")]).isEmpty)
    }

    /// No word boundary, as on Android: "Coral" lights the front of "@Coralie". An empty name lights nothing, and two
    /// people sharing a name light one span.
    @Test func aTokenMatchesWithoutAWordBoundary() {
        #expect(MentionText.spans(in: "@Coralie", mentions: [MessageMention(nodeId: "n2", name: "Coral")]) == [0..<6])
        #expect(MentionText.spans(in: "@ hi", mentions: [MessageMention(nodeId: "n2", name: "")]).isEmpty)
        let twins = [MessageMention(nodeId: "a", name: "Sam"), MessageMention(nodeId: "b", name: "Sam")]
        #expect(MentionText.spans(in: "@Sam", mentions: twins) == [0..<4])
    }

    // MARK: Chips

    @Test func backspaceAtAChipsEndTakesTheWholeChip() {
        let chips = MentionText.spans(in: "hi @Walter", mentions: walter)
        #expect(MentionText.keepChipsWhole(chips, edits: [MentionEdit(range: 9..<10, text: "")]) == [MentionEdit(range: 3..<10, text: "")])
    }

    @Test func forwardDeleteAtAChipsStartTakesTheWholeChip() {
        let chips = MentionText.spans(in: "@Walter hi", mentions: walter)
        #expect(MentionText.keepChipsWhole(chips, edits: [MentionEdit(range: 0..<1, text: "")]) == [MentionEdit(range: 0..<7, text: "")])
    }

    @Test func aReplacementReachingIntoAChipTakesItWhole() {
        let chips = MentionText.spans(in: "@Walter hi", mentions: walter)
        #expect(
            MentionText.keepChipsWhole(chips, edits: [MentionEdit(range: 5..<10, text: "hey")]) == [MentionEdit(range: 0..<10, text: "hey")]
        )
    }

    @Test func typingInsideAChipLandsAfterIt() {
        let chips = MentionText.spans(in: "@Walter", mentions: walter)
        #expect(MentionText.keepChipsWhole(chips, edits: [MentionEdit(range: 3..<3, text: "x")]) == [MentionEdit(range: 7..<7, text: "x")])
    }

    @Test func editsThatLeaveChipsWholeAreKept() {
        let chips = MentionText.spans(in: "hi @Walter ok", mentions: walter)
        #expect(MentionText.keepChipsWhole(chips, edits: [MentionEdit(range: 10..<10, text: "s")]) == nil)
        #expect(MentionText.keepChipsWhole(chips, edits: [MentionEdit(range: 3..<3, text: "x")]) == nil)
        #expect(MentionText.keepChipsWhole(chips, edits: [MentionEdit(range: 10..<11, text: "")]) == nil)
        #expect(MentionText.keepChipsWhole(chips, edits: [MentionEdit(range: 3..<10, text: "")]) == nil)
        #expect(MentionText.keepChipsWhole([], edits: [MentionEdit(range: 5..<6, text: "")]) == nil)
    }

    @Test func widenedEditsThatMeetAreMerged() {
        let chips = MentionText.spans(
            in: "@Ann@Bob", mentions: [MessageMention(nodeId: "a", name: "Ann"), MessageMention(nodeId: "b", name: "Bob")])
        let edits = [MentionEdit(range: 3..<4, text: "x"), MentionEdit(range: 4..<5, text: "y")]
        #expect(MentionText.keepChipsWhole(chips, edits: edits) == [MentionEdit(range: 0..<8, text: "xy")])
    }

    @Test func aCursorTappedInsideAChipGoesToTheNearerEdge() {
        let chips = MentionText.spans(in: "hi @Walter", mentions: walter)
        #expect(MentionText.snapOutOfChips(chips, selection: 5..<5, from: nil) == 3..<3)
        #expect(MentionText.snapOutOfChips(chips, selection: 8..<8, from: nil) == 10..<10)
        #expect(MentionText.snapOutOfChips(chips, selection: 1..<1, from: nil) == 1..<1)
        // The middle of "@Abc" is as near one edge as the other, and a tie goes to the end.
        let even = MentionText.spans(in: "@Abc", mentions: [MessageMention(nodeId: "a", name: "Abc")])
        #expect(MentionText.snapOutOfChips(even, selection: 2..<2, from: nil) == 4..<4)
    }

    @Test func arrowKeysStepOverAChip() {
        let chips = MentionText.spans(in: "hi @Walter", mentions: walter)
        #expect(MentionText.snapOutOfChips(chips, selection: 9..<9, from: 10..<10) == 3..<3)
        #expect(MentionText.snapOutOfChips(chips, selection: 4..<4, from: 3..<3) == 10..<10)
    }

    /// A text view's selection has no direction, so Android's backwards case reads as a forward one here.
    @Test func aSelectionGrowsToTakeEveryChipItCuts() {
        let chips = MentionText.spans(in: "hi @Walter ok", mentions: walter)
        #expect(MentionText.snapOutOfChips(chips, selection: 0..<6, from: nil) == 0..<10)
        #expect(MentionText.snapOutOfChips(chips, selection: 6..<13, from: nil) == 3..<13)
    }

    /// The field's side of a typed edit (`MentionChips.transformInput`): the widened edit applied, and the cursor just past
    /// what replaced it; nothing when the edit leaves the chips whole.
    @Test func anEditIntoAChipComesBackApplied() throws {
        let chips = MentionText.spans(in: "hi @Walter ok", mentions: walter)
        let backspace = try #require(MentionText.edited("hi @Walter ok", chips: chips, replacing: 9..<10, with: ""))
        #expect(backspace.text == "hi  ok" && backspace.cursor == 3)
        let typed = try #require(MentionText.edited("hi @Walter ok", chips: chips, replacing: 5..<5, with: "x"))
        #expect(typed.text == "hi @Walterx ok" && typed.cursor == 11)
        #expect(MentionText.edited("hi @Walter ok", chips: chips, replacing: 11..<11, with: "x") == nil)
    }
}
