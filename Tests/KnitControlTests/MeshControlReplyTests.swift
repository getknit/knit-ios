import Foundation
import KnitControl
import KnitCrypto
import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// Replying over the control lines (ADR 2026-10.mn29): what `interop.py iphone-reply` sends, and the quote it reads back
/// in `messages` and in a `message` event.
@Suite(.timeLimit(.minutes(1))) struct MeshControlReplyTests {
    @Test func everyMessageCommandTakesAReplyTo() throws {
        let peer = fixtureNodeId(4)
        let lines: [(String, ControlCommand)] = [
            (#"{"cmd":"room","text":"yes","replyTo":"m0"}"#, .room("yes", photo: nil, replyTo: "m0")),
            (
                #"{"cmd":"dm","to":"\#(peer)","text":"yes","replyTo":"m0"}"#,
                .directMessage(to: peer, text: "yes", photo: nil, replyTo: "m0")
            ),
            (
                #"{"cmd":"group-send","conv":"g-1","text":"yes","replyTo":"m0"}"#,
                .group(.send("g-1", text: "yes", photo: nil, replyTo: "m0"))
            ),
        ]
        for (line, command) in lines {
            #expect(try ControlRequest.parse(line).get().command == command, "\(line)")
        }
    }

    /// Through the mesh: `replyTo` quotes a message held here, under the author's stored name, and `messages` reports it.
    @Test func aReplyQuotesAMessageHeldHere() async throws {
        let rig = ControlRig()
        _ = try await rig.send(#"{"cmd":"name","name":"Near"}"#)
        let posted = try #require(try await rig.send(#"{"cmd":"room","text":"meet  at\nsix"}"#)["id"] as? String)
        let reply = try await rig.send(#"{"cmd":"room","text":"yes","replyTo":"\#(posted)","tag":"q1"}"#)
        #expect(reply["ok"] as? Bool == true && reply["tag"] as? String == "q1")
        let thread = try await rig.send(#"{"cmd":"messages","conv":"nearby"}"#)
        let messages = try #require(thread["messages"] as? [[String: Any]])
        let quote = try #require(messages.first { $0["id"] as? String == reply["id"] as? String }?["replyTo"] as? [String: Any])
        #expect(quote["id"] as? String == posted && quote["authorId"] as? String == rig.keys.nodeId.string)
        #expect(quote["author"] as? String == "Near" && quote["snippet"] as? String == "meet at six")
        #expect(quote["hasAttachment"] as? Bool == false)
        #expect(messages.first { $0["id"] as? String == posted }?["replyTo"] == nil, "a message that replies to nothing says so")
    }

    @Test func aReplyToAMessageNotHeldSendsNothing() async throws {
        let rig = ControlRig()
        let refused = try await rig.send(#"{"cmd":"room","text":"yes","replyTo":"nothing-here"}"#)
        #expect(refused["ok"] as? Bool == false)
        #expect((refused["error"] as? String)?.contains("nothing-here") == true)
        let thread = try await rig.send(#"{"cmd":"messages","conv":"nearby"}"#)
        #expect((thread["messages"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func someonesReplyCarriesItsQuoteInItsEventLine() async throws {
        let rig = ControlRig()
        let sender = fixtureNodeId(4)
        let quote = MessageReply(messageId: "m0", authorId: sender.string, author: "Ann", snippet: "see you", hasAttachment: true)
        let record = MessageRecord(
            id: "m1", senderId: sender, recipientId: nil, conversationId: Conversations.nearby, body: "ok", sentAt: 5, replyTo: quote)
        let line = try #require(try await rig.report(.received(record, isRequest: false)).first)
        let carried = try #require(line["replyTo"] as? [String: Any])
        #expect(carried["id"] as? String == "m0" && carried["author"] as? String == "Ann" && carried["hasAttachment"] as? Bool == true)
    }

    /// The app's bridge writes its own quote, as its composer would; the control surface's is the fallback.
    @Test func theActionsQuoteGoesWhenTheyWriteOne() async throws {
        let actions = RecordingActions(me: fixtureNodeId(1))
        let rig = ControlRig(actions: actions)
        let peer = fixtureNodeId(4)
        _ = try await rig.send(#"{"cmd":"dm","to":"\#(peer)","text":"yes","replyTo":"m0"}"#)
        _ = try await rig.send(#"{"cmd":"group-send","conv":"g-1","text":"yes","replyTo":"m0"}"#)
        #expect(actions.calls == ["dm \(peer) yes replying to m0 by Composer", "group-send g-1 yes replying to m0 by Composer"])
    }
}

extension RecordingActions {
    func quote(of messageId: String) -> MessageReply? {
        MessageReply(messageId: messageId, authorId: me.string, author: "Composer", snippet: "")
    }

    /// What a recorded send says of the quote it carried.
    static func describe(_ reply: MessageReply?) -> String {
        reply.map { " replying to \($0.messageId) by \($0.author)" } ?? ""
    }
}
