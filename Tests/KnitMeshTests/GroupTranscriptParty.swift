import KnitCrypto
import KnitStore
import KnitStoreSQL
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// One party of a group transcript, as A9's `TranscriptParty` is (`RatchetTranscript.kt:241-288` on the A9 branch): a
/// fixed identity, the prekeys it holds, the prekeys it pins for its peers, and both session layers, ``RatchetSessions``
/// and ``GroupRatchetSessions``, over stores of one kind under one unit, their engines drawing from the party's one plan.
/// A restore drops both layers' stores and their floors and keeps the identity, the prekeys and the plan.
final class GroupTranscriptParty {
    let name: String
    let identity: IdentityKeys
    /// The prekeys it holds, by id.
    let holds: [Int: SignedPrekey]
    /// The prekey it pins for each peer, by peer name, with the prekey's name.
    let pins: [String: (name: String, prekey: PeerPrekey)]
    let draws: VectorDraws
    private let kind: GroupSessionKind
    private(set) var dmStore: any RatchetStore
    private(set) var groupStore: any GroupRatchetStore
    private(set) var transactor: any StoreTransactor
    private(set) var dm: RatchetSessions
    private(set) var group: GroupRatchetSessions

    var nodeId: NodeId { identity.nodeId }

    init(_ name: String, in transcript: RatchetVectors.GroupTranscript, kind: GroupSessionKind) throws {
        let entry = try #require(transcript.parties[name])
        self.name = name
        identity = try RatchetVectorReplay.identity(entry.identity)
        #expect(identity.nodeId.string == entry.nodeId)
        var held: [Int: SignedPrekey] = [:]
        for prekeyName in entry.holdsPrekeys {
            let (pair, info) = try RatchetVectorReplay.prekey(prekeyName)
            held[info.id] = try SignedPrekey.mint(id: info.id, signedBy: identity, createdAt: 0) { pair }
        }
        holds = held
        var pinned: [String: (name: String, prekey: PeerPrekey)] = [:]
        for (peer, prekeyName) in entry.pins {
            let owner = try #require(RatchetVectorReplay.file.profiles.prekeys.first { $0.name == prekeyName }).owner
            let (_, info) = try RatchetVectorReplay.prekey(prekeyName)
            pinned[peer] = (prekeyName, try #require(PeerPrekey(verifying: info, signedBy: try RatchetVectorReplay.identity(owner).bundle)))
        }
        pins = pinned
        draws = VectorDraws(owner: name, plan: transcript.draws[name] ?? [])
        self.kind = kind
        let made = try Stores(kind)
        (dmStore, groupStore, transactor) = (made.dm, made.group, made.transactor)
        dm = RatchetSessions(identity: identity, store: dmStore, transactor: transactor, engine: draws.engine)
        group = GroupRatchetSessions(nodeId: identity.nodeId, store: groupStore, transactor: transactor, engine: draws.groupEngine)
    }

    /// A backup restore onto this party (`TranscriptParty.wipe`, `RatchetTranscript.kt:274-285`): every ratchet row and
    /// floor gone, the identity, the prekeys and the draw plan kept.
    func restore() throws {
        let made = try Stores(kind)
        (dmStore, groupStore, transactor) = (made.dm, made.group, made.transactor)
        dm = RatchetSessions(identity: identity, store: dmStore, transactor: transactor, engine: draws.engine)
        group = GroupRatchetSessions(nodeId: identity.nodeId, store: groupStore, transactor: transactor, engine: draws.groupEngine)
    }

    /// Both ratchets' stores of one kind under one unit: memory stores under one ``MemoryTransactor``, or the SQL stores
    /// on one database in memory, which is their unit.
    private struct Stores {
        let dm: any RatchetStore
        let group: any GroupRatchetStore
        let transactor: any StoreTransactor

        init(_ kind: GroupSessionKind) throws {
            switch kind {
            case .memory:
                let memoryDM = MemoryRatchetStore()
                let memoryGroup = MemoryGroupRatchetStore()
                (dm, group, transactor) = (memoryDM, memoryGroup, MemoryTransactor(stores: [memoryDM, memoryGroup]))
            case .sql:
                let database = try KnitDatabase.inMemory { error in Issue.record("the database failed: \(error)") }
                (dm, group, transactor) = (SQLRatchetStore(database), SQLGroupRatchetStore(database), database)
            }
        }
    }
}
