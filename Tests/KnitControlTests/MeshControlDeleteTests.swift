import Foundation
import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// Deleting over the control lines (ADR 2026-10.u7cq): what `interop.py iphone-delete` sends, and what it reads back.
@Suite(.timeLimit(.minutes(1))) struct MeshControlDeleteTests {
    /// Through the mesh, a deleted message leaves `messages`, and deleting it again is refused.
    @Test func aDeletedMessageLeavesItsThread() async throws {
        let rig = ControlRig()
        let posted = try #require(try await rig.send(#"{"cmd":"room","text":"hi"}"#)["id"] as? String)
        let deleted = try await rig.send(#"{"cmd":"delete-message","id":"\#(posted)","tag":"d1"}"#)
        #expect(deleted["reply"] as? String == "delete-message" && deleted["ok"] as? Bool == true)
        #expect(deleted["id"] as? String == posted && deleted["tag"] as? String == "d1")
        let thread = try await rig.send(#"{"cmd":"messages","conv":"nearby"}"#)
        #expect((thread["messages"] as? [Any])?.isEmpty == true)
        let again = try await rig.send(#"{"cmd":"delete-message","id":"\#(posted)"}"#)
        #expect(again["ok"] as? Bool == false && (again["error"] as? String)?.isEmpty == false)
        #expect(rig.stores.messages.contains(posted), "its id is remembered")
    }

    /// Through the mesh, a chat with nothing left in it deletes nothing, and that is no error.
    @Test func aChatSaysWhetherItHadAnythingToDelete() async throws {
        let rig = ControlRig()
        _ = try await rig.send(#"{"cmd":"room","text":"hi"}"#)
        let cleared = try await rig.send(#"{"cmd":"delete-chat","conv":"nearby"}"#)
        #expect(cleared["reply"] as? String == "delete-chat" && cleared["ok"] as? Bool == true)
        #expect(cleared["conv"] as? String == "nearby" && cleared["deleted"] as? Bool == true)
        let empty = try await rig.send(#"{"cmd":"delete-chat","conv":"nearby"}"#)
        #expect(empty["ok"] as? Bool == true && empty["deleted"] as? Bool == false)
    }

    @Test func deletesGoThroughTheActionsGiven() async throws {
        let actions = RecordingActions(me: fixtureNodeId(1))
        let rig = ControlRig(actions: actions)
        _ = try await rig.send(#"{"cmd":"delete-message","id":"m1"}"#)
        _ = try await rig.send(#"{"cmd":"delete-chat","conv":"g-1"}"#)
        #expect(actions.calls == ["delete-message m1", "delete-chat g-1"])
    }

    @Test func aDeleteNamesWhatItDeletes() async throws {
        let rig = ControlRig()
        #expect(try await rig.send(#"{"cmd":"delete-message","conv":"nearby"}"#)["error"] as? String == "missing id")
        #expect(try await rig.send(#"{"cmd":"delete-chat","id":"m1"}"#)["error"] as? String == "missing conv")
    }
}

extension RecordingActions {
    func deleteMessage(_ id: String) -> Bool {
        record("delete-message \(id)")
        return !refuses
    }

    func deleteChat(_ conversationId: String) -> Bool {
        record("delete-chat \(conversationId)")
        return !refuses
    }
}
