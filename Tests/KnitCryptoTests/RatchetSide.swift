import Foundation
import KnitWire
import Testing

@testable import KnitCrypto

/// A sealed DM frame as the engine tests pass it around: the header, the carried nonce (`nil` for v3) and the
/// ciphertext (`Frame`, `RatchetEngineTest.kt:22-27`).
struct RatchetFrame {
    let header: RatchetHeader
    let nonce: [UInt8]?
    let ct: [UInt8]
}

/// One device in a two-party engine test (`Side`, `RatchetEngineTest.kt:29-140`): an identity, a signed prekey, and the
/// rows the session layer will own, applied with `RatchetRepository`'s rules (``RatchetRows``). The first side of a pair
/// holds its peer and the second links back weakly, so a test that keeps the first keeps both, with no cycle to leak.
final class RatchetSide {
    static let aad = Array("id|sender|1700000000000|thread".utf8)

    let nodeId: NodeId
    let identity: IdentityKeys
    let prekey: SignedPrekey
    let engine: RatchetEngine
    /// Whether an init naming our prekey finds its private half; `false` plays a prekey pruned since.
    var prekeyResolvable = true
    var rows = RatchetRows()
    private var heldPeer: RatchetSide?
    private weak var linkedPeer: RatchetSide?
    private(set) var lastDelta: RatchetEngine.OpenDelta?

    init(_ nodeId: NodeId, engine: RatchetEngine = RatchetEngine()) throws {
        self.nodeId = nodeId
        identity = IdentityKeys.generate()
        prekey = try SignedPrekey.mint(id: 1, signedBy: identity, createdAt: RatchetEngineTests.now)
        self.engine = engine
    }

    var session: RatchetEngine.SessionState? {
        get { rows.session }
        set { rows.session = newValue }
    }

    /// The epoch numbers we hold a receive chain for, whatever root derived them.
    var recvNumbers: Set<Int> { Set(rows.chains.keys.map(\.epoch)) }

    var other: RatchetSide {
        guard let peer = heldPeer ?? linkedPeer else {
            preconditionFailure("pair() links both sides, and the test holds the first")
        }
        return peer
    }

    /// Talks to `peer`, keeping it alive.
    func hold(_ peer: RatchetSide) {
        heldPeer = peer
    }

    /// The peer's prekey, verified against its bundle, as the profile pipeline pins it.
    var peerPrekey: PeerPrekey {
        guard let verified = PeerPrekey(verifying: other.prekey.info, signedBy: other.identity.bundle) else {
            preconditionFailure("a minted prekey verifies against its own identity")
        }
        return verified
    }

    func initiate(now: Int64) throws {
        let initiation = try engine.initiate(
            peerId: other.nodeId,
            identity: identity,
            peerIdentity: other.identity.bundle,
            peerPrekey: peerPrekey,
            now: now
        )
        rows.commitSend(initiation.session, newLocalEpoch: initiation.epoch)
    }

    func seal(_ plain: String, now: Int64, force: Bool = false, v3: Bool = false) throws -> RatchetFrame {
        let state = try #require(session)
        let sealed = try engine.seal(
            state,
            plaintext: Array(plain.utf8),
            aad: Self.aad,
            peerPrekey: peerPrekey,
            now: now,
            forceNewEpoch: force,
            v3: v3
        )
        let result = try #require(sealed)
        rows.commitSend(result.session, newLocalEpoch: result.newLocalEpoch)
        return RatchetFrame(header: result.header, nonce: result.nonce, ct: result.ct)
    }

    func open(
        _ frame: RatchetFrame,
        now: Int64,
        resetRequested: Bool = false,
        allowReplacement: Bool = true,
        allowEraChange: Bool = true
    ) throws -> RatchetEngine.OpenOutcome {
        let header = frame.header
        let context = RatchetEngine.OpenContext(
            selfNodeId: nodeId,
            peerId: other.nodeId,
            session: session,
            recvEpochs: rows.chains(for: header),
            skippedKeys: rows.skippedKeys(for: header),
            ownBasePrivateKey: rows.ownBasePrivateKey(for: header),
            identity: identity,
            peerIdentity: other.identity.bundle,
            prekeyForInit: header.initial.flatMap { initial in prekeyResolvable && initial.pkid == prekey.id ? prekey : nil },
            allowReplacement: allowReplacement,
            resetRequested: resetRequested,
            allowEraChange: allowEraChange
        )
        let outcome = try engine.open(context, header: header, nonce: frame.nonce, ct: frame.ct, aad: Self.aad, now: now)
        if let opened = outcome.opened {
            lastDelta = opened.delta
            rows.apply(opened.delta, se: header.se, n: header.n)
        }
        return outcome
    }

    /// A reset of ours, minted as `RatchetSessions.reRoot` mints one: a fresh initiation that keeps the old root draining
    /// as `prevRoot`, our receive state purged, and our numbering restarted at 1, its epoch replacing the dead era's key
    /// of that number (knit-next ADR 027). The peer opens it with `resetRequested`; what we seal after it carries the
    /// same init, unflagged.
    func reset(now: Int64) throws -> RatchetFrame {
        let old = session
        let initiation = try engine.initiate(
            peerId: other.nodeId,
            identity: identity,
            peerIdentity: other.identity.bundle,
            peerPrekey: peerPrekey,
            now: now
        )
        var state = initiation.session
        state.prevRoot = old?.root
        state.prevRootWeAreInitiator = old?.weAreInitiator ?? false
        state.prevRootExpiresAt = old == nil ? 0 : now + RatchetEngine.previousRootMilliseconds
        state.lastResetSentAt = now
        rows.commitSend(state, newLocalEpoch: initiation.epoch)
        rows.purgeReceiveState()
        return try seal("reset", now: now)
    }

    /// A wipe: every ratchet row gone, the identity and its prekeys kept.
    func wipe() {
        rows = RatchetRows()
    }
}

extension RatchetSide {
    /// Two linked sides; the first sorts before the second, as Kotlin's `aaaaaaaa` and `bbbbbbbb` do.
    static func pair(
        _ first: Character = "a",
        _ second: Character = "b",
        engine: RatchetEngine = RatchetEngine()
    ) throws -> (RatchetSide, RatchetSide) {
        let one = try RatchetSide(.repeating(first), engine: engine)
        let two = try RatchetSide(.repeating(second), engine: engine)
        one.hold(two)
        two.linkedPeer = one
        return (one, two)
    }
}

/// The plaintext an opened outcome carries, as text, or a failed expectation.
func text(_ outcome: RatchetEngine.OpenOutcome, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
    let opened = try #require(outcome.opened, "expected the frame to open, got \(outcome.vectorName)", sourceLocation: sourceLocation)
    return try #require(String(bytes: opened.plaintext, encoding: .utf8), sourceLocation: sourceLocation)
}
