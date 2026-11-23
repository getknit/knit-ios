import KnitCrypto
import KnitStore
import Testing

@testable import KnitAppCore

/// Which of a received row's mentions a bubble lights (knit-ios #36, knit-next #247): every case of the paired contract's
/// list, which `vectors/mention-vouch-v1.json` pins with Android's own ids, here with ids of this suite's.
@Suite struct MentionVouchTests {
    /// Us, Walter.
    private static let me = (nodeId: "w", name: "Walter")
    /// The contract's `plain` directory: Alice, Bob and a blank-named peer.
    private static let plain = [(nodeId: "a", name: "Alice"), (nodeId: "b", name: "Bob"), (nodeId: "g", name: "")]
    /// `plain` and X, whose name keys as Alice's: a Cyrillic е (U+0435) for the e (ADR 2026-10.k99b).
    private static let clash = plain + [(nodeId: "x", name: "Alic\u{0435}")]

    private func labels(_ peers: [(nodeId: String, name: String)], presenter: NamePresenter = .asStored) -> PeerLabelIndex {
        PeerLabelIndex(peers: peers, me: Self.me, presenter: presenter)
    }

    /// The first `count` tokens of `nodeId`'s alias phrase, joined as a label's discriminator.
    private func tokens(_ nodeId: String, _ count: Int = 1, from start: Int = 0) -> String {
        Alias.tokens(for: nodeId)[start..<(start + count)].joined(separator: " ")
    }

    /// Which of `mentions` a row from `sender` keeps, in a group with `roster` or, without one, any other thread.
    private func kept(
        _ mentions: [MessageMention], from sender: String = "b", roster: [String]? = nil, in labels: PeerLabelIndex
    ) -> [MessageMention] {
        MentionText.vouched(mentions, sender: sender, me: Self.me.nodeId, roster: roster, labels: labels)
    }

    private func mention(_ nodeId: String, _ name: String) -> MessageMention {
        MessageMention(nodeId: nodeId, name: name)
    }

    // MARK: The name rule

    @Test func theReadersLabelIsKeptInAnyCase() {
        let mentions = [mention("a", "Alice"), mention("a", "ALICE")]
        #expect(kept(mentions, in: labels(Self.plain)) == mentions)
    }

    /// What a sender that saw a clash this phone does not writes: the label grown by the id's own tokens, to all ten.
    @Test func theLabelGrownByTheIdsOwnTokensIsKept() {
        let mentions = (1...Alias.maxTokens).map { mention("a", "Alice (\(tokens("a", $0)))") }
        #expect(kept(mentions, in: labels(Self.plain)) == mentions)
    }

    @Test func textsOutsideTheIdsAcceptedOnesDrop() {
        let mentions = [mention("a", "Alice (\(tokens("b")))"), mention("b", "Alice"), mention("a", tokens("a"))]
        #expect(kept(mentions, in: labels(Self.plain)).isEmpty)
    }

    @Test func anIdOutsideTheIndexIsKeptOnlyUnderItsAlias() {
        let mentions = [mention("u", "Alice"), mention("u", tokens("u")), mention("u", "\(tokens("u")) (\(tokens("u", from: 1)))")]
        #expect(kept(mentions, in: labels(Self.plain)) == Array(mentions.dropFirst()))
    }

    @Test func aBlankNamedPeerIsKeptUnderItsAliasAndItsGrowth() {
        let mentions = [mention("g", tokens("g")), mention("g", "\(tokens("g")) (\(tokens("g", from: 1)))"), mention("g", "Greg")]
        #expect(kept(mentions, in: labels(Self.plain)) == Array(mentions.prefix(2)))
    }

    @Test func ourOwnNameIsKeptAndAnotherDrops() {
        let mentions = [mention("w", "Walter"), mention("w", "Walter (\(tokens("w")))"), mention("w", "Wally")]
        #expect(kept(mentions, in: labels(Self.plain)) == Array(mentions.prefix(2)))
    }

    /// The content filter hides Alice's name here, so her label is her alias: her name drops, her alias stays.
    @Test func aNameTheContentFilterHidesDropsAndTheAliasIsKept() {
        let hiding = labels(Self.plain, presenter: NamePresenter { $0 == "Alice" ? "" : $0 })
        let alias = mention("a", tokens("a"))
        #expect(kept([mention("a", "Alice"), alias, mention("b", "Bob")], in: hiding) == [alias, mention("b", "Bob")])
    }

    // MARK: Our own words and `@everyone`

    @Test func ourOwnMessageKeepsEveryEntry() {
        let mentions = [mention("b", "Robert"), mention("u", "Anyone")]
        #expect(kept(mentions, from: Self.me.nodeId, in: labels(Self.plain)) == mentions)
    }

    @Test func everyoneIsLitInAGroupForAMemberOnly() {
        let body = "@everyone hi"
        let mentions = [mention("a", "everyone"), mention("b", "everyone")]
        let index = labels(Self.plain)
        #expect(MentionText.spans(in: body, mentions: kept(mentions, roster: ["w", "a", "b"], in: index)) == [0..<9])
        #expect(kept(mentions, roster: ["w", "g"], in: index).isEmpty, "nobody it names is a member")
        #expect(kept(mentions, in: index).isEmpty, "the room or a DM")
        #expect(kept([mention("w", "everyone")], roster: ["a"], in: index).count == 1, "ours, whatever the roster")
        #expect(kept([mention("a", "Everyone")], roster: ["w", "a"], in: index).isEmpty, "the word is exact")
    }

