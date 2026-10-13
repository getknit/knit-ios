import Foundation
import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// Typing cues over the control lines: what `interop.py iphone-typing` sends, and what it reads back in `status` and the
/// event lines, in the shape Android's bridge reports in `STATE.typing`.
@Suite(.timeLimit(.minutes(1))) struct MeshControlTypingTests {
    @Test func aThreadTakesOneCueEveryEightSecondsAndTheRoomIsTheDefault() async throws {
        let rig = ControlRig()
        let first = try await rig.send(#"{"cmd":"typing","conv":"nearby","tag":"t1"}"#)
        #expect(first["reply"] as? String == "typing" && first["ok"] as? Bool == true && first["tag"] as? String == "t1")
        #expect(first["conv"] as? String == "nearby" && first["sent"] as? Bool == true)
        let again = try await rig.send(#"{"cmd":"typing"}"#)
        #expect(again["conv"] as? String == "nearby" && again["sent"] as? Bool == false, "the throttle holds it")
        let peer = fixtureNodeId(4).string
        let direct = try await rig.send(#"{"cmd":"typing","to":"\#(peer)"}"#)
        #expect(direct["conv"] as? String == peer && direct["sent"] as? Bool == true, "another thread, Android's `to`")
        let left = try await rig.send(#"{"cmd":"typing","conv":"g-nowhere"}"#)
        #expect(left["ok"] as? Bool == true && left["sent"] as? Bool == false, "a group we do not hold")
    }

    @Test func whoIsTypingIsAnEventLineAndInStatus() async throws {
        let rig = ControlRig()
        #expect((try await rig.send(#"{"cmd":"status"}"#)["typing"] as? [String: [String]])?.isEmpty == true)
        let typist = fixtureNodeId(4)
        let lines = try await rig.report(.typing([Conversations.nearby: [typist]]))
        let line = try #require(lines.first)
        #expect(line["event"] as? String == "typing")
        #expect(line["typing"] as? [String: [String]] == ["nearby": [typist.string]])
        let ended = try #require(try await rig.report(.typing([:])).first)
        #expect((ended["typing"] as? [String: [String]])?.isEmpty == true)
    }

    @Test func cuesGoThroughTheActionsGiven() async throws {
        let actions = RecordingActions(me: fixtureNodeId(1))
        let rig = ControlRig(actions: actions)
        _ = try await rig.send(#"{"cmd":"typing","conv":"g-1"}"#)
        #expect(actions.calls == ["typing g-1"])
    }
}

extension RecordingActions {
    func noteTyping(in thread: String) -> Bool {
        record("typing \(thread)")
        return !refuses
    }
}
