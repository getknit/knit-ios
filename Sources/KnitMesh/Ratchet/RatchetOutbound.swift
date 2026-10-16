import KnitCrypto
import KnitStore
import KnitWire

/// The DM ratchet's send rules above the engine, pure (`sealEnvelopeFor`, `ratchetPrekeyOf` and `resealRecentDmsTo` in
/// knit-next's `MeshManager.kt`, at `cbf2a487`, `:1267-1308`, `:1851-1856` and `:3361-3371`): which scheme one of our DMs
/// takes toward a peer, and which of our DMs a peer's reset has us seal again. ``MeshEngine``'s send arm applies them
/// (ADR 2026-10.5sk9, phase P5b).
internal enum RatchetOutbound {
    /// How far back a peer's reset has us seal our unacked DMs again: custody's day, past which no copy of ours is left on
    /// the mesh to recover (`RESEAL_WINDOW_MS`, `MeshManager.kt:3481`).
    static let resealMilliseconds: Int64 = 86_400_000

    /// How one of our DMs to a peer is sealed (`sealEnvelopeFor`, `MeshManager.kt:1287-1308`).
    enum Scheme: Equatable {
        /// No bundle is pinned for the peer, so nobody can open it yet: it waits as `pendingKey`, and only for that.
        case waiting
        /// v1, to the pinned bundle: the switch is off, or the peer's pinned profile does not carry `CAP_RATCHET`.
        case staticKeys(PublicKeyBundle)
        /// The ratchet, to the pinned bundle. A seal the facade cannot make, or a key X25519 refuses, goes v1 instead.
        case ratchet(Ratcheted)
    }

    /// What a ratchet seal toward one peer takes: its pinned bundle, the prekey pinned for it if a valid one is, and the
    /// plaintext laid out for the scheme its pinned profile reads.
    struct Ratcheted: Equatable {
        /// The peer's pinned bundle, whose node id keys the session.
        let bundle: PublicKeyBundle
        /// The verified prekey pinned for the peer, or `nil`: a session held still seals without one, and none starts.
        let prekey: PeerPrekey?
        /// The plaintext, compact for v3 or named for v2 (`MessageContent.sealBytes`).
        let bytes: SealBytes

        /// Whether the plaintext is laid out for v3.
        var v3: Bool { bytes.scheme == EncEnvelope.Version.compactRatchet }
    }

    /// The scheme `content` takes toward `peer`, the row pinned for it (`nil` for none), with the switch at `ratchet`.
    ///
    /// The switch comes first: off, nothing takes the ratchet, whatever the peer advertises (ADR 2026-10.5sk9). On, a DM
    /// takes the ratchet when the peer's pinned profile carries `CAP_RATCHET` and a bundle is pinned, read from the pinned
    /// profile alone (`CryptoScheme.kt:11-13`). A DM waits only for a bundle: a peer that claims the bit with no usable
    /// prekey still takes the ratchet here, and the facade's answer, no session and no prekey, sends it v1 at once,
    /// counted, and never upgrades it (`MeshManager.kt:1294-1301`). The plaintext is compact under v3 only when the
    /// profile also carries `CAP_CRYPTO_V3` and the content has a canonical compact form, else the named v2 layout
    /// (`MessageContentV2.kt:265-274`).
    static func scheme(for content: MessageContent, to peer: PeerRecord?, ratchet: Bool) -> Scheme {
        guard let peer, let bundle = PublicKeyBundle(encoded: peer.publicKey) else {
            return .waiting
        }
        guard ratchet, Capabilities(rawValue: peer.capabilities ?? 0).contains(.ratchet) else {
            return .staticKeys(bundle)
        }
        // The pin was verified as it was taken; one that would not verify now counts as none (`ratchetPrekeyOf`, `:1851-1856`).
        let prekey = peer.prekey.flatMap { PeerPrekey(verifying: $0, signedBy: bundle) }
        let bytes = content.sealBytes(v3: CryptoScheme.readsCryptoV3(peer.capabilities))
        return .ratchet(Ratcheted(bundle: bundle, prekey: prekey, bytes: bytes))
    }

    /// Whether `message` is one of our DMs, from `me`, that a reset from `peer` has us seal again: an ordinary message to
    /// that peer, sent no earlier than `since`, never acknowledged, and not still waiting for a key, which goes out by
    /// itself once one pins (`unackedDmsTo`, `MessageDao.kt:179-187`).
    static func isUnacknowledged(_ message: MessageRecord, to peer: NodeId, from me: NodeId, since: Int64) -> Bool {
        message.senderId == me && message.recipientId == peer && message.kind == .message && !message.delivered
            && !message.pendingKey && message.sentAt >= since
    }
}

/// How our DMs were sealed so far, under the names of Android's metrics (`MeshMetrics.Seals`, `MeshMetrics.kt:1476-1482`,
/// at `cbf2a487`). A v3 seal is a ratchet seal too, so it counts in both, as Android's does (`MeshManager.kt:1296-1298`).
public struct RatchetSealCounts: Sendable, Equatable {
    /// DMs sealed with the ratchet, v2 and v3 alike (`dmSealedV2`).
    public internal(set) var dmSealedV2 = 0
    /// Of those, the ones sealed in the compact v3 form (`dmSealedV3`).
    public internal(set) var dmSealedV3 = 0
    /// DMs to a peer whose pinned profile carries `CAP_RATCHET` that went v1 instead (`dmSealedV1Fallback`): no session
    /// and no usable prekey, a new epoch due with no base, or a key X25519 refuses. A persistent count is worth a look.
    public internal(set) var dmSealedV1Fallback = 0

    /// Counts as stated, each zero unless given: nothing sealed yet.
    public init(dmSealedV2: Int = 0, dmSealedV3: Int = 0, dmSealedV1Fallback: Int = 0) {
        self.dmSealedV2 = dmSealedV2
        self.dmSealedV3 = dmSealedV3
        self.dmSealedV1Fallback = dmSealedV1Fallback
    }
}
