import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitAppCore

/// knit-next's mention contract (`vectors/mention-vouch-v1.json`, knit-next #247, knit-ios #36), checked as
/// `MentionVouchVectorTest` checks it on Android: every directory's labels, then every row through the rule and the
/// spans.
@Suite struct MentionVouchVectorTests {
    private static let file = MentionVouchVectors.file

    private static func index(_ name: String) throws -> PeerLabelIndex {
        let directory = try #require(file.directories[name], "no directory \(name)")
        return PeerLabelIndex(
            peers: directory.peers.map { (nodeId: $0.nodeId, name: $0.name) }, me: (nodeId: file.me.nodeId, name: file.me.name))
    }

    @Test func theConstantsAreOurs() {
        #expect(Self.file.maxTokens == Alias.maxTokens)
        #expect(Self.file.everyone == MentionCandidate.everyoneName)
        #expect(Self.file.window == MentionWindow.size)
    }

    /// Each label pins ADR 058's discriminator and its growth, which no other vector covers.
    @Test func everyDirectoryLabelsEveryIdAsAndroidDoes() throws {
        #expect(Set(Self.file.directories.keys) == ["plain", "clash"])
        for (name, directory) in Self.file.directories {
            let labels = try Self.index(name)
            let ids = directory.peers.map(\.nodeId) + [Self.file.me.nodeId] + directory.unknown
            #expect(Set(directory.labels.keys) == Set(ids), "\(name) pins a label for each id")
            for (nodeId, text) in directory.labels {
                #expect(labels.label(for: nodeId).text == text, "\(name): \(nodeId)")
                #expect(labels.mentionTexts(for: nodeId).first == text, "\(name): \(nodeId)'s first accepted text is its label")
            }
        }
    }

    @Test func everyRowKeepsAndLightsWhatAndroidDoes() throws {
        #expect(Self.file.cases.count == 23)
        for entry in Self.file.cases {
            let labels = try Self.index(entry.directory)
            #expect(["direct", "room", "group"].contains(entry.thread), "\(entry.label)")
            #expect((entry.roster != nil) == (entry.thread == "group"), "\(entry.label): a roster is a group's")
            let roster = entry.thread == "group" ? entry.roster ?? [] : nil
            let mentions = entry.mentions.map { MessageMention(nodeId: $0.nodeId, name: $0.name) }
            let kept = MentionText.vouched(
                mentions, sender: entry.sender, me: Self.file.me.nodeId, roster: roster, labels: labels, inWindow: entry.inWindow)
            #expect(kept == entry.kept.map { mentions[$0] }, "\(entry.label)")
            let spans = MentionText.spans(in: entry.body, mentions: kept).map { [$0.lowerBound, $0.upperBound] }
            #expect(spans == entry.spans, "\(entry.label)")
        }
    }

    @Test func everyThreadLeavesOutWhatAndroidDoes() {
        #expect(Self.file.windows.count == 5)
        for thread in Self.file.windows {
            let rows = thread.rows.map { MentionWindow.Row(id: $0.id, sender: $0.sender, sentAt: $0.sentAt, mentions: $0.mentions) }
            let blocked = Set(thread.blocked.map(ExactKey.init))
            let outside = MentionWindow.outside(rows, me: Self.file.me.nodeId, blocked: blocked)
            #expect(outside == Set(thread.outside.map(ExactKey.init)), "\(thread.label)")
        }
    }
}
