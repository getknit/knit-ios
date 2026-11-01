import KnitWire

/// A channel's role and stage, and the registered link it becomes: the handshake's state, apart from the manager's body.
extension LinkManager {
    enum Role: Equatable {
        /// We dialed, expecting this peer to answer.
        case dialer(NodeId)
        /// The peer dialed us.
        case responder
    }

    enum Stage: Equatable {
        /// A dial not yet open.
        case connecting
        /// Open, waiting for the other side's HELLO.
        case awaitingHello
        /// Both HELLOs carry ``Capabilities/linkProof``, and the peer's PROOF must be the next record (the
        /// `link-hello-proof` contract, §5). Nothing is written on the channel and nothing about the peer is registered
        /// until it verifies.
        case awaitingProof(PendingProof)
        /// Registered to this peer: frames flow.
        case live(NodeId)
    }

    /// Who a HELLO said the peer is: what registering the link needs.
    struct Claim: Equatable {
        /// The id the peer's HELLO claimed.
        let peer: NodeId
        /// The peer's HELLO, parsed.
        let hello: Hello
        /// Whether the peer was sighted when its HELLO came, for the link it becomes; a peer we dial always was.
        let sighted: Bool
    }

    /// What a channel awaiting its peer's PROOF needs to verify it and register the link.
    struct PendingProof: Equatable {
        /// Who the peer's HELLO claims to be: the id its PROOF's keys must hash to.
        let claim: Claim
        /// Both HELLO payloads exactly as they crossed the link, which each side's transcript signs.
        let dialerHello: [UInt8]
        let responderHello: [UInt8]
        /// On a responder, the live link claiming the same id that the proof replaces once it verifies (R2, R3), and keeps
        /// if it fails.
        let displacing: ChannelID?

        /// The id the peer's HELLO claimed.
        var peer: NodeId { claim.peer }
    }

    /// A registered link.
    struct LiveLink {
        let channel: ChannelID
        let neighbor: Neighbor
        let since: Int64
        /// Whether the peer was sighted since the link came up; a dialer we dial always has.
        var sighted: Bool
        /// Whether the peer has been heard through service data while linked, or was when the link came up: an advert
        /// with a digest cue. A GATT payload carries none, by ADR 2026-09.xzpt's shared law, so a peer only ever heard
        /// that way, or never heard, looks like an iPhone (``isExemptFromStallClose(_:)``). Sticky for the link.
        var heardServiceData = false
        /// Whether the peer proved the id its HELLO claimed on this link (contract §5). Only a proven link replaces a
        /// proven one (R2), and a proven link displaces any unproven one claiming its id (R3).
        var proven = false
    }

    struct Channel {
        let role: Role
        var stage: Stage
        var reader = LinkRecordReader()
        /// What the channel carried lately, for the warning if a record fails to parse.
        var trace = LinkTrace()
        /// When the dial, the HELLO or the PROOF times out.
        var deadline: Int64?
        /// Whether that deadline was put off once already, having passed while iOS had the app suspended. Reset when the
        /// channel enters a stage, so each stage of the handshake may be put off once.
        var putOff = false
        /// Our HELLO's payload as we wrote it on this channel, which the transcript signs.
        var wroteHello: [UInt8]?
    }
}
