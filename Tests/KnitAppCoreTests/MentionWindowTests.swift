import KnitWire
import Testing

@testable import KnitAppCore

/// A thread's window (the paired contract's revision 3): the newest 200 counted rows, by `sentAt`, then id.
@Suite struct MentionWindowTests {
    private static let me = "w"

    private func row(_ id: String, at sentAt: Int64, from sender: String = "b", mentions: Int = 1) -> MentionWindow.Row {
        MentionWindow.Row(id: id, sender: sender, sentAt: sentAt, mentions: mentions)
    }

    /// Whether the ids outside the window of `rows` are `ids`.
    private func leavesOut(_ rows: [MentionWindow.Row], _ ids: [String]) -> Bool {
        MentionWindow.outside(rows, me: Self.me) == Set(ids.map(ExactKey.init))
    }

    /// Ids `prefix000`…: ascending, so a larger number is a larger id.
    private func counted(_ count: Int, from start: Int64 = 1000) -> [MentionWindow.Row] {
        (0..<count).map { index in row("m" + String(1000 + index), at: start + Int64(index)) }
    }

    @Test func theOldestOfTwoHundredAndOneIsOutside() {
        #expect(leavesOut(counted(201).shuffled(), ["m1000"]))
    }

    @Test func aTieOnSentAtGoesToTheGreaterId() {
        var rows = counted(199, from: 2000)
        rows += [row("m-b", at: 1000), row("m-a", at: 1000)]
        #expect(leavesOut(rows, ["m-a"]))
    }

    /// Our own rows and rows without mentions never count, however new.
    @Test func ourRowsAndRowsWithoutMentionsDoNotCount() {
        let newer =
            (0..<25).map { row("o\($0)", at: 9000 + Int64($0), from: Self.me) }
            + (0..<25).map { row("p\($0)", at: 9100 + Int64($0), mentions: 0) }
        #expect(leavesOut(counted(201) + newer, ["m1000"]))
    }

    /// A blocked sender's rows don't count, so blocking a flooder brings the older rows back inside (revision 5).
    @Test func aBlockedSendersRowsDoNotCount() {
        var rows = counted(MentionWindow.size)
        rows.append(row("z-newest", at: 9999, from: "flooder"))
        #expect(MentionWindow.outside(rows, me: Self.me, blocked: [ExactKey("flooder")]).isEmpty)
        #expect(leavesOut(rows, ["m1000"]), "the same rows, nobody blocked")
    }

    @Test func twoHundredCountedRowsAreAllInside() {
        #expect(leavesOut(counted(MentionWindow.size), []))
    }

    /// Ids rank by UTF-16 code units, as Kotlin compares them.
    @Test func idsRankByTheirCodeUnits() {
        var rows = counted(199, from: 2000)
        rows += [row("\u{FF61}", at: 1000), row("\u{1F600}", at: 1000)]
        #expect(leavesOut(rows, ["\u{1F600}"]), "U+1F600's high surrogate sorts below U+FF61")
    }
}
