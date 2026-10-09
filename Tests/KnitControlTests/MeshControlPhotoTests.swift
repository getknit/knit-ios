import Foundation
import KnitCrypto
import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// Photos over the control lines (ADR 2026-10.nh55): what a run sends, and what it reads back about photos owed, and
/// what the content filter made of each message (ADR 2026-10.e4kz).
@Suite(.timeLimit(.minutes(1))) struct MeshControlPhotoTests {
    /// A photo goes out with its message, the reply names the blob it is kept under, and a thread's lines say whether
    /// each photo's bytes are here, so a run can tell a photo that arrived from one still owed.
    @Test func aPhotoIsSentAndAThreadSaysWhetherItsBytesAreHere() async throws {
        let rig = ControlRig()
        let sent = try await rig.send(#"{"cmd":"room","text":"look","photo":"AQID","mime":"image/png"}"#)
        #expect(sent["attachmentHash"] as? String == BlobHash(of: [1, 2, 3]).string)
        let owed = BlobHash(of: Array("on its way".utf8))
        rig.stores.messages.save(
            MessageRecord(
                id: "far",
                senderId: fixtureNodeId(4),
                recipientId: nil,
                conversationId: Conversations.nearby,
                body: "",
                sentAt: 2,
                attachment: MessageAttachment(hash: owed, mime: "image/jpeg")
            )
        )
        let thread = try await rig.send(#"{"cmd":"messages","conv":"nearby"}"#)
        let lines = try #require(thread["messages"] as? [[String: Any]])
        let ours = try #require(lines.first { $0["id"] as? String == sent["id"] as? String })
        #expect(ours["attachmentMime"] as? String == "image/png" && ours["attachmentHeld"] as? Bool == true)
        let theirs = try #require(lines.first { $0["id"] as? String == "far" })
        #expect(theirs["attachmentHash"] as? String == owed.string && theirs["attachmentHeld"] as? Bool == false)
        #expect(try await rig.send(#"{"cmd":"room","text":"hi"}"#)["attachmentHash"] is NSNull, "a message without one names none")
    }

    /// A photo the node already holds goes as that blob, as a pick does (ADR 2026-10.f3mv): a room picture sent again
    /// in a DM keeps its public name, and the reply says so.
    @Test func aPhotoTheNodeHoldsGoesAsThatBlob() async throws {
        let rig = ControlRig()
        let posted = try await rig.send(#"{"cmd":"room","text":"look","photo":"AQID"}"#)
        #expect(posted["reused"] as? Bool == false)
        let to = fixtureNodeId(4).string
        let forwarded = try await rig.send(#"{"cmd":"dm","to":"\#(to)","photo":"AQID"}"#)
        #expect(forwarded["reused"] as? Bool == true)
        #expect(forwarded["attachmentHash"] as? String == BlobHash(of: [1, 2, 3]).string, "under the room's own hash, with no key")
        #expect(try await rig.send(#"{"cmd":"room","text":"hi"}"#)["reused"] == nil, "a message without a photo says nothing")
    }

    /// A thread's lines say which messages the content filter flagged or has yet to screen, and say nothing of the rest
    /// (ADR 2026-10.e4kz).
    @Test func aThreadSaysWhatTheContentFilterMadeOfEachMessage() async throws {
        let rig = ControlRig()
        for (id, moderation) in [("flagged", MessageModeration.flagged), ("waiting", .waiting), ("clear", .clear)] {
            rig.stores.messages.save(
                MessageRecord(
                    id: id,
                    senderId: fixtureNodeId(4),
                    recipientId: nil,
                    conversationId: Conversations.nearby,
                    body: id,
                    sentAt: 2,
                    moderation: moderation
                )
            )
        }
        let thread = try await rig.send(#"{"cmd":"messages","conv":"nearby"}"#)
        let lines = try #require(thread["messages"] as? [[String: Any]])
        #expect(lines.map { $0["moderation"] as? String } == ["flagged", "waiting", nil])
    }
}

extension RecordingActions {
    /// Holds no picture: every photo goes as it was given.
    func heldPhoto(picked _: [UInt8]) -> OutgoingPhoto? {
        nil
    }
}
