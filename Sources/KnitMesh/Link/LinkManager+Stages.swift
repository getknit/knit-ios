import KnitCrypto
import KnitWire

/// A channel's role and stage, and the registered link it becomes: the handshake's state, apart from the manager's body.
extension LinkManager {
    enum Role: Equatable {
        /// We dialed this target.
        case dialer(DialTarget)
        /// The peer dialed us.
        case responder
    }

    enum Stage: Equatable {
        /// A dial not yet open.
        case connecting
        /// Our sealed dial is open and our `KEY_SHARE` written: the responder's must be the next record (the `link-seal`
        /// contract, §4, step 3), within its own deadline and with its own put-off. The ephemeral key waits on the channel
        /// (``Channel/ephemeral``), never here.
        case awaitingKeyShare
        /// Open, waiting for the other side's HELLO.
        case awaitingHello
        /// Both HELLOs carry ``Capabilities/linkProof``, and the peer's PROOF must be the next record (the
        /// `link-hello-proof` contract, §5). Nothing is written on the channel and nothing about the peer is registered
        /// until it verifies.
        case awaitingProof(PendingProof)
        /// Registered to this peer: frames flow.
        case live(NodeId)
    }

    /// What a dial went to (`Role.dialer(NodeId)` before forms resolved, ADR 2026-11.sv5t): the form it dialed, the key it
    /// is booked under, where, and why. A clear dial expects the advert's id back; a tag dial expects no id, requires a
    /// proof, and takes the proven one (`LinkHandshake.dialTag`, `LinkHandshake.kt:134-154`).
    struct DialTarget: Equatable {
        /// The key the dial, its in-flight slot and its backoff are booked under.
        let key: DialKey
        /// The form dialed, which our HELLO's `a` names.
        let form: AdvertOrder.Form
        /// Where it was dialed.
        let address: RadioAddress
        /// Why, and whom the sighting was attributed to then.
        let record: DialRecord

        /// The id a clear dial expects back; `nil` for a tag dial, which expects none.
        var expected: NodeId? { form.blinded ? nil : form.advertised }

        /// A tag dial's handle.
        var handle: FormHandle? { key.tagHandle }

        /// Whether the sighting dialed resolved to nobody, so a failure also backs off its address and its handle.
        var unresolved: Bool { record.peerKey.nodeId == nil }

        /// Every key a failure of this dial is booked under: the dial key, and while unresolved its address and handle
        /// streaks; never the id a reply named (`LinkHandshake.dialTag`'s KDoc, `:128-131`).
        var failureKeys: [DialKey] {
            [key] + [DialKeys.addressKey(key, unresolved: unresolved), DialKeys.handleKey(key, unresolved: unresolved)].compactMap(\.self)
        }

        /// What the logs name: the id for a clear dial, the handle for a tag dial, never a tag or an address.
        var shown: String { handle?.description ?? form.advertised.string }

        /// Whether the advert dialed carried `FLAG_LINK_SEAL`, so the dial opens with a `KEY_SHARE` (the `link-seal`
        /// contract, §2). Copied from that advert when the dial is made, and from nothing else: not the profile, not an
        /// earlier link.
        var seals = false
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

    /// The live channel to `peer`, if linked.
    func liveChannel(to peer: NodeId) -> ChannelID? {
        liveLinks.first { $0.neighbor.nodeId == peer }?.channel
    }

    /// Channels in the order the radio opened them.
    static func inOrder(_ lhs: ChannelID, _ rhs: ChannelID) -> Bool {
        lhs.rawValue < rhs.rawValue
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
        /// Whether the peer's HELLO told a tag (`t`): it blinds, so its sightings come under tags that rotate, and a rotation
        /// nobody announced leaves the link with no attributed sighting. Such a link scores as never sighted rather than
        /// lost (``LinkManager/linkRssi(_:)``).
        var blinds = false
        /// When a byte last came in on the link, or Knit last ran again after a time it may have been suspended, whichever
        /// is later: `RefuseHeld` passes over a link quiet for ``LinkManager/heldQuietMilliseconds`` (``LinkManager/heldQuiet(_:now:)``).
        var lastRead: Int64
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
        /// Our X25519 key while a sealed dial waits for the responder's `KEY_SHARE`, dropped once it derives. Never in
        /// ``Stage``, which is compared and copied.
        var ephemeral: LinkSeal.Ephemeral?
        /// What a channel opened in the sealed form reads with, from the exchange on; `nil` on a plain one.
        var seal: SealedReads?

        /// Whether the channel carries a registered link.
        var isLive: Bool {
            if case .live = stage {
                return true
            }
            return false
        }

        /// How the channel opened, which the proof's transcript follows (``LinkProof/Form``): never a HELLO's bits.
        var form: LinkProof.Form { seal.map { .sealed($0.shares) } ?? .plain }
    }

    /// A sealed channel's reading side: the opener for the frames, and the reader that splits their plaintext into the
    /// link's records, however the frames cut them (the `link-seal` contract, §5). The sending side is the radio's
    /// (``Radio/seal(_:with:)``).
    struct SealedReads {
        /// Both `KEY_SHARE`s, which the PROOF's transcript binds.
        let shares: LinkSeal.KeyShares
        let opener: LinkOpener
        var inner = LinkRecordReader()
    }
}
