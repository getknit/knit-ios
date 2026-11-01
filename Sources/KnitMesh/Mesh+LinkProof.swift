import KnitStore
import KnitWire

/// The link's proof of the id its HELLO claims, as the mesh sees it (the `link-hello-proof` contract; knit-ios #25).
extension Mesh {
    /// Links registered as proven (``LinkManager/linksProven``).
    public var linksProven: Int { links.linksProven }
    /// Failed link proofs (``LinkManager/linkProofFailed``).
    public var linkProofFailed: Int { links.linkProofFailed }
    /// Unproven claims refused, and unproven links closed, for ids that prove themselves (``LinkManager/linkClaimRefused``).
    public var linkClaimRefused: Int { links.linkClaimRefused }

    /// knit-peer's impostor as set (``setImpostor(_:)``).
    public var impostor: LinkManager.Impostor { links.impostor }

    /// Sets knit-peer's impostor (``LinkManager/Impostor``), a trial's switch the app never sets. It applies to the links
    /// that open from now on.
    public func setImpostor(_ impostor: LinkManager.Impostor) {
        links.impostor = impostor
        settle()
    }

    /// Whether the profile `peers` holds for an id carries ``Capabilities/linkProof``: what the link manager asks before it
    /// takes an unproven claim (contract §7). The engine writes a peer's capabilities only from a profile no older than the
    /// presentation it holds, so an older profile never takes the bit back. A read that fails answers no profile, so `false`.
    static func profileCarriesProof(in peers: any PeerStore) -> (NodeId) -> Bool {
        { node in
            peers.peer(node)?.capabilities.map { Capabilities(rawValue: $0).contains(.linkProof) } ?? false
        }
    }
}
