import KnitCrypto
import KnitStore
import KnitWire

// What a link's proof needs of the profiles (the `link-hello-proof` contract, knit-ios #25): a peer whose signed profile
// carries ``Capabilities/linkProof`` is one every link claiming its id must prove, so the bit must reach the transport,
// and no older profile may take it back, theirs or ours.
extension MeshEngine {
    // MARK: Our profile

    /// Publishes our profile again as an edit when the capabilities it would carry differ from those our last publish
    /// recorded, or none are recorded, at start (contract §7, knit-ios #25; `republishProfileIfCapabilitiesChanged` in
    /// knit-next). Capabilities change with the build or the ratchet's switch, never through an edit, and a peer writes
    /// our capabilities only from a profile no older than the presentation it holds of us. So without a new version a
    /// profile signed before an upgrade, re-served from custody for a day or replayed by anyone, would land at the same
    /// version and take a new bit such as ``Capabilities/linkProof`` back. With it, every profile from before is strictly
    /// older. A build put back to an older one republishes past the version this left, without the bit, which peers take.
    ///
    /// A profile at version 0 has never been edited, and an edit would flood its empty name at a version every peer takes
    /// (``syncPrekey(atStart:)``), so it is republished under a fresh stamp at version 0 instead, and its first edit, the
    /// onboarding's, outranks the frames from before. A profile the store cannot read now is left for the next start.
    ///
    /// Runs after the prekey's sync, which can change what the profile carries, and before the stale check, which keeps
    /// the version.
    func republishIfCapabilitiesChanged() {
        guard let own = stores.ownProfile.loadIfReadable() else {
            return
        }
        let carried = publishedCapabilities(of: own)
        guard own.capabilities != carried else {
            return
        }
        log.log(.info, "mesh republished our profile: its capabilities are now \(carried.hex)")
        guard own.version != 0 else {
            republish(own, now: clock.wallMilliseconds())
            return
        }
        publishEdit(of: own) { _ in
            // Nothing presented changes: the version, the stamp and the capabilities move.
        }
    }

    /// The capabilities our signed profile carries for `own` (``currentProfileEnvelope()``): the switch's set beside the
    /// prekey `own` names, while the switch is on and the ring still keeps it; otherwise ``Capabilities/local`` without the
    /// ratchet's three bits. What the build draws rides either way (``MeshConfiguration/drawnCapabilities``).
    func publishedCapabilities(of own: OwnProfile) -> Capabilities {
        publishedPrekey(of: own) == nil
            ? Capabilities.local.subtracting(.ratchetSuite).union(configuration.drawnCapabilities) : configuration.capabilities
    }

    /// The prekey our signed profile carries for `own`: the one it names, with the switch on and the ring still keeping it.
    func publishedPrekey(of own: OwnProfile) -> SignedPrekey? {
        configuration.ratchet ? own.prekeyId.flatMap { prekeyRing?.prekey(id: $0) } : nil
    }

    /// Saves `own`, a publish under a new stamp, with the capabilities that publish carries, which the next start compares.
    func savePublished(_ own: OwnProfile) {
        var own = own
        own.capabilities = publishedCapabilities(of: own)
        stores.ownProfile.save(own)
    }

    // MARK: Their profiles

    /// Writes `record`, the row a cleartext profile leaves its sender with, over `before`, and tells the transport when it
    /// gained ``Capabilities/linkProof``: the bit came under the peer's own signature, so a link claiming the id must prove
    /// it from now on, and the links that claim it unproven go (contract R4; `LinkClaims.profileCapabilities` in
    /// knit-next). A row that keeps the bit, or lacks it, tells nothing.
    func writeProfileRow(_ record: PeerRecord, was before: PeerRecord?) {
        stores.peers.upsert(record)
        if Self.carriesLinkProof(record.capabilities), !Self.carriesLinkProof(before?.capabilities) {
            transport.peerProvesItself(record.nodeId)
        }
    }

    /// Whether a row's capabilities carry ``Capabilities/linkProof``; none recorded carries nothing.
    private static func carriesLinkProof(_ capabilities: Int64?) -> Bool {
        capabilities.map { Capabilities(rawValue: $0).contains(.linkProof) } ?? false
    }
}
