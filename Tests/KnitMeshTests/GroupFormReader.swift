import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// An Android member reading the group form the engine under test sends (phase P6b), ``GroupFormAuthor``'s mirror: our seed
/// DMs open through ``AndroidPeer``'s DM ratchet and commit there, their seeds are adopted into a ``GroupRatchetSessions`` of
/// its own over a memory store, as Kotlin's `adoptSeeds` runs after the DM's commit, and our group frames open through it,
/// as `decryptAndDeliverGroup` opens them (`InboundPipeline.kt:1598-1663`, at knit-next `cbf2a487`).
final class GroupFormReader {
    let android: AndroidPeer
    let store = MemoryGroupRatchetStore()
    let sessions: GroupRatchetSessions

    init(_ android: AndroidPeer) {
        self.android = android
        sessions = GroupRatchetSessions(nodeId: android.nodeId, store: store, transactor: MemoryTransactor(stores: [store]))
    }

    var nodeId: NodeId { android.nodeId }

    /// Opens `frame`, a DM-form chat from `sender` to this phone, committing it, and adopts the seeds a `CTL_GROUP_KEY`
    /// carries: answers what it said, or `nil` for a frame it cannot open.
    @discardableResult
    func receive(_ frame: Written, from sender: TestPeer) throws -> MessageContent? {
        guard ExactKey(frame.envelope.recipientId ?? "") == ExactKey(nodeId.string) else {
            return nil
        }
        guard let bytes = plaintext(try android.open(frame, from: sender, now: frame.envelope.sentAt)) else {
            return nil
        }
        let content = try MessageContent(decoding: bytes)
        if content.ctl == MessageContent.Control.groupKey, let seeds = content.gk, !seeds.keys.isEmpty {
            _ = sessions.adoptSeeds(seeds.keys, in: seeds.groupId, from: sender.nodeId, now: frame.envelope.sentAt)
        }
        return content
    }

    /// Opens `frame`, a group-form frame from `sender`, committing it: what it said, or the engine's typed refusal.
    func open(_ frame: Written, from sender: TestPeer) throws -> Result<MessageContent, GroupFormRefusal> {
        let envelope = frame.envelope
        let group = try #require(envelope.group?.id)
        let enc = try #require(try ChatContent(decoding: envelope.payload).enc)
        let aad = MessageCrypto.header(id: envelope.id, senderId: envelope.senderId, sentAt: envelope.sentAt, thread: group)
        let opening = try #require(GroupRatchetSessions.Frame(envelope: enc, aad: aad))
        let opened = sessions.open(opening, in: group, from: sender.nodeId, now: envelope.sentAt) { _ in () }
        switch opened {
        case .settled(.opened(let bytes, _)):
            return .success(try MessageContent(decoding: bytes))
        case .settled(.refused(let failure)):
            return .failure(GroupFormRefusal(failure: failure))
        default:
            Issue.record("the reader's own unit cannot fail")
            throw AndroidPeer.Refused()
        }
    }

    /// The body `frame` opens to, or `nil` when it does not open.
    func body(of frame: Written, from sender: TestPeer) -> String? {
        guard case .success(let content) = try? open(frame, from: sender) else {
            return nil
        }
        return content.body
    }
}

/// A group-form frame the reader could not open, and why.
struct GroupFormRefusal: Error, Equatable {
    let failure: GroupRatchetEngine.OpenOutcome.Failed
}

extension EngineFixture {
    /// Our group frames to `groupId`, each once, in the order written.
    func groupFrames(in groupId: String) -> [Written] {
        Self.once(transport.written(.chat)).filter { $0.envelope.group.map { ExactKey($0.id) } == ExactKey(groupId) }
    }

    /// What our DM-form chats to `android` say, as the phone reads them without committing, each once.
    func seeds(to android: AndroidPeer) -> [GroupKeyPayload] {
        controls(to: android).filter { $0.ctl == MessageContent.Control.groupKey }.compactMap(\.gk)
    }

    /// The `EncEnvelope` a frame of ours carries.
    static func sealed(_ frame: Written) throws -> EncEnvelope {
        try #require(try ChatContent(decoding: frame.envelope.payload).enc)
    }
}
