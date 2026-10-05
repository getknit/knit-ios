import Foundation
import KnitCrypto
import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// Reacting over the control lines (ADR 2026-10.ehe6): what `interop.py iphone-react` sends, and what it reads back in
/// `messages`, in the shape Android's bridge reports.
@Suite(.timeLimit(.minutes(1))) struct MeshControlReactionTests {
    private let thumbs = "\u{1F44D}"

    /// Through the mesh: a reaction stands on its message in `messages`, and the same emoji again takes it back.
    @Test func aReactionStandsOnItsMessageAndTheSameEmojiTakesItBack() async throws {
        let rig = ControlRig()
        let posted = try #require(try await rig.send(#"{"cmd":"room","text":"hi"}"#)["id"] as? String)
        let me = rig.keys.nodeId.string
        let reacted = try await rig.send(#"{"cmd":"react","id":"\#(posted)","emoji":"\#(thumbs)","tag":"r1"}"#)
        #expect(reacted["reply"] as? String == "react" && reacted["ok"] as? Bool == true && reacted["tag"] as? String == "r1")
        #expect(reacted["id"] as? String == posted && reacted["from"] as? String == me && reacted["emoji"] as? String == thumbs)
        #expect(try await reactions(on: posted, in: rig) == [me: thumbs])
        let taken = try await rig.send(#"{"cmd":"react","id":"\#(posted)","emoji":"\#(thumbs)"}"#)
        #expect(taken["ok"] as? Bool == true && taken["emoji"] is NSNull)
        #expect(try await reactions(on: posted, in: rig)?.isEmpty == true)
    }

    @Test func aReactionToNothingOrThatIsNotOneEmojiIsRefused() async throws {
        let rig = ControlRig()
        let posted = try #require(try await rig.send(#"{"cmd":"room","text":"hi"}"#)["id"] as? String)
        let nowhere = try await rig.send(#"{"cmd":"react","id":"nothing-here","emoji":"\#(thumbs)"}"#)
        #expect(nowhere["ok"] as? Bool == false)
        let words = try await rig.send(#"{"cmd":"react","id":"\#(posted)","emoji":"lol"}"#)
        #expect(words["ok"] as? Bool == false)
        #expect(try await rig.send(#"{"cmd":"react","id":"\#(posted)"}"#)["error"] as? String == "missing emoji")
        #expect(try await rig.send(#"{"cmd":"react","emoji":"\#(thumbs)"}"#)["error"] as? String == "missing id")
    }

    @Test func someonesReactionIsAnEventLine() async throws {
        let rig = ControlRig()
        let reactor = fixtureNodeId(4)
        let lines = try await rig.report(.reacted(ReactionRecord(messageId: "m1", reactor: reactor, emoji: nil, updatedAt: 5)))
        let line = try #require(lines.first)
        #expect(line["event"] as? String == "reaction" && line["id"] as? String == "m1")
        #expect(line["from"] as? String == reactor.string && line["emoji"] is NSNull)
    }

    @Test func reactionsGoThroughTheActionsGiven() async throws {
        let actions = RecordingActions(me: fixtureNodeId(1))
        let rig = ControlRig(actions: actions)
        _ = try await rig.send(#"{"cmd":"react","id":"m1","emoji":"\#(thumbs)"}"#)
        #expect(actions.calls == ["react m1 \(thumbs)"])
    }

    /// The `reactions` object `messages` reports on message `id`.
    private func reactions(on id: String, in rig: ControlRig) async throws -> [String: String]? {
        let thread = try await rig.send(#"{"cmd":"messages","conv":"nearby"}"#)
        let messages = try #require(thread["messages"] as? [[String: Any]])
        return messages.first { $0["id"] as? String == id }?["reactions"] as? [String: String]
    }
}

extension RecordingActions {
    func react(to messageId: String, with emoji: String) -> ReactionRecord? {
        record("react \(messageId) \(emoji)")
        return refuses ? nil : ReactionRecord(messageId: messageId, reactor: me, emoji: emoji, updatedAt: 1)
    }
}
