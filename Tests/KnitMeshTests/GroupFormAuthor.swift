import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// One member of a group authoring group-form frames toward the engine under test, as Android's `GroupRatchetEngine` seals
/// them (`GroupRatchetAuthor`, `InboundPipelineTest.kt:5675-5723`, at knit-next `cbf2a487`), with its seeds sent as
/// `CTL_GROUP_KEY` DMs through ``AndroidPeer``'s DM ratchet. Phase P6a2 receives what it sends; what the engine seals in the
/// group form since phase P6b, ``GroupFormReader`` reads.
final class GroupFormAuthor {
    let android: AndroidPeer
    let groupId: String
    private let engine = GroupRatchetEngine()
    private(set) var chain: GroupRatchetEngine.SendChain

    /// `android` minting its first epoch in `groupId` at `mintedAt` on its own clock.
    init(_ android: AndroidPeer, in groupId: String, mintedAt: Int64 = 5) {
        self.android = android
        self.groupId = groupId
        chain = engine.mint(groupId: groupId, selfId: android.nodeId, previousEpoch: 0, now: mintedAt)
    }

    /// The seed of the epoch it seals under now.
    var seed: GroupSeed { GroupSeed(epoch: chain.epoch, seed: chain.seed, mintedAt: chain.mintedAt) }

    /// A device wipe: every chain lost, the numbering restarting at 1 under a fresh mint at `mintedAt`.
    func wipeAndRemint(at mintedAt: Int64) {
        chain = engine.mint(groupId: groupId, selfId: android.nodeId, previousEpoch: 0, now: mintedAt)
    }

    /// A forced rekey, as a leave's retires the chain and the next seal mints past it (knit-next ADR 2026-10.xgwj): the next
    /// epoch, minted at `mintedAt`.
    func rekey(at mintedAt: Int64) {
        chain = engine.mint(groupId: groupId, selfId: android.nodeId, previousEpoch: chain.epoch, now: mintedAt)
    }

    /// A group-form frame in the group `info` names, saying `body`, or carrying `ctl` and `rp`, stamped `sentAt`.
    func frame(
        _ info: GroupInfo, id: String, body: String, sentAt: Int64, ctl: Int? = nil, rp: ReactionContent? = nil
    ) throws -> TestFrame {
        try frame(info, id: id, sealing: MessageContent(body: body, ctl: ctl, rp: rp).encoded, sentAt: sentAt)
    }

    /// A group-form frame sealing `plaintext` as it is, which a malformed frame carries.
    func frame(_ info: GroupInfo, id: String, sealing plaintext: [UInt8], sentAt: Int64) throws -> TestFrame {
        let aad = MessageCrypto.header(id: id, senderId: android.nodeId.string, sentAt: sentAt, thread: groupId)
        let sealed = try #require(try engine.seal(chain, plaintext: plaintext, aad: aad))
        chain = sealed.chain
        let enc = EncEnvelope(
            version: EncEnvelope.Version.ratchet, nonce: sealed.nonce, ct: sealed.ct, keys: [], groupRatchet: sealed.header)
        let envelope = RelayEnvelope(
            type: .chat, id: id, senderId: android.nodeId.string, sentAt: sentAt, group: info, payload: ChatContent(enc: enc).encoded)
        return try android.peer.signed(envelope)
    }

    /// A sealed group reaction to `messageId`, `emoji` or a retraction, stamped `sentAt`.
    func reaction(_ info: GroupInfo, id: String, sentAt: Int64, on messageId: String, emoji: String?) throws -> TestFrame {
        let content = ReactionContent(messageId: messageId, emoji: emoji)
        return try frame(info, id: id, body: "", sentAt: sentAt, ctl: MessageContent.Control.reaction, rp: content)
    }

    /// Its seed as a `CTL_GROUP_KEY` DM to `recipient` under the DM ratchet against `prekey`, carrying `roster` when given,
    /// as a #47-era sender does (`rosterSeed`, `InboundPipelineTest.kt:7277-7288`).
    /// `relay` false hands it over point to point, so no custody keeps it.
    func seedDm(
        to recipient: TestPeer, prekey: PeerPrekey, id: String, sentAt: Int64, roster: GroupInfo? = nil, relay: Bool = true
    ) throws -> TestFrame {
        let payload = GroupKeyPayload(groupId: groupId, keys: [seed], group: roster)
        let content = MessageContent(body: "", ctl: MessageContent.Control.groupKey, gk: payload)
        return try android.dm(content, to: recipient, prekey: prekey, id: id, sentAt: sentAt, relay: relay)
    }
}

extension EngineFixture {
    /// Holds the group of `me` and `others` as a row, its creator the first of `others`, and answers the roster its frames
    /// carry (`seedRatchetGroup`, `InboundPipelineTest.kt:5726-5731`).
    @discardableResult
    func holdGroup(with others: [TestPeer], left: Bool = false) -> GroupInfo {
        let info = KnitMeshTests.roster([me] + others, createdBy: others[0])
        let members = info.members.map { GroupMember(nodeId: $0) }
        stores.groups.save(GroupRecord(id: info.id, createdBy: info.createdBy, createdAt: 1, hasLeft: left, roster: members))
        return info
    }

    /// Takes `member` off the held group's roster as a signed leave stamped `leftAt` leaves it (`depart`,
    /// `InboundPipelineTest.kt:7066-7080`).
    func depart(_ member: TestPeer, from info: GroupInfo, at leftAt: Int64) throws {
        let group = try #require(stores.groups.group(info.id))
        let departure = try #require(GroupRoster.depart(member.nodeId, at: leftAt, from: group))
        stores.groups.save(departure.group)
    }

    /// The effective members of the held group, and those held as departed, by their ids.
    func roster(of info: GroupInfo) -> (members: Set<String>, departed: Set<String>) {
        let group = stores.groups.group(info.id)
        return (Set(group?.members ?? []), Set(group?.departed ?? []))
    }

    /// The receive chains the engine holds from `sender` in `groupId` for `epoch`.
    func recvChains(_ groupId: String, from sender: TestPeer, epoch: Int = 1) -> [GroupRecvChainRecord] {
        stores.groupRatchet.recvChains(groupId, from: sender.nodeId, epoch: epoch)
    }

    /// DM-form chats of ours to `peer`: our acks and requests, each once, the first copy kept.
    func chats(to peer: TestPeer) -> [Written] {
        let me = ExactKey(self.me.nodeId.string)
        return Self.once(transport.written(.chat)).filter { written in
            ExactKey(written.envelope.senderId) == me && written.envelope.recipientId.map(ExactKey.init) == ExactKey(peer.nodeId.string)
        }
    }

    /// What our DM-form chats to `android` carry, as the phone reads them, each once.
    func controls(to android: AndroidPeer) -> [MessageContent] {
        chats(to: android.peer).compactMap { android.peek($0, from: me) }
    }
}
