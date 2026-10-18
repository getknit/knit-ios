import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// One device in a two-facade test (`Side`, `RatchetSessionsResetTest.kt:37-90`): an identity, its signed prekeys by id,
/// and a real ``RatchetSessions`` over a memory store in a unit of its own. The first side of a pair holds its peer and the
/// second links back weakly, so a test that keeps the first keeps both, with no cycle to leak.
final class RatchetSessionSide {
    static let aad = Array("aad".utf8)
    static let resetBody = Array("reset".utf8)

    let identity: IdentityKeys
    var prekeys: [Int: SignedPrekey]
    let store: any RatchetStore
    let transactor: MemoryTransactor
    let sessions: RatchetSessions
    private var heldPeer: RatchetSessionSide?
    private weak var linkedPeer: RatchetSessionSide?

    /// A side over a fresh memory store, or over `refusing`, which fails what it is told to.
    init(engine: RatchetEngine = RatchetEngine(), refusing: RefusingRatchetStore? = nil) throws {
        identity = IdentityKeys.generate()
        prekeys = [1: try SignedPrekey.mint(id: 1, signedBy: identity, createdAt: 0)]
        let memory = MemoryRatchetStore()
        store = refusing ?? memory
        transactor = refusing?.transactor ?? MemoryTransactor(stores: [memory])
        sessions = RatchetSessions(identity: identity, store: store, transactor: transactor, engine: engine)
    }

    var nodeId: NodeId { identity.nodeId }

    var peer: RatchetSessionSide {
        guard let linked = heldPeer ?? linkedPeer else {
            preconditionFailure("pair() links both sides, and the test holds the first")
        }
        return linked
    }

    /// The peer's prekey `id`, verified against its bundle, as the profile pipeline pins it.
    func prekey(_ id: Int = 1) throws -> PeerPrekey {
        let held = try #require(peer.prekeys[id])
        return try #require(PeerPrekey(verifying: held.info, signedBy: peer.identity.bundle))
    }

    /// A DM to the peer, against its prekey `pkid`, which must seal.
    func seal(_ text: String, now: Int64, v3: Bool = false, pkid: Int = 1) throws -> EncEnvelope {
        let answer = sessions.sealDm(
            to: peer.identity.bundle, prekey: try prekey(pkid), plaintext: Array(text.utf8), aad: Self.aad, now: now, v3: v3)
        guard case .settled(.sealed(let envelope)) = answer else {
            Issue.record("expected a sealed DM, got \(answer)")
            throw Unexpected()
        }
        return envelope
    }

    /// A reset toward the peer, against its prekey `pkid`.
    func reset(now: Int64, cause: RatchetResetPolicy.Cause = .onDemand, pkid: Int = 1) throws -> RatchetSessions.ResetSealing {
        let answer = sessions.sealResetDm(
            to: peer.identity.bundle, prekey: try prekey(pkid), plaintext: Self.resetBody, aad: Self.aad, now: now, cause: cause)
        guard case .settled(let sealing) = answer else {
            Issue.record("expected a settled reset, got \(answer)")
            throw Unexpected()
        }
        return sealing
    }

    /// Opens `envelope` from the peer, committing it as the pipeline would.
    func open(_ envelope: EncEnvelope, now: Int64) throws -> RatchetSessions.Answer<RatchetSessions.Opening<Void>> {
        let frame = try #require(RatchetSessions.Frame(envelope: envelope, aad: Self.aad))
        return sessions.open(frame, from: peer.identity.bundle, now: now, prekeys: { [prekeys] in prekeys[$0] }, alongside: { _ in () })
    }

    var session: RatchetEngine.SessionState? {
        sessions.session(of: peer.nodeId)
    }

    /// What a backup restore leaves: every ratchet row for the peer gone, identity and prekeys intact.
    func wipe() {
        _ = sessions.forget(peer.nodeId)
    }

    struct Unexpected: Error {}
}

extension RatchetSessionSide {
    /// Two linked sides, the first over `refusing` when given.
    static func pair(
        engine: RatchetEngine = RatchetEngine(),
        refusing: RefusingRatchetStore? = nil
    ) throws -> (RatchetSessionSide, RatchetSessionSide) {
        let one = try RatchetSessionSide(engine: engine, refusing: refusing)
        let two = try RatchetSessionSide(engine: engine)
        one.heldPeer = two
        two.linkedPeer = one
        return (one, two)
    }
}

/// The plaintext an open answered settled, or `nil`.
func plaintext(_ answer: RatchetSessions.Answer<RatchetSessions.Opening<Void>>) -> [UInt8]? {
    guard case .settled(.opened(let plaintext, _)) = answer else {
        return nil
    }
    return plaintext
}

/// The envelope a reset sealed, or a failed expectation.
func sealedReset(
    _ sealing: RatchetSessions.ResetSealing,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> (envelope: EncEnvelope, reRooted: Bool) {
    guard case .sealed(let envelope, let plan) = sealing else {
        Issue.record("expected a sealed reset, got \(sealing)", sourceLocation: sourceLocation)
        throw RatchetSessionSide.Unexpected()
    }
    return (envelope, plan.action == .reRoot)
}

/// Whether a reset was declined.
func isDeclined(_ sealing: RatchetSessions.ResetSealing) -> Bool {
    guard case .declined = sealing else {
        return false
    }
    return true
}
