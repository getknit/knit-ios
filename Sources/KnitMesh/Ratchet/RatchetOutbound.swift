import KnitCrypto
import KnitStore
import KnitWire

/// The DM ratchet's send rules above the engine, pure (`sealEnvelopeFor`, `ratchetPrekeyOf` and `resealRecentDmsTo` in
/// knit-next's `MeshManager.kt`, at `cbf2a487`, `:1267-1308`, `:1851-1856` and `:3361-3371`): which scheme one of our DMs
/// takes toward a peer, and which of our DMs a peer's reset has us seal again. ``MeshEngine``'s send arm applies them
/// (ADR 2026-10.5sk9, phase P5b). Phase P5d adds what our sealed receipts and ticks take (`canSealTickTo`,
/// `sealDeliveryTickEnvelope` and `sealDmReceipt`), and the room ticks a DM carries inline (`inlineAcksFor`). Phase P5e adds
/// where a reaction of ours goes and what it carries (`sealReaction`), our sealed profile (`currentProfilePayload`), and
/// what an init's answer needs (IntroSync's `canSeal`).
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

    /// What a ratchet seal toward one peer takes: its pinned bundle, the prekey pinned for it if a valid one is, the
    /// plaintext laid out for the scheme its pinned profile reads, and what else that profile says it reads.
    struct Ratcheted: Equatable {
        /// The peer's pinned bundle, whose node id keys the session.
        let bundle: PublicKeyBundle
        /// The verified prekey pinned for the peer, or `nil`: a session held still seals without one, and none starts.
        let prekey: PeerPrekey?
        /// The plaintext, compact for v3 or named for v2 (`MessageContent.sealBytes`).
        let bytes: SealBytes
        /// Whether the pinned profile carries `CAP_CRYPTO_V3`, so a plaintext laid out again, with inline acks, is
        /// compact when it can be (``sealBytes(of:carrying:readsCryptoV3:)``).
        let readsCryptoV3: Bool
        /// Whether the pinned profile carries `CAP_INLINE_ACK` (`inlineAcksFor`'s gate, `MeshManager.kt:2012-2013`), from the
        /// same read as the rest.
        let readsInlineAcks: Bool

        /// Whether the plaintext is laid out for v3.
        var v3: Bool { bytes.scheme == EncEnvelope.Version.compactRatchet }

        /// This seal with `acks` riding `content`, the message's own, in its plaintext (``sealBytes(of:carrying:readsCryptoV3:)``).
        func carrying(_ acks: [String], in content: MessageContent) -> Self {
            Self(
                bundle: bundle,
                prekey: prekey,
                bytes: RatchetOutbound.sealBytes(of: content, carrying: acks, readsCryptoV3: readsCryptoV3),
                readsCryptoV3: readsCryptoV3,
                readsInlineAcks: readsInlineAcks
            )
        }
    }

    /// What a sealed receipt or tick toward one author takes, from one read of its pinned row (`canSealTickTo`,
    /// `MeshManager.kt:2066-2069`; `sealDeliveryTickEnvelope`, `:1868-1872`; `sealDmReceipt`, `InboundPipeline.kt:2904-2913`):
    /// its pinned bundle, the verified prekey pinned for it if a valid one is, and whether it reads v3.
    struct ReceiptPlan: Equatable {
        /// The author's pinned bundle, whose node id keys the session.
        let bundle: PublicKeyBundle
        /// The verified prekey pinned for the author, or `nil`: a session held still seals without one, and with neither
        /// the facade refuses before any key moves.
        let prekey: PeerPrekey?
        /// Whether the pinned profile carries `CAP_CRYPTO_V3`.
        let readsCryptoV3: Bool
    }

    /// The most room ticks a sealed DM receipt carries beside its own `ack` (`DmAckCoalescer.MAX_LORA_TICK_ACKS - 1`,
    /// `InboundPipeline.kt:2924`). Kotlin sizes it for the three-packet LoRa hop, which this port lacks; the bound is
    /// Android's, so both platforms put the same ticks on the same receipt.
    static let maxReceiptRiders = 11

    /// The most room ticks one of our DMs carries inline (`MAX_INLINE_ACKS`, `MeshManager.kt:123`).
    static let maxInlineAcks = 4
    /// What one inline ack costs inside a DM's ciphertext: a 22-character frame id and its CBOR header (`INLINE_ACK_BYTES`,
    /// `MeshManager.kt:120`).
    static let inlineAckBytes = 23
    /// A sealed DM's body budget on Kotlin's LoRa hop, with the X3DH init still attached (`LoraSizeHint.DM_BODY_BYTES`).
    static let dmBodyBytes = 320
    /// What a quoted reply takes of that budget (`LoraSizeHint.REPLY_RESERVE_BYTES`).
    static let replyReserveBytes = 260
    /// What an attachment's reference takes of it (`LoraSizeHint.ATTACHMENT_RESERVE_BYTES`).
    static let attachmentReserveBytes = 170

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
        let bits = Capabilities(rawValue: peer.capabilities ?? 0)
        guard ratchet, bits.contains(.ratchet) else {
            return .staticKeys(bundle)
        }
        let readsV3 = CryptoScheme.readsCryptoV3(peer.capabilities)
        return .ratchet(
            Ratcheted(
                bundle: bundle,
                prekey: pinnedPrekey(of: peer, signedBy: bundle),
                bytes: content.sealBytes(v3: readsV3),
                readsCryptoV3: readsV3,
                readsInlineAcks: bits.contains(.inlineAck)
            )
        )
    }

    /// The prekey pinned for `peer`, verified against `bundle`: the pin was verified as it was taken, and one that would
    /// not verify now counts as none (`ratchetPrekeyOf`, `MeshManager.kt:1851-1856`).
    private static func pinnedPrekey(of peer: PeerRecord, signedBy bundle: PublicKeyBundle) -> PeerPrekey? {
        peer.prekey.flatMap { PeerPrekey(verifying: $0, signedBy: bundle) }
    }

    /// `content` laid out to seal with `acks` riding it, `nil` when none does (`content.copy(acks = inlineAcks.takeIf {
    /// it.isNotEmpty() })`, `MeshManager.kt:1295`): compact when the peer reads v3 and the content, acks included, has a
    /// canonical compact form, else the named v2 layout, so an ack id the compact codec cannot carry moves the DM to v2
    /// rather than losing the tick.
    static func sealBytes(of content: MessageContent, carrying acks: [String], readsCryptoV3: Bool) -> SealBytes {
        var carrying = content
        carrying.acks = acks.isEmpty ? nil : acks
        return carrying.sealBytes(v3: readsCryptoV3)
    }

    /// How many room ticks `message`, one of our DMs, has room to carry inline (`inlineAcksFor`, `MeshManager.kt:2015-2017`):
    /// Kotlin's LoRa body budget for a DM, less what a quote and an attachment reserve and the body's UTF-8 bytes, at
    /// ``inlineAckBytes`` each, from none to ``maxInlineAcks``. This port has no LoRa plane, but the budget is Android's, so
    /// both platforms put the same ticks on the same DM. `LoraSizeHint.utf8Length` counts a lone surrogate as three bytes,
    /// and a Swift string holds none, so its UTF-8 count is the same number.
    static func inlineAckRoom(for message: MessageRecord) -> Int {
        let reserved = (message.replyTo == nil ? 0 : replyReserveBytes) + (message.attachment == nil ? 0 : attachmentReserveBytes)
        let room = max(0, dmBodyBytes - reserved) - message.body.utf8.count
        // Kotlin's `/` truncates toward zero, as Swift's does, before `coerceIn(0, MAX_INLINE_ACKS)`.
        return min(max(room / inlineAckBytes, 0), maxInlineAcks)
    }

    /// What a sealed receipt or tick toward `peer`, the row pinned for it (`nil` for none), takes with the switch at
    /// `ratchet`, or `nil` when the author cannot read one (`canSealTickTo`, `MeshManager.kt:2066-2069`, and the gates of
    /// `sealDeliveryTickEnvelope` and `sealDmReceipt`, `:1868-1870`, `InboundPipeline.kt:2904-2906`): the switch off, no
    /// row, a profile without `CAP_RATCHET`, or a bundle that will not decode. No prekey is asked for, as Kotlin asks none
    /// here; IntroSync's gate (`:345`) is the one that does. With no session and no prekey the seal refuses before any
    /// key moves, so the receipt or tick goes cleartext (ADR 2026-10.5sk9, phase P5d).
    static func receiptPlan(to peer: PeerRecord?, ratchet: Bool) -> ReceiptPlan? {
        guard ratchet, let peer, Capabilities(rawValue: peer.capabilities ?? 0).contains(.ratchet),
            let bundle = PublicKeyBundle(encoded: peer.publicKey)
        else {
            return nil
        }
        return ReceiptPlan(
            bundle: bundle, prekey: pinnedPrekey(of: peer, signedBy: bundle), readsCryptoV3: CryptoScheme.readsCryptoV3(peer.capabilities))
    }

    /// A sealed tick's plaintext acknowledging `ids` (`sealDeliveryTickEnvelope`, `MeshManager.kt:1880-1883`): one id rides
    /// the original `ack`, a batch the additive `acks`, so a single tick reads on every build that reads a sealed receipt.
    static func tick(acking ids: [String]) -> MessageContent {
        guard ids.count == 1 else {
            return MessageContent(body: "", ctl: MessageContent.Control.receipt, acks: ids)
        }
        return MessageContent(body: "", ctl: MessageContent.Control.receipt, ack: ids.first)
    }

    /// A DM's sealed receipt's plaintext (`sealDmReceipt`, `InboundPipeline.kt:2925`): the DM's id in `ack`, and the room
    /// ticks riding it in `acks`, absent when none rides.
    static func dmReceipt(acking ackId: String, riders: [String]) -> MessageContent {
        MessageContent(body: "", ctl: MessageContent.Control.receipt, ack: ackId, acks: riders.isEmpty ? nil : riders)
    }

    /// What an init's answer toward `peer`, the row pinned for it (`nil` for none), takes with the switch at `ratchet`, or
    /// `nil` when we cannot seal one yet: ``receiptPlan(to:ratchet:)``'s gate and a verified prekey pinned beside it, as
    /// IntroSync's `canSeal` asks (`canSealTickTo(peerId) && ratchetPrekeyOf(peers.find(peerId)) != null`,
    /// `MeshManager.kt:345`). Kotlin's `ratchetPrekeyOf` decodes the pinned prekey; this one verifies it against the bundle
    /// too, as every pinned prekey here is read (``pinnedPrekey(of:signedBy:)``).
    static func answerPlan(to peer: PeerRecord?, ratchet: Bool) -> ReceiptPlan? {
        receiptPlan(to: peer, ratchet: ratchet).flatMap { $0.prekey == nil ? nil : $0 }
    }

    /// Whether `peer`'s pinned row comes from a profile, which carries a protocol version or capabilities, and lacks
    /// `CAP_RATCHET` (`ratchetless`, `MeshManager.kt:348-355`): a build without the ratchet, which no answer can reach, so a
    /// debt owed to it is forgiven when such a profile pins (`IntroSync.kt:186-188`). A row with neither is not judged.
    static func isRatchetless(_ peer: PeerRecord) -> Bool {
        (peer.protocolVersion != nil || peer.capabilities != nil) && !Capabilities(rawValue: peer.capabilities ?? 0).contains(.ratchet)
    }

    /// Where one of our reactions goes, by the thread of the message it names (`sealReaction`, `MeshManager.kt:2219-2224`).
    enum ReactionTarget: Equatable {
        /// The Nearby room, plaintext by design: the cleartext `reaction` frame, always, counted as nothing.
        case room
        /// A group: its sealed form is the group ratchet's (`sealGroupReaction`, `:2227-2247`), which phase P6b ports, so
        /// until then the cleartext frame, counted as nothing, since nothing tried to seal it.
        case group
        /// A DM with this peer: sealed as a `CTL_REACTION` when it can read one, else the cleartext frame, counted.
        case direct(NodeId)
    }

    /// Where a reaction to a message in thread `conversationId` goes, for `me` (``Conversations``): the room, a group, or
    /// the DM's other party. A thread id that names no other party, which no DM of ours has, goes as the room's does.
    static func reactionTarget(in conversationId: String, me: NodeId) -> ReactionTarget {
        if Conversations.isGroup(conversationId) {
            return .group
        }
        guard let peer = NodeId(conversationId), peer != me else {
            return .room
        }
        return .direct(peer)
    }

    /// A sealed reaction's plaintext (`sealReaction`, `MeshManager.kt:2219`): the message it names and the emoji, none for
    /// a retraction.
    static func reaction(on messageId: String, emoji: String?) -> MessageContent {
        MessageContent(body: "", ctl: MessageContent.Control.reaction, rp: ReactionContent(messageId: messageId, emoji: emoji))
    }

    /// Our sealed profile's plaintext for `own` (`currentProfilePayload`, `MeshManager.kt:2856-2875`): the presentation as
    /// our cleartext profile presents it, the name and status normalized to one line and cut to their limits, the photo by
    /// its hash, at our profile's version, and the open-to-chat flag. Never the key or the prekey, which ride the cleartext
    /// profile alone (`Wire.kt:682-686`), and no board, which this port never binds.
    static func profile(of own: OwnProfile) -> MessageContent {
        let payload = ProfilePayload(
            name: TextLimits.truncated(TextLimits.normalizeSingleLine(own.name), toUTF16: TextLimits.displayName),
            status: TextLimits.truncated(TextLimits.normalizeSingleLine(own.status), toUTF16: TextLimits.status),
            avatarHash: own.avatarHash?.string,
            version: own.version,
            openToChat: own.openToChat
        )
        return MessageContent(body: "", ctl: MessageContent.Control.profile, pr: payload)
    }

    /// Whether `message` is one of our DMs, from `me`, that a reset from `peer` has us seal again: an ordinary message to
    /// that peer, sent no earlier than `since`, never acknowledged, and not still waiting for a key, which goes out by
    /// itself once one pins (`unackedDmsTo`, `MessageDao.kt:179-187`).
    static func isUnacknowledged(_ message: MessageRecord, to peer: NodeId, from me: NodeId, since: Int64) -> Bool {
        message.senderId == me && message.recipientId == peer && message.kind == .message && !message.delivered
            && !message.pendingKey && message.sentAt >= since
    }
}

