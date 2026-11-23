import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// A thread's lit mentions, kept from one build to the next (knit-ios #36): whatever it keeps, every build lights what a
/// fresh judge would.
@Suite struct MentionLightsTests {
    private static let me = Person(seed: 1).nodeId
    private static let alice = Person(seed: 2).nodeId
    private static let bob = Person(seed: 3).nodeId

    private func labels(alice name: String = "Alice", hiding: Bool = false) -> PeerLabelIndex {
        PeerLabelIndex(
            peers: [(nodeId: Self.alice.string, name: name), (nodeId: Self.bob.string, name: "Bob")],
            me: (nodeId: Self.me.string, name: "Walter"),
            presenter: hiding ? NamePresenter { $0 == "Alice" ? "" : $0 } : .asStored)
    }

    private func row(
        _ id: String, from sender: NodeId, _ body: String, _ mentions: [(NodeId, String)], at sentAt: Int64 = 1
    ) -> MessageRecord {
        MessageRecord(
            id: id,
            senderId: sender,
            recipientId: nil,
            conversationId: Conversations.nearby,
            body: body,
            sentAt: sentAt,
            mentions: mentions.map { MessageMention(nodeId: $0.0.string, name: $0.1) }
        )
    }

    /// `count` newer rows from Bob, each mentioning him, which push the older counted rows out of the window.
    private func filler(_ count: Int) -> [MessageRecord] {
        (0..<count).map { row("f\($0)", from: Self.alice, "@Bob hi", [(Self.bob, "Bob")], at: 100 + Int64($0)) }
    }

    /// A room's rows: names this phone gives and doesn't, our own row, `everyone`, an alias, and a list past the sixteen.
    private var rows: [MessageRecord] {
        let crowd = (10..<28).map { (Person(seed: $0).nodeId, "x") }
        return [
            row("1", from: Self.bob, "@Alice hi", [(Self.alice, "Alice")]),
            row("2", from: Self.bob, "@Ally hi", [(Self.alice, "Ally")]),
            row("3", from: Self.me, "@Ally hi", [(Self.alice, "Ally")]),
            row("4", from: Self.bob, "@everyone hi", [(Self.alice, "everyone"), (Self.me, "everyone")]),
            row("5", from: Self.bob, "@\(Alias.alias(for: Self.alice.string)) hi", [(Self.alice, Alias.alias(for: Self.alice.string))]),
            row("6", from: Self.bob, "@x @Alice", crowd + [(Self.alice, "Alice")]),
        ]
    }

    /// What a fresh judge lights for `rows` under `labels` and `roster`, each row in or out of the window `rows` make with
    /// `blocked` blocked.
    private func fresh(
        _ rows: [MessageRecord], _ labels: PeerLabelIndex, _ roster: [String]?, blocked: Set<NodeId> = []
    ) -> [[Range<Int>]] {
        let windowRows = rows.map { row in
            MentionWindow.Row(id: row.id, sender: row.senderId.string, sentAt: row.sentAt, mentions: row.mentions.count)
        }
        let outside = MentionWindow.outside(windowRows, me: Self.me.string, blocked: Set(blocked.map { ExactKey($0.string) }))
        return rows.map { row in
            let kept = MentionText.vouched(
                row.mentions,
                sender: row.senderId.string,
                me: Self.me.string,
                roster: roster,
                labels: labels,
                inWindow: !outside.contains(ExactKey(row.id))
            )
            return MentionText.spans(in: row.body, mentions: kept)
        }
    }

    /// One build: its labels, its roster, how many newer counted rows the thread holds, and whom we blocked.
    private struct Build {
        var labels: PeerLabelIndex
        var roster: [String]?
        var newer = 0
        var blocked: Set<NodeId> = []
    }

    /// Builds over the labels, the filter, the roster and the window: unchanged, a rename, the filter on and off, two
    /// rosters, then 200 newer counted rows that push the room's rows out of the window, their sender blocked and
    /// unblocked, and back.
    @Test func everyBuildLightsWhatAFreshJudgeWould() {
        var lights = MentionLights()
        let builds = [
            Build(labels: labels()),
            Build(labels: labels()),
            Build(labels: labels(alice: "Ally")),
            Build(labels: labels(alice: "Ally", hiding: true)),
            Build(labels: labels(hiding: true)),
            Build(labels: labels(), roster: [Self.me.string, Self.alice.string]),
            Build(labels: labels(), roster: [Self.me.string]),
            Build(labels: labels(), newer: MentionWindow.size),
            Build(labels: labels(), newer: MentionWindow.size - 1),
            Build(labels: labels(), newer: MentionWindow.size, blocked: [Self.alice]),
            Build(labels: labels(), newer: MentionWindow.size),
            Build(labels: labels()),
        ]
        for (index, build) in builds.enumerated() {
            let (labels, roster) = (build.labels, build.roster)
            let thread = rows + filler(build.newer)
            lights.begin(labels: labels, roster: roster, thread: thread, me: Self.me.string, blocked: build.blocked)
            let lit = thread.map { lights.spans(of: $0, me: Self.me.string) }
            #expect(lit == fresh(thread, labels, roster, blocked: build.blocked), "build \(index)")
        }
    }

    /// A row stored again under the same id lights for what it now is: another sender, other words, another list.
    @Test func aRowThatChangedIsJudgedAgain() {
        var lights = MentionLights()
        let labels = labels()
        let ours = row("1", from: Self.me, "@Ally hi", [(Self.alice, "Ally")])
        let theirs = row("1", from: Self.bob, "@Ally hi", [(Self.alice, "Ally")])
        let other = row("1", from: Self.bob, "@Alice hi", [(Self.alice, "Alice")])
        lights.begin(labels: labels, roster: nil, thread: [ours], me: Self.me.string, blocked: [])
        #expect(lights.spans(of: ours, me: Self.me.string) == [0..<5])
        lights.begin(labels: labels, roster: nil, thread: [theirs], me: Self.me.string, blocked: [])
        #expect(lights.spans(of: theirs, me: Self.me.string).isEmpty)
        lights.begin(labels: labels, roster: nil, thread: [other], me: Self.me.string, blocked: [])
        #expect(lights.spans(of: other, me: Self.me.string) == [0..<6])
    }
}
