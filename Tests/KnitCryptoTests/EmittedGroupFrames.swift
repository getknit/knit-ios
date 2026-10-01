import KnitCrypto
import KnitTestSupport
import KnitWire

/// Carol's group frames for `ios-emitted-v1.json` (ADR 2026-09.n393, companion change A5): a v1 group message she
/// seals to knit-next's Alice and Bob, her rename of the group, and her leaving it. knit-next's `IosEmittedVectorTest`
/// opens the message as Alice and as Bob, derives the group's id from its roster, and verifies the other two.
enum EmittedGroupFrames {
    static let chatId = FrameId.text(for: fixtureBytes(16, seed: 33))
    static let renameId = FrameId.text(for: fixtureBytes(16, seed: 34))
    static let leaveId = FrameId.text(for: fixtureBytes(16, seed: 35))
    static let chatSentAt: Int64 = 1_756_200_003_000
    static let renameSentAt: Int64 = 1_756_200_004_000
    static let leaveSentAt: Int64 = 1_756_200_005_000
    static let body = "Hi both, from Swift"
    static let name = "Swift crew"
    /// The founding members, by their names in the vector files, in roster order.
    static let memberNames = ["alice", "bob", "carol"]

    /// The roster Carol's frames carry: Alice and Bob in pick order, then Carol, who made the group.
    static func roster(alice: IdentityKeys, bob: IdentityKeys, carol: IdentityKeys, name: String? = nil) -> GroupInfo {
        let members = [alice, bob, carol].map(\.nodeId.string)
        return GroupInfo(id: GroupId.derive(members), name: name, members: members, createdBy: carol.nodeId.string)
    }

    /// The group message, sealed to Alice and Bob under the header whose thread is the group's id.
    static func chat(carol: IdentityKeys, alice: IdentityKeys, bob: IdentityKeys) throws -> RelayEnvelope? {
        let group = roster(alice: alice, bob: bob, carol: carol)
        let header = MessageCrypto.header(id: chatId, senderId: carol.nodeId.string, sentAt: chatSentAt, thread: group.id)
        let recipients = [alice.nodeId: alice.bundle, bob.nodeId: bob.bundle]
        guard let sealed = try MessageCrypto.seal(MessageContent(body: body).encoded, header: header, to: recipients) else {
            return nil
        }
        return RelayEnvelope(
            type: .chat,
            id: chatId,
            senderId: carol.nodeId.string,
            sentAt: chatSentAt,
            group: group,
            payload: ChatContent(enc: sealed).encoded
        )
    }

    /// The rename: the roster with its new name, and an empty payload.
    static func rename(carol: IdentityKeys, alice: IdentityKeys, bob: IdentityKeys) -> RelayEnvelope {
        let group = roster(alice: alice, bob: bob, carol: carol, name: name)
        return RelayEnvelope(
            type: .groupUpdate, id: renameId, senderId: carol.nodeId.string, sentAt: renameSentAt, group: group, payload: [])
    }

    /// Carol leaving: no roster, and the group's id in the payload.
    static func leave(carol: IdentityKeys, alice: IdentityKeys, bob: IdentityKeys) -> RelayEnvelope {
        let groupId = roster(alice: alice, bob: bob, carol: carol).id
        let payload = GroupLeaveContent(groupId: groupId).encoded
        return RelayEnvelope(type: .groupLeave, id: leaveId, senderId: carol.nodeId.string, sentAt: leaveSentAt, payload: payload)
    }

    /// Whether a committed group message is still what Carol would send, short of the fresh key material: every layer
    /// re-encodes to its own bytes, it carries the roster and the clock `chat` uses, Carol's signature verifies, and
    /// Alice and Bob each open it to the body.
    static func isCurrentChat(_ hex: String, carol: IdentityKeys, alice: IdentityKeys, bob: IdentityKeys) -> Bool {
        guard let bytes = Hex.decode(hex), let wire = try? WireEnvelope(decoding: bytes),
            let relay = try? RelayEnvelope(decoding: wire.signed), let chat = try? ChatContent(decoding: relay.payload),
            let envelope = chat.enc
        else {
            return false
        }
        let group = roster(alice: alice, bob: bob, carol: carol)
        let header = MessageCrypto.header(id: relay.id, senderId: relay.senderId, sentAt: relay.sentAt, thread: group.id)
        let reencodes = wire.encoded == bytes && relay.encoded == wire.signed && chat.encoded == relay.payload
        let addressed =
            relay.type == .chat && relay.id == chatId && relay.senderId == carol.nodeId.string && relay.sentAt == chatSentAt
            && relay.recipientId == nil && relay.group == group
        return reencodes && addressed && carol.bundle.isValidSignature(wire.sig, for: wire.signed)
            && MessageCrypto.open(envelope, header: header, as: alice)?.body == body
            && MessageCrypto.open(envelope, header: header, as: bob)?.body == body
    }
}
