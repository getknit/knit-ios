import KnitCrypto
public import KnitWire

/// The link's proof of the node id its HELLO claims (the `link-hello-proof` contract; `LinkHandshake.kt` and
/// `LinkClaims.kt` in knit-next, ADR 2026-11.264w; knit-ios #25).
///
/// When both HELLOs carry ``Capabilities/linkProof``, the responder writes its reply and its PROOF in one write, and the
/// dialer, once that PROOF verifies, writes its own. Each side signs both HELLO payloads as they crossed, nonces included
/// (``LinkProof``), so a proof holds for this link alone. A side registers the peer, and the engine hears `.up`, only once
/// the peer's PROOF verified: nothing that keys on the peer's id runs before. A peer whose HELLO lacks the bit (Android
/// v2.10.1 and earlier) links unproven, as before, unless its id is one that proves itself (R1).
///
/// The proof binds the id to the key that signed this link's two HELLOs. It does not bind the radio channel: a link a
/// third node relays end to end still proves, which only a key derived from the handshake and a MAC on every record would
/// stop (contract §10).
extension LinkManager {
    /// knit-peer's impostor, a trial's switch the app never sets: what a build from before the proof, or a node claiming
    /// another's id, puts on the wire, so that a phone's refusals can be watched on air (the contract's T4 and T5).
    public struct Impostor: Sendable, Equatable {
        /// A link manager shaped like Android v2.10.1's: no ``Capabilities/linkProof`` and no nonce in our HELLO, no PROOF
        /// written, and no claim refused or closed on our side.
        public var legacy: Bool
        /// The id our HELLO names instead of ours. With ``legacy`` it is an unsigned claim; without it our PROOF signs the
        /// link with our own key, whose id is not this one, so a peer that checks finds the keys name another node.
        public var claimedId: NodeId?
        /// A peer we dial whatever the order, once promotion would: a phone that sights the peer it is told about refuses a
        /// cross-dial, and an impostor only dials by its own rule otherwise.
        public var dials: NodeId?

        /// Honest: proves itself, claims its own id, and dials by the rule.
        public init(legacy: Bool = false, claimedId: NodeId? = nil, dials: NodeId? = nil) {
            self.legacy = legacy
            self.claimedId = claimedId
            self.dials = dials
        }
    }

    /// What the proof's rules make of a HELLO claiming an id.
    enum ClaimVerdict: Equatable {
        /// Both sides carry the bit: the link must prove the id before it registers.
        case proves
        /// The HELLO lacks the bit, and the id need not prove itself: the link registers unproven, as before.
        case legacy
        /// The HELLO lacks the bit and claims an id that proves itself (R1).
        case refused
        /// The HELLO carries the bit without a valid nonce: a failed proof.
        case failed(String)
    }

    /// Links registered as proven (`linksProven`, the name both platforms report).
    public var linksProven: Int { claims.linksProven }
    /// Failed proofs (`linkProofFailed`): a missing, malformed, misplaced or wrong PROOF, or a HELLO carrying the bit with
    /// no nonce. The side that found it counts it.
    public var linkProofFailed: Int { claims.linkProofFailed }
    /// Unproven claims refused because the id proves itself, and live unproven links closed when the id proved itself or
    /// its profile gained the bit (`linkClaimRefused`).
    public var linkClaimRefused: Int { claims.linkClaimRefused }

    /// Whether this manager runs the proof: always, but for knit-peer's legacy impostor.
    var provesLinks: Bool { !impostor.legacy }

    // MARK: MeshTransport

    /// `peer`'s signed profile now carries ``Capabilities/linkProof``: every live link claiming it unproven goes at once,
    /// out of ``neighbors`` and every send's targets before the engine sends on (R4). Their `.down` events lead whatever the
    /// next entry answers, so they come before a proven link's `.up` under the same id.
    public func peerProvesItself(_ peer: NodeId) {
        guard provesLinks else {
            return
        }
        let now = clock.monotonicMilliseconds()
        for channel in liveLinks.filter({ $0.neighbor.nodeId == peer && !$0.proven }).map(\.channel) {
            log.log(.info, "link \(channel) closed: \(peer) proves itself")
            claims.claimRefused()
            deferredDowns += retire(channel, backingOff: false, now: now)
        }
    }