/// How our DMs and reactions were sealed so far, under the names of Android's metrics (`MeshMetrics.Seals`,
/// `MeshMetrics.kt:1476-1482`, at `cbf2a487`), all five of them. A v3 seal is a ratchet seal too, so it counts in both, as
/// Android's does (`MeshManager.kt:1296-1298`). The two `dmSealed` counts are our DMs': Kotlin also counts a v3 ctl in
/// `dmSealedV3` (`:2263`, `:2930`), and this port does not, so a trial's `dmSealedV3 >= 1` still means a v3 DM.
public struct RatchetSealCounts: Sendable, Equatable {
    /// DMs sealed with the ratchet, v2 and v3 alike (`dmSealedV2`).
    public internal(set) var dmSealedV2 = 0
    /// Of those, the ones sealed in the compact v3 form (`dmSealedV3`).
    public internal(set) var dmSealedV3 = 0
    /// DMs to a peer whose pinned profile carries `CAP_RATCHET` that went v1 instead (`dmSealedV1Fallback`): no session
    /// and no usable prekey, a new epoch due with no base, or a key X25519 refuses. A persistent count is worth a look.
    public internal(set) var dmSealedV1Fallback = 0
    /// Our reactions sealed as a `CTL_REACTION` (`reactionsSealed`, `onReactionSealed`, `MeshManager.kt:2274`): a DM's, since
    /// phase P5e. A group's waits for P6b.
    public internal(set) var reactionsSealed = 0
    /// Our DM reactions that went as the cleartext `reaction` frame instead (`reactionsSealedFallback`,
    /// `onReactionSealedFallback`, `MeshManager.kt:2189`): a peer who cannot read one, or a seal the facade could not make. A
    /// store that failed counts nothing and sends nothing, as Kotlin's throw does; a room's reaction is never counted, and a
    /// group's not until P6b seals one.
    public internal(set) var reactionsSealedFallback = 0

