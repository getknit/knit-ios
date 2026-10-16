import KnitCrypto
import KnitStore
import KnitWire

/// The DM ratchet's send rules above the engine, pure (`sealEnvelopeFor`, `ratchetPrekeyOf` and `resealRecentDmsTo` in
/// knit-next's `MeshManager.kt`, at `cbf2a487`, `:1267-1308`, `:1851-1856` and `:3361-3371`): which scheme one of our DMs
/// takes toward a peer, and which of our DMs a peer's reset has us seal again. ``MeshEngine``'s send arm applies them
/// (ADR 2026-10.5sk9, phase P5b). Phase P5d adds what our sealed receipts and ticks take (`canSealTickTo`,
/// `sealDeliveryTickEnvelope` and `sealDmReceipt`), and the room ticks a DM carries inline (`inlineAcksFor`).
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