    /// A peer named "everyone" is mentioned by name in a DM, as any name is. In a group it is not a member of, its own
    /// entry draws plain, with no fall-through to its label (the contract's revision 1).
    @Test func aPeerNamedEveryoneIsJudgedByNameOutsideAGroup() {
        let index = labels(Self.plain + [(nodeId: "e", name: "everyone")])
        #expect(index.label(for: "e").text == "everyone")
        #expect(kept([mention("e", "everyone")], from: "e", in: index).count == 1)
        #expect(kept([mention("e", "everyone")], from: "e", roster: ["w", "a"], in: index).isEmpty)
    }

    // MARK: Spans

    @Test func aTokenWithOneKeptEntryOfTwoIsLit() {
        let mentions = [mention("u", "Alice"), mention("a", "Alice")]
        #expect(MentionText.spans(in: "hi @Alice", mentions: kept(mentions, in: labels(Self.plain))) == [3..<9])
    }

    @Test func aShorterKeptTokenIsLitInsideADroppedLongerOne() {
        let mentions = [mention("u", "Alice (zz)"), mention("a", "Alice")]
        #expect(MentionText.spans(in: "@Alice (zz) hi", mentions: kept(mentions, in: labels(Self.plain))) == [0..<6])
    }

    // MARK: The bounds (the contract's revision 2)

    /// Sixteen distinct ids reach the name rule first, so a seventeenth's entry draws plain; listed first, it lights.
    @Test func onlyTheFirstSixteenIdsAreJudged() {
        let others = (1...MentionVouch.maxJudgedIds).map { mention("u\($0)", "x") }
        let alice = mention("a", "Alice")
        let body = "@x @Alice"
        #expect(MentionText.spans(in: body, mentions: kept(others + [alice], in: labels(Self.plain))).isEmpty)
        #expect(MentionText.spans(in: body, mentions: kept([alice] + others, in: labels(Self.plain))) == [3..<9])
    }

    /// Entries settled before the name rule, ours and a group's `everyone`, never count toward the sixteen.
    @Test func entriesSettledBeforeTheNameRuleDoNotCount() {
        let everyone = (1...MentionVouch.maxJudgedIds).map { mention("m\($0)", "everyone") }
        let others = (1...(MentionVouch.maxJudgedIds - 1)).map { mention("u\($0)", "x") }
        let roster = everyone.map(\.nodeId) + ["w"]
        #expect(kept(everyone + others + [mention("a", "Alice")], roster: roster, in: labels(Self.plain)).count == 17)
    }

    /// A name of 512 UTF-16 units is judged, and one of 513 drops; both key to "alice".
    @Test func aNamePastFiveHundredTwelveUnitsDrops() {
        let longest = mention("a", "Alice" + String(repeating: "\u{200B}", count: 507))
        let longer = mention("a", "Alice" + String(repeating: "\u{200B}", count: 508))
        #expect(longest.name.utf16.count == MentionVouch.maxNameUnits)
        #expect(kept([longest, longer], in: labels(Self.plain)) == [longest])
    }

    /// Outside its thread's window, a row's name rule keeps nothing; `everyone` in a group is settled before it.
    @Test func outsideTheWindowOnlyTheStepsBeforeTheNameRuleKeep() {
        let index = labels(Self.plain)
        let alice = mention("a", "Alice")
        #expect(MentionText.vouched([alice], sender: "b", me: Self.me.nodeId, roster: nil, labels: index, inWindow: false).isEmpty)
        let everyone = [mention("a", "everyone")]
        let roster = ["w", "a", "b"]
        #expect(MentionText.vouched(everyone, sender: "b", me: Self.me.nodeId, roster: roster, labels: index, inWindow: false) == everyone)
        #expect(MentionText.vouched([alice], sender: "w", me: Self.me.nodeId, roster: nil, labels: index, inWindow: false) == [alice])
    }

    // MARK: A lookalike

    @Test func aClashingNameIsKeptOnlyWithItsDiscriminator() {
        let index = labels(Self.clash)
        #expect(index.label(for: "a").text == "Alice (\(tokens("a")))")
        #expect(index.label(for: "x").text == "Alic\u{0435} (\(tokens("x")))")
        let names = ["Alic\u{0435}", "Alice", "Alice\u{FE0F}", "Alic\u{0435} (\(tokens("x")))", "Alice (\(tokens("x")))"]
        #expect(kept(names.map { mention("x", $0) }, in: index).map(\.name) == Array(names.suffix(2)))
    }

    /// The accepted cost: a sender that saw no clash writes "@Alice", which draws plain where this phone sees one.
    @Test func aBareNameDropsWhereTheReaderSeesAClash() {
        let mentions = [mention("a", "Alice"), mention("a", "Alice (\(tokens("a")))")]
        #expect(kept(mentions, in: labels(Self.clash)) == [mentions[1]])
    }

    @Test func aLabelGrownByAnotherIdsTokensDrops() {
        #expect(kept([mention("x", "Alice (\(tokens("a")))")], in: labels(Self.clash)).isEmpty)
    }
}