    /// Counts as stated, each zero unless given: nothing sealed yet.
    public init(
        dmSealedV2: Int = 0, dmSealedV3: Int = 0, dmSealedV1Fallback: Int = 0, reactionsSealed: Int = 0, reactionsSealedFallback: Int = 0
    ) {
        self.dmSealedV2 = dmSealedV2
        self.dmSealedV3 = dmSealedV3
        self.dmSealedV1Fallback = dmSealedV1Fallback
        self.reactionsSealed = reactionsSealed
        self.reactionsSealedFallback = reactionsSealedFallback
    }
}

/// The init answers we sent, under the name of Android's metric (`introsAnswered`, `MeshMetrics.Keys`, `MeshMetrics.kt:1466-1474`,
/// at `cbf2a487`): the one of that group's seven this port counts, since it sends no contact-card intro and reports its
/// key recovery elsewhere (phase P5e).
public struct RatchetAnswerCounts: Sendable, Equatable {
    /// Sealed frames we sent to confirm a still-unconfirmed peer's session, each an answer to an init its frame carried
    /// (`introsAnswered`, `onIntroAnswered`, `IntroSync.kt:239`).
    public internal(set) var introsAnswered = 0

    /// Counts as stated, zero unless given: nothing answered yet.
    public init(introsAnswered: Int = 0) {
        self.introsAnswered = introsAnswered
    }
}
