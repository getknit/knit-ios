import Foundation
import KnitControl
import KnitCrypto
import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// Mentioning over the control lines (ADR 2026-10.nbhj): what `interop.py iphone-mention` sends, and the mentions it
/// reads back in `messages` and in a `message` event.
@Suite(.timeLimit(.minutes(1))) struct MeshControlMentionTests {
    @Test func everyMessageCommandTakesMentions() throws {
        let peer = fixtureNodeId(4)
        let lines: [(String, ControlCommand)] = [
            (#"{"cmd":"room","text":"hi","mentions":["\#(peer)"]}"#, .room("hi", photo: nil, replyTo: nil, mentions: [peer])),
            (
                #"{"cmd":"dm","to":"\#(peer)","text":"hi","mentions":["\#(peer)"]}"#,
                .directMessage(to: peer, text: "hi", photo: nil, replyTo: nil, mentions: [peer])
            ),
            (
                #"{"cmd":"group-send","conv":"g-1","text":"hi","mentions":["\#(peer)"]}"#,
                .group(.send("g-1", text: "hi", photo: nil, replyTo: nil, mentions: [peer]))
            ),
            (#"{"cmd":"room","text":"hi"}"#, .room("hi", photo: nil, replyTo: nil)),
        ]
        for (line, command) in lines {
            #expect(try ControlRequest.parse(line).get().command == command, "\(line)")
        }
        #expect(throws: ControlError.invalidNodeId("nobody")) {
            try ControlRequest.parse(#"{"cmd":"room","text":"hi","mentions":["nobody"]}"#).get()
        }
    }

    /// Through the mesh: a mention goes under the person's stored name, or their alias without one, and `messages`
    /// reports it; one whose "@" and name the text doesn't carry is dropped, as the composer drops it.
    @Test func aMentionGoesUnderTheStoredNameAndComesBack() async throws {
        let rig = ControlRig()
        let me = rig.keys.nodeId.string
        _ = try await rig.send(#"{"cmd":"name","name":"Near"}"#)
        let stranger = fixtureNodeId(4)
        let alias = Alias.displayName(stored: nil, nodeId: stranger.string)
        let sent = try await rig.send(#"{"cmd":"room","text":"@Near and @\#(alias)","mentions":["\#(me)","\#(stranger)"]}"#)
        let stray = try await rig.send(#"{"cmd":"room","text":"no names here","mentions":["\#(me)"]}"#)
        let thread = try await rig.send(#"{"cmd":"messages","conv":"nearby"}"#)
        let messages = try #require(thread["messages"] as? [[String: Any]])
        let mentions = try #require(messages.first { $0["id"] as? String == sent["id"] as? String }?["mentions"] as? [[String: Any]])
        #expect(mentions.map { $0["nodeId"] as? String } == [me, stranger.string])
        #expect(mentions.map { $0["name"] as? String } == ["Near", alias])
        #expect(stray["ok"] as? Bool == true)
        #expect(messages.first { $0["id"] as? String == stray["id"] as? String }?["mentions"] == nil, "nobody, so no field")
    }

    @Test func someonesMentionsRideItsEventLine() async throws {
        let rig = ControlRig()
        let sender = fixtureNodeId(4)
        let mention = MessageMention(nodeId: rig.keys.nodeId.string, name: "Near")
        let record = MessageRecord(
            id: "m1",
            senderId: sender,
            recipientId: nil,
            conversationId: Conversations.nearby,
            body: "@Near",
            sentAt: 5,
            mentions: [mention]
        )
        let line = try #require(try await rig.report(.received(record, isRequest: false)).first)
        let carried = try #require(line["mentions"] as? [[String: Any]])
        #expect(carried.count == 1 && carried.first?["nodeId"] as? String == mention.nodeId && carried.first?["name"] as? String == "Near")
    }

    /// The app's bridge writes its own mention, under its label, as its composer would; the control surface's is the
    /// fallback.
    @Test func theActionsMentionGoesWhenTheyWriteOne() async throws {
        let actions = RecordingActions(me: fixtureNodeId(1), label: "Label")
        let rig = ControlRig(actions: actions)
        let peer = fixtureNodeId(4)
        _ = try await rig.send(#"{"cmd":"dm","to":"\#(peer)","text":"@Label hi","mentions":["\#(peer)"]}"#)
        _ = try await rig.send(#"{"cmd":"group-send","conv":"g-1","text":"@Label hi","mentions":["\#(peer)"]}"#)
        #expect(actions.calls == ["dm \(peer) @Label hi mentioning Label", "group-send g-1 @Label hi mentioning Label"])
    }
}

extension RecordingActions {
    /// " mentioning" and each name, or nothing for none.
    static func describe(_ mentions: [MessageMention]) -> String {
        mentions.isEmpty ? "" : " mentioning " + mentions.map(\.name).joined(separator: ",")
    }
}
