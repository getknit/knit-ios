import KnitWire

/// Who must prove the node id its link HELLO claims, and how the proofs and claims went (the `link-hello-proof`
/// contract, §7 and §9; `LinkClaims.kt` in knit-next, ADR 2026-11.264w; knit-ios #25). Pure: the store's answer comes in
/// through ``profileCarriesProof``, and ``LinkManager`` acts on what this says.
///
/// An id is **proof-capable** when its stored profile carries ``Capabilities/linkProof`` (the profile is signed by its
/// author, so nobody else can strip the bit), or when a link proved it since the app started. A link claiming a
/// proof-capable id must prove it, and every live link that claims one unproven goes.
internal struct LinkClaims {
    /// How many ids proven this run are remembered, the least recently proven forgotten first: 4,096, Android's
    /// `LinkClaims.MAX_PROVEN`, with its order (a repeat proof makes an id the newest, and a lookup moves nothing). A peer
    /// whose profile we hold needs none of them, since its profile carries the bit; this bounds the rest under a churn of
    /// fresh identities. Forgetting one costs nothing a live link holds: a live proven link makes its id proof-capable on
    /// its own (``LinkManager/judgeClaim(_:claiming:)``).
    static let maxProven = 4096

    /// Whether the stored profile for an id carries ``Capabilities/linkProof``. A store read that fails answers `false`
    /// (`SQLPeerStore.peer` answers `nil`), so a claim to that id is taken unproven, as before the proof, until it reads.
    let profileCarriesProof: (NodeId) -> Bool
    /// Each id proven this run, and when, in ``stamp``'s order.
    private var proven: [NodeId: UInt64] = [:]
    private var stamp: UInt64 = 0

    /// Links registered as proven.
    private(set) var linksProven = 0
    /// Failed proofs: a missing, malformed, misplaced or wrong PROOF, or a HELLO carrying the bit with no nonce.
    private(set) var linkProofFailed = 0
    /// Unproven claims to a proof-capable id refused (R1), and live unproven links closed for one (R3, R4).
    private(set) var linkClaimRefused = 0

    init(profileCarriesProof: @escaping (NodeId) -> Bool) {
        self.profileCarriesProof = profileCarriesProof
    }

    /// Whether a link claiming `id` must prove it (R1).
    func isProofCapable(_ id: NodeId) -> Bool {
        proven[id] != nil || profileCarriesProof(id)
    }

    /// A link proved `id` and registered: counts it, and keeps the id proof-capable for the rest of the run, as the newest.
    mutating func proved(_ id: NodeId) {
        linksProven += 1
        stamp += 1
        proven[id] = stamp
        if proven.count > Self.maxProven, let oldest = proven.min(by: { $0.value < $1.value })?.key {
            proven[oldest] = nil
        }
    }

    /// A proof failed.
    mutating func proofFailed() {
        linkProofFailed += 1
    }

    /// An unproven claim was refused, or a live unproven link closed for a proof-capable id.
    mutating func claimRefused() {
        linkClaimRefused += 1
    }
}