    /// The links ``peerProvesItself(_:)`` closed, once: ahead of anything an entry answers.
    func takeDeferredDowns() -> [Event] {
        defer { deferredDowns.removeAll() }
        return deferredDowns
    }

    // MARK: The exchange

    /// What the proof's rules make of `hello`, which claims `peer`. Run before any of today's admission rules (R1 first).
    func judgeClaim(_ hello: Hello, claiming peer: NodeId) -> ClaimVerdict {
        guard provesLinks else {
            return .legacy
        }
        if hello.capabilities.contains(.linkProof) {
            return hello.nonce == nil ? .failed("nonce") : .proves
        }
        // A live proven link is a proof this run too, whether or not the bounded set still remembers it (contract §7).
        let provenLink = liveLinks.contains { $0.neighbor.nodeId == peer && $0.proven }
        return claims.isProofCapable(peer) || provenLink ? .refused : .legacy
    }

    /// The reply to our dial, `payload` as it crossed, already checked to name `peer`. A reply with the bit makes its PROOF
    /// the next record; one without links unproven, unless the id proves itself.
    func answered(_ id: ChannelID, hello: Hello, payload: [UInt8], peer: NodeId, now: Int64) -> [Event] {
        switch judgeClaim(hello, claiming: peer) {
        case .failed(let why):
            proofFailed(on: id, for: peer, why: why)
            return retire(id, backingOff: true, now: now) + promote(now: now)
        case .refused:
            refuseClaim(peer)
            return retire(id, backingOff: true, now: now) + promote(now: now)
        case .legacy:
            return register(id, Claim(peer: peer, hello: hello, sighted: true), proven: false, now: now)
        case .proves:
            // `connected` wrote our HELLO before any reply could come, so the channel holds it.
            if let ours = channels[id]?.wroteHello {
                let claim = Claim(peer: peer, hello: hello, sighted: true)
                awaitProof(on: id, PendingProof(claim: claim, dialerHello: ours, responderHello: payload, displacing: nil), now: now)
            }
            return []
        }
    }

    /// Answers a dialer that proves itself with `pending.responderHello`, a reply made for this connection, and our PROOF,
    /// in one write, then writes nothing until its PROOF verifies.
    func answerWithProof(_ id: ChannelID, _ pending: PendingProof, now: Int64) -> [Event] {
        channels[id]?.wroteHello = pending.responderHello
        guard let proof = signedProof(as: .responder, dialerHello: pending.dialerHello, responderHello: pending.responderHello),
            let helloRecord = LinkRecord(.hello, payload: pending.responderHello).encoded
        else {
            proofFailed(on: id, for: pending.peer, why: "unsigned")
            return retire(id, backingOff: false, now: now)
        }
        // One write, so the dialer reads our PROOF straight behind the reply (contract §5, step 2).
        write(helloRecord + proof, on: id)
        awaitProof(on: id, pending, now: now)
        return []
    }

    /// Our PROOF record as `signer`, or `nil` when the key would not sign. Signed once per link: each signature differs.
    func signedProof(as signer: LinkProof.Role, dialerHello: [UInt8], responderHello: [UInt8]) -> [UInt8]? {
        signProof(signer, dialerHello, responderHello).flatMap { LinkRecord(.proof, payload: $0).encoded }
    }

    /// Waits for the peer's PROOF: one more stage of the handshake, with its own deadline and its own put-off.
    func awaitProof(on id: ChannelID, _ pending: PendingProof, now: Int64) {
        channels[id]?.stage = .awaitingProof(pending)
        channels[id]?.deadline = now + configuration.helloTimeoutMilliseconds
        channels[id]?.putOff = false
    }

