import KnitCrypto
import KnitWire

/// The DM ratchet's receive rules above the engine, pure (`InboundPipeline.decryptAndDeliver`, `decryptAndDeliverV2`,
/// `onRatchetFailure` and `applyCtlInTxn` in knit-next's `InboundPipeline.kt`, at `cbf2a487`): which frames reach the
/// ratchet, what is refused before it, how a plaintext is read, which failures feed the reset heuristic, and which ids
/// a receipt acknowledges. ``MeshEngine``'s ratchet arm applies them (ADR 2026-10.5sk9, phase P5a).
internal enum RatchetInbound {
    /// The most ids one sealed receipt, or one plain DM's inline acks, may acknowledge: twice the send side's batch
    /// (`MAX_RECEIPT_ACKS = 2 * AckSync.MAX_BATCH_ACKS`, `InboundPipeline.kt:3680`, `AckSync.kt:780`), so a hostile frame
    /// cannot loop us.
    static let maxReceiptAcks = 128

    /// The length of a v2 envelope's carried nonce (`AesGcm.IV_BYTES`).
    static let nonceByteCount = 12

    /// Where a frame the ratchet arm opens comes from, which bounds what its open may set in motion (phase P5a).
    enum Origin: Equatable, Sendable {
        /// Off a link, or the copy a failed first verdict kept, at the sweep: the frame's first verdict, as Kotlin
        /// gives every open. A failure that counts is evidence for the reset heuristic and lets one copy of its id
        /// past the router, and an init may move the session's era.
        case firstVerdict
        /// Out of our own custody at start, a frame with no row whose verdict, if it had one, came before the restart: a
        /// delivery path and nothing more. A failure counts under its reason alone, nothing is let past the router, and
        /// an init the held session has not resolved moves no era, since the pair may have left that era since. Kotlin
        /// replays nothing from its own custody, so it meets neither.
        case startReplay
    }

    /// How a sealed DM reached the inbound path: the neighbour that handed it over, if one did, whether it came signed,
    /// and where it comes from.
    struct Route: Equatable, Sendable {
        /// The neighbour it came over; `nil` out of our own custody, which kept no hop.
        let hop: NodeId?
        /// Whether its signature verified; `false` only for the v3 live-link tick.
        let signed: Bool
        /// Whether this open is its first verdict.
        let origin: Origin
    }

    /// Whether `enc` is the DM form the ratchet arm takes: v2 or v3, both of which carry the header `r`
    /// (`EncEnvelope.isDmRatchetVersion`, `Wire.kt:810`). A v2 envelope addressed to a group is the group form instead,
    /// which the caller routes apart.
    static func isDirectRatchet(_ enc: EncEnvelope) -> Bool {
        enc.version == EncEnvelope.Version.ratchet || enc.version == EncEnvelope.Version.compactRatchet
    }

    /// The one envelope an unsigned frame may carry (`admitsUnsigned`, `InboundPipeline.kt:1739-1740`, knit-next ADR
    /// 059): v3, the DM header, and no group header. Anything else unsigned is refused before it can reach the clear
    /// branch or the exists-gate, where anyone who overheard a DM's id could make us acknowledge it.
    static func admitsUnsigned(_ enc: EncEnvelope?) -> Bool {
        guard let enc else {
            return false
        }
        return enc.version == EncEnvelope.Version.compactRatchet && enc.ratchet != nil && enc.groupRatchet == nil
    }

    /// The frame a DM-form envelope hands the engine, or `nil` when it is malformed before the engine, which is
    /// `RATCHET_BAD_HEADER` (`decryptAndDeliverV2`, `InboundPipeline.kt:1017-1028`; `nonceShapeValid`, `:1746-1747`): no
    /// header, a v3 nonce that is not empty, or a v2 nonce that is not 12 bytes. v3 is signalled to the engine by a
    /// `nil` nonce, set from the version after the empty-nonce check: mapping an empty nonce to `nil` would read a v2
    /// frame with an empty nonce as v3, and fail it as `AEAD_FAIL`, which counts toward a reset.
    static func frame(_ enc: EncEnvelope, aad: [UInt8]) -> RatchetSessions.Frame? {
        let v3 = enc.version == EncEnvelope.Version.compactRatchet
        guard let header = enc.ratchet, v3 ? enc.nonce.isEmpty : enc.nonce.count == nonceByteCount else {
            return nil
        }
        return RatchetSessions.Frame(header: header, nonce: v3 ? nil : enc.nonce, ct: enc.ct, aad: aad)
    }

    /// The content a plaintext that opened holds, read by the envelope's version: the compact layout for v3, the named
    /// one for v2 (`decodePlaintext`, `InboundPipeline.kt:1750-1753`). `nil` when it will not decode (`DECRYPT_FAILED`)
    /// or its content version is newer than this build reads (`isSupported`, `UNKNOWN_CONTENT_VERSION`): either way
    /// Kotlin drops the frame before its commit, so the chain index stays unspent (`:1043-1052`).
    static func content(of plaintext: [UInt8], v3: Bool) -> MessageContent? {
        let content = v3 ? MessageContentV2.decode(plaintext) : try? MessageContent(decoding: plaintext)
        guard let content, content.version <= MessageContent.currentVersion else {
            return nil
        }
        return content
    }

    /// The drop a typed failure records (`onRatchetFailure`, `InboundPipeline.kt:1781-1790`).
    static func dropReason(for failure: RatchetEngine.OpenOutcome.Failed) -> DropReason {
        switch failure {
        case .noSession:
            .ratchetNoSession
        case .epochGone:
            .ratchetEpochGone
        case .duplicate:
            .ratchetDuplicate
        case .badHeader:
            .ratchetBadHeader
        case .aeadFail:
            .ratchetAeadFail
        }
    }

    /// Whether a failure is evidence for the reset heuristic (`InboundPipeline.kt:1819-1826`): one of
    /// ``RatchetResetPolicy/triggeringFailures``, from a frame whose signature verified, at its first verdict. `AEAD_FAIL`
    /// may count only because the signature came first (knit-next `d1984ea9`); the unsigned tick never counts, or three
    /// forged frames with distinct ids would buy an attacker a reset per pair; and a start's replay never does, or the
    /// tail an era left in our custody would buy a reset at every restart past the 6 h floor.
    static func countsTowardReset(_ failure: RatchetEngine.OpenOutcome.Failed, route: Route) -> Bool {
        route.signed && route.origin == .firstVerdict && RatchetResetPolicy.triggeringFailures.contains(failure)
    }

    /// The ids a receipt acknowledges, the single `ack` first, each once by its bytes, at most ``maxReceiptAcks``
    /// (`(listOfNotNull(ack) + acks).distinct().take(MAX_RECEIPT_ACKS)`, `InboundPipeline.kt:1215-1222`). A plain DM's
    /// inline acks pass `ack` as `nil` (`applyInlineAcks`, `:1106-1116`).
    static func acknowledged(ack: String?, acks: [String]?) -> [String] {
        var seen: Set<ExactKey> = []
        var ids: [String] = []
        for id in [ack].compactMap(\.self) + (acks ?? []) where seen.insert(ExactKey(id)).inserted {
            ids.append(id)
            if ids.count == maxReceiptAcks {
                break
            }
        }
        return ids
    }
}
