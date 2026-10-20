import KnitControl
import KnitCrypto
import KnitMesh
import KnitStore
import KnitSync
import KnitWire

/// Actions that record what they were asked, as the app's session would take them.
final class RecordingActions: ControlActions {
    let me: NodeId
    let refuses: Bool
    /// The label its composer mentions everyone under, or `nil` to leave a mention to the control surface.
    let label: String?
    private let recorded = Lock<[String]>([])

    init(me: NodeId, refuses: Bool = false, label: String? = nil) {
        self.me = me
        self.refuses = refuses
        self.label = label
    }

    func mention(of person: NodeId) -> MessageMention? {
        label.map { MessageMention(nodeId: person.string, name: $0) }
    }

    var calls: [String] { recorded.withLock { $0 } }

    func start() {
        record("start")
    }

    func stop() {
        record("stop")
    }

    func postToRoom(_ text: String, photo: OutgoingPhoto?, replyTo: MessageReply?, mentions: [MessageMention]) -> MessageRecord? {
        record("room \(text)\(Self.describe(photo))\(Self.describe(replyTo))\(Self.describe(mentions))")
        return refuses
            ? nil
            : MessageRecord(id: "room-\(text)", senderId: me, recipientId: nil, conversationId: Conversations.nearby, body: text, sentAt: 1)
    }

    func sendDirectMessage(
        _ text: String, to recipient: NodeId, photo: OutgoingPhoto?, replyTo: MessageReply?, mentions: [MessageMention]
    ) -> MessageRecord? {
        record("dm \(recipient) \(text)\(Self.describe(photo))\(Self.describe(replyTo))\(Self.describe(mentions))")
        return refuses
            ? nil
            : MessageRecord(id: "dm-\(text)", senderId: me, recipientId: recipient, conversationId: recipient.string, body: text, sentAt: 1)
    }

    func accept(_ conversationId: String) {
        record("accept \(conversationId)")
    }

    func updateProfile(name: String, status: String, openToChat: Bool) {
        record("profile \(name) \(status) \(openToChat)")
    }

    func setAvatar(_ jpeg: [UInt8]?) {
        record("avatar \(jpeg.map { "\($0.count) bytes" } ?? "cleared")")
    }

    func createGroup(with others: [NodeId]) -> GroupRecord? {
        record("group-create \(others.map(\.string).joined(separator: ","))")
        return refuses ? nil : group(named: "")
    }

    func sendGroupMessage(
        _ text: String, to groupId: String, photo: OutgoingPhoto?, replyTo: MessageReply?, mentions: [MessageMention]
    ) -> MessageRecord? {
        record("group-send \(groupId) \(text)\(Self.describe(photo))\(Self.describe(replyTo))\(Self.describe(mentions))")
        return refuses
            ? nil : MessageRecord(id: "group-\(text)", senderId: me, recipientId: nil, conversationId: groupId, body: text, sentAt: 1)
    }

    func renameGroup(_ groupId: String, to name: String) -> GroupRecord? {
        record("group-rename \(groupId) \(name)")
        return refuses ? nil : group(named: name)
    }

    func leaveGroup(_ groupId: String) -> Bool {
        record("group-leave \(groupId)")
        return !refuses
    }

    func block(_ peer: NodeId) {
        record("block \(peer)")
    }

    func unblock(_ peer: NodeId) {
        record("unblock \(peer)")
    }

    func addContact(_ card: ContactCard.Card, from source: ContactSource, unblock: Bool) -> ContactAdded {
        record("add-contact \(card.nodeId) \(source)\(unblock ? " unblocking" : "")")
        return refuses ? .failed : .added(card.nodeId)
    }

    private func group(named name: String) -> GroupRecord {
        GroupRecord(id: "g-1", name: name, createdBy: me.string, createdAt: 1, roster: [GroupMember(nodeId: me.string)])
    }

    func record(_ call: String) {
        recorded.withLock { $0.append(call) }
    }

    /// A photo, as a call names it: nothing when there is none.
    private static func describe(_ photo: OutgoingPhoto?) -> String {
        photo.map { " +\($0.bytes.count) bytes \($0.mime)" } ?? ""
    }
}
