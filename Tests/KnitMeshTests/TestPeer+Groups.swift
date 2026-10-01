import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

/// A group's roster as its members' frames carry it, with the id its founding set hashes to.
func roster(_ members: [TestPeer], departed: [TestPeer] = [], name: String? = nil, createdBy creator: TestPeer) -> GroupInfo {
    GroupInfo(
        id: GroupId.derive((members + departed).map(\.nodeId.string)),
        name: name,
        members: members.map(\.nodeId.string),
        createdBy: creator.nodeId.string,
        departed: departed.isEmpty ? nil : departed.map(\.nodeId.string)
    )
}

/// The messages `events` announced, each with whether it came as a request.
func announced(_ events: [MeshEvent]) -> [(record: MessageRecord, isRequest: Bool)] {
    events.compactMap { event in
        guard case .received(let record, let isRequest) = event else {
            return nil
        }
        return (record, isRequest)
    }
}

/// The group message `written` carried, as `reader` opens it, or `nil` when it cannot.
func opened(_ written: Written, as reader: TestPeer) throws -> MessageContent? {
    let envelope = written.envelope
    let enc = try #require(try ChatContent(decoding: envelope.payload).enc)
    let thread = try #require(envelope.group?.id)
    let header = MessageCrypto.header(id: envelope.id, senderId: envelope.senderId, sentAt: envelope.sentAt, thread: thread)
    return MessageCrypto.open(enc, header: header, as: reader.keys)
}

extension TestPeer {
    /// A v1 group message from this peer, sealed to `recipients`, with `info` beside it.
    func groupMessage(
        _ body: String,
        in info: GroupInfo,
        to recipients: [Self],
        id: String,
        sentAt: Int64,
        content: MessageContent? = nil
    ) throws -> TestFrame {
        let header = MessageCrypto.header(id: id, senderId: nodeId.string, sentAt: sentAt, thread: info.id)
        let bundles = Dictionary(uniqueKeysWithValues: recipients.map { ($0.nodeId, $0.keys.bundle) })
        guard let sealed = try MessageCrypto.seal((content ?? MessageContent(body: body)).encoded, header: header, to: bundles) else {
            fatalError("a group message needs a recipient")
        }
        let envelope = RelayEnvelope(
            type: .chat, id: id, senderId: nodeId.string, sentAt: sentAt, group: info, payload: ChatContent(enc: sealed).encoded)
        return try signed(envelope)
    }

    /// A roster frame from this peer, such as a rename: the roster in `group`, and an empty payload.
    func groupUpdate(_ info: GroupInfo, id: String, sentAt: Int64) throws -> TestFrame {
        try signed(RelayEnvelope(type: .groupUpdate, id: id, senderId: nodeId.string, sentAt: sentAt, group: info, payload: []))
    }

    /// This peer leaving `groupId`.
    func groupLeave(_ groupId: String, id: String, sentAt: Int64) throws -> TestFrame {
        let payload = GroupLeaveContent(groupId: groupId).encoded
        return try signed(RelayEnvelope(type: .groupLeave, id: id, senderId: nodeId.string, sentAt: sentAt, payload: payload))
    }
}