    /// The record where the peer's PROOF belongs. A dialer writes its own PROOF once the responder's verifies; either side
    /// then registers the peer as proven. Anything else there fails the proof and closes the link, backing off a dialer.
    func handleProof(_ record: LinkRecord, _ pending: PendingProof, on id: ChannelID, role: Role, now: Int64) -> [Event] {
        let dialed = role != .responder
        let failure =
            Self.proofFailure(record, pending, signer: dialed ? .responder : .dialer)
            ?? (dialed ? writeProof(as: .dialer, pending, on: id) : nil)
        if let failure {
            proofFailed(on: id, for: pending.peer, why: failure)
            return retire(id, backingOff: dialed, now: now) + (dialed ? promote(now: now) : [])
        }
        return proved(id, pending, now: now)
    }

    /// Why `record` is not the PROOF of `pending.peer` as `signer`, or `nil` when it is. Never the keys or the signature.
    static func proofFailure(_ record: LinkRecord, _ pending: PendingProof, signer: LinkProof.Role) -> String? {
        guard record.tag == .proof else {
            return "record"
        }
        let outcome = LinkProof.verify(
            record.payload,
            claimedId: pending.peer,
            signer: signer,
            dialerHello: pending.dialerHello,
            responderHello: pending.responderHello
        )
        switch outcome {
        case .proven:
            return nil
        case .failed(let failure):
            return failure.rawValue
        }
    }

    /// Writes our PROOF as `signer` on `id`, or answers why not.
    func writeProof(as signer: LinkProof.Role, _ pending: PendingProof, on id: ChannelID) -> String? {
        guard let proof = signedProof(as: signer, dialerHello: pending.dialerHello, responderHello: pending.responderHello) else {
            return "unsigned"
        }
        write(proof, on: id)
        return nil
    }

    /// The peer proved `pending.peer` on `id`. The link it replaces (R2) or displaces (R3) goes first, then any other live
    /// unproven link claiming the id (R3, R4), so their `.down` events come before this `.up`, and the engine runs the real
    /// peer's link-up afresh.
    func proved(_ id: ChannelID, _ pending: PendingProof, now: Int64) -> [Event] {
        let peer = pending.peer
        var events: [Event] = []
        let replaced = pending.displacing.flatMap { held in liveLinks.first { $0.channel == held && $0.proven } }
        if let held = replaced?.channel, replaced?.neighbor.nodeId == peer {
            // The line the harness reads for a replacement (`IOS_CHANNEL_ENDINGS`), byte for byte.
            log.log(.info, "link \(peer) replaced its stale link \(held) with \(id)")
            events += retire(held, backingOff: false, now: now)
        }
        for channel in liveLinks.filter({ $0.neighbor.nodeId == peer && !$0.proven }).map(\.channel) {
            log.log(.info, "link \(channel) displaced: \(peer) proved itself on \(id)")
            claims.claimRefused()
            events += retire(channel, backingOff: false, now: now)
        }
        return events + register(id, pending.claim, proven: true, now: now)
    }

    /// Counts and logs a failed proof on `id` for the id its HELLO claimed. The caller closes the link.
    func proofFailed(on id: ChannelID, for peer: NodeId, why: String) {
        claims.proofFailed()
        log.log(.info, "link \(id) proof failed for \(peer): \(why)")
    }

    /// Counts and logs an unproven claim to `peer`, an id that proves itself (R1). The caller closes the link.
    func refuseClaim(_ peer: NodeId) {
        claims.claimRefused()
        log.log(.info, "link refused \(peer): an unproven claim to a node that proves itself")
    }

    /// The ids that dialed us and are proving themselves now.
    var provingDialers: [NodeId] {
        channels.values.compactMap { channel in
            guard channel.role == .responder, case .awaitingProof(let pending) = channel.stage else {
                return nil
            }
            return pending.peer
        }
    }

    /// Whether `channel` waits for the PROOF of `peer`.
    static func awaitsProof(of peer: NodeId, _ channel: Channel) -> Bool {
        if case .awaitingProof(let pending) = channel.stage {
            return pending.peer == peer
        }
        return false
    }
}
