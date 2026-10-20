import Foundation
import KnitCrypto
import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// Add contact over the control lines (ADR 2026-10.tpr5): what `interop.py iphone-contact` sends, and what it reads back.
@Suite(.timeLimit(.minutes(1))) struct MeshControlContactTests {
    private static func person(_ seed: Int) throws -> IdentityKeys {
        try #require(IdentityKeys(signingSeed: fixtureBytes(32, seed: seed), agreementScalar: fixtureBytes(32, seed: seed + 100)))
    }

    private static func link(of keys: IdentityKeys, name: String) -> String {
        ContactCard.encode(keys, name: name, issuedAt: 1_790_000_000_000)?.url ?? ""
    }

    @Test func contactLinkNamesThisNodeInEveryForm() async throws {
        let rig = ControlRig()
        let reply = try await rig.send(#"{"cmd":"contact-link"}"#)
        #expect(reply["ok"] as? Bool == true && reply["reply"] as? String == "contact-link")
        for key in ["url", "scheme", "compact"] {
            let text = try #require(reply[key] as? String, "\(key)")
            guard case .card(let card) = ContactCard.parse(text) else {
                Issue.record("\(key) does not parse")
                continue
            }
            #expect(card.nodeId == rig.keys.nodeId)
        }
    }

    /// Through the mesh, a link pins the person and accepts their conversation, and `peers` then lists them.
    @Test func addContactPinsThePersonALinkNames() async throws {
        let rig = ControlRig()
        let sam = try Self.person(7)
        let reply = try await rig.send(#"{"cmd":"add-contact","text":"\#(Self.link(of: sam, name: "Sam"))"}"#)
        #expect(reply["ok"] as? Bool == true)
        #expect(reply["peer"] as? String == sam.nodeId.string)
        #expect(reply["verified"] as? Bool == false)
        #expect(rig.stores.peers.peer(sam.nodeId)?.publicKey == sam.bundle.encoded)
        #expect(rig.stores.conversations.acceptedConversations().contains(sam.nodeId.string))
        let peers = try #require(try await rig.send(#"{"cmd":"peers"}"#)["peers"] as? [[String: Any]])
        #expect(peers.contains { $0["peer"] as? String == sam.nodeId.string })
    }

    @Test func addContactGoesThroughTheActionsGivenWithItsPathAndUnblock() async throws {
        let actions = RecordingActions(me: fixtureNodeId(1))
        let rig = ControlRig(actions: actions)
        let sam = try Self.person(7)
        let link = Self.link(of: sam, name: "Sam")
        _ = try await rig.send(#"{"cmd":"add-contact","text":"\#(link)"}"#)
        _ = try await rig.send(#"{"cmd":"add-contact","text":"\#(VerifyPayload.encode(sam.bundle))","scan":true}"#)
        _ = try await rig.send(#"{"cmd":"add-contact","text":"\#(link)","unblock":true}"#)
        #expect(
            actions.calls == [
                "add-contact \(sam.nodeId) link", "add-contact \(sam.nodeId) scan", "add-contact \(sam.nodeId) link unblocking",
            ])
    }

    @Test func whatIsNoCardIsRefusedWithItsReason() async throws {
        let actions = RecordingActions(me: fixtureNodeId(1))
        let rig = ControlRig(actions: actions)
        let reply = try await rig.send(#"{"cmd":"add-contact","text":"hello"}"#)
        #expect(reply["ok"] as? Bool == false)
        #expect((reply["error"] as? String)?.hasPrefix("not a contact card") == true)
        let missing = try await rig.send(#"{"cmd":"add-contact"}"#)
        #expect(missing["ok"] as? Bool == false)
        #expect(actions.calls.isEmpty)
    }

    @Test func ourOwnCardIsRefused() async throws {
        let rig = ControlRig()
        let own = try #require(try await rig.send(#"{"cmd":"contact-link"}"#)["url"] as? String)
        let reply = try await rig.send(#"{"cmd":"add-contact","text":"\#(own)"}"#)
        #expect(reply["ok"] as? Bool == false)
        #expect(rig.stores.peers.peer(rig.keys.nodeId) == nil)
    }
}
