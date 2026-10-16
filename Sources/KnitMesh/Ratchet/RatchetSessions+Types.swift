public import KnitCrypto
public import KnitWire

extension RatchetSessions {
    /// What one of the facade's calls came to, under the store unit's contract (ADR 2026-10.5sk9's P4a amendment).
    public enum Answer<Result> {
        /// The call's unit ended on its own, committed as the outermost or having changed nothing, and the floors held in
        /// memory already moved: `Result` may be used now.
        case settled(Result)
        /// The call ran inside a unit the caller opened. `Result` stands only once that outermost unit commits; the caller
        /// then passes the ``Settlement`` to ``RatchetSessions/settle(_:)``, and only then sends or delivers what `Result`
        /// holds. A helper that sent on a joined answer whose outer unit then failed would have put a frame on air whose
        /// chain advance rolled back, and the next seal would reuse its message key.
        case joined(Result, Settlement)
        /// A store failed: nothing persisted, no floor moved, and nothing in the call may be used. An inbound frame whose
        /// open failed this way is kept in memory as the copy that failed, and the engine opens it again at the next sweep
        /// (``RatchetReplay``).
        case failed
    }

    /// A DM seal's result (`sealDm`'s `EncEnvelope?`, `RatchetSessions.kt:223-277`).
    public enum Sealing: Sendable, Equatable {
        /// The envelope, persisted with the chain it spent.
        case sealed(EncEnvelope)
        /// No session and no prekey to start one, or a new epoch due with no base: nothing changed. A chat then goes as
        /// v1, a ctl as its cleartext frame, and a seed waits.
        case unavailable
        /// X25519 refused the peer's identity key or prekey, which a peer signs as it likes: nothing changed, handled as
        /// ``unavailable``, and nothing counts toward a reset.
        case refusedKey
    }

    /// An open's result (`peekOpen` and `commitOpen`, `RatchetSessions.kt:161-221`, in one phase).
    public enum Opening<Work> {
        /// The frame opened, and its changes stand with the caller's: the plaintext, `MessageContent` for v2 and
        /// `MessageContentV2` for v3, and the work the caller's body answered for after the commit.
        case opened(plaintext: [UInt8], work: Work)
        /// The engine refused the frame with a typed failure: nothing changed. Only an authenticated frame's failure in
        /// ``RatchetResetPolicy/triggeringFailures`` may go on to
        /// ``RatchetSessions/noteUndecryptable(from:frameId:sentAt:now:)``.
        case refused(RatchetEngine.OpenOutcome.Failed)
        /// X25519 refused the init's ephemeral or the peer's identity key in the X3DH respond, where Tink throws out of
        /// Kotlin's engine (`InboundPipeline`'s `runCatching`, `DECRYPT_FAILED`): nothing committed, and nothing counts
        /// toward a reset.
        case rejected
        /// It opened, and the caller's body answered `nil`: every write of the unit, the open's included, is undone.
        case abandoned
    }

    /// A reset's result (`ResetSeal`, `RatchetSessions.kt:516-531`), with the plan that decided it.
    public enum ResetSealing: Sendable, Equatable {
        /// The reset marker, sealed v2 and persisted: under a fresh root when the plan re-rooted, else under the session
        /// held, flagged while an init rides.
        case sealed(EncEnvelope, plan: RatchetResetPolicy.Plan)
        /// Nothing sealed: the plan declined, for `reason`, in Android's words.
        case declined(reason: String, plan: RatchetResetPolicy.Plan)
        /// The peer has no usable prekey, or the session held cannot be sealed under: nothing changed.
        case noPrekey
        /// X25519 refused the peer's identity key or prekey: nothing changed.
        case refusedKey
    }

    /// A DM ratchet frame as an open reads it: the header, the carried v2 nonce (`nil` for v3, whose nonce derives), the
    /// ciphertext with its tag, and the AAD, the v1 header `"{id}|{senderId}|{sentAt}|{recipientId}"`.
    public struct Frame: Sendable, Equatable {
        /// The ratchet header.
        public let header: RatchetHeader
        /// The 12-byte v2 IV, or `nil` for v3.
        public let nonce: [UInt8]?
        /// The ciphertext followed by its tag.
        public let ct: [UInt8]
        /// The frame's v1 header, as bytes.
        public let aad: [UInt8]

        /// A frame.
        public init(header: RatchetHeader, nonce: [UInt8]?, ct: [UInt8], aad: [UInt8]) {
            self.header = header
            self.nonce = nonce
            self.ct = ct
            self.aad = aad
        }

        /// The frame a v2 or v3 envelope carries, or `nil` for any other. A v3 envelope's nonce is not read, since the
        /// nonce derives (`decryptAndDeliverV2`'s `enc.nonce.takeIf { !v3 }`); that it is empty, and that a v2 one is 12
        /// bytes, is the pipeline's to check first (`InboundPipeline.kt:1025-1028`), which the engine's inbound path does
        /// with `RatchetInbound.frame(_:aad:)`.
        public init?(envelope: EncEnvelope, aad: [UInt8]) {
            let v3 = envelope.version == EncEnvelope.Version.compactRatchet
            guard let ratchet = envelope.ratchet, v3 || envelope.version == EncEnvelope.Version.ratchet else {
                return nil
            }
            self.init(header: ratchet, nonce: v3 ? nil : envelope.nonce, ct: envelope.ct, aad: aad)
        }
    }

    /// The floors held in memory for one peer, `nil` where none is held: what the vectors' `floorsBefore` states.
    public struct Floors: Sendable, Equatable {
        /// When we last adopted a replacement from the peer, or lost a race to it.
        public let lastReplacementAt: Int64?
        /// When the peer answered our own init.
        public let confirmedAt: Int64?
        /// When we last sealed a reset, held for a peer with no session row (`lastResetSentAtInMemory`).
        public let lastResetSentAt: Int64?
        /// How many distinct undecryptable frame ids are held.
        public let undecryptableIds: Int

        /// Floors as stated.
        public init(lastReplacementAt: Int64?, confirmedAt: Int64?, lastResetSentAt: Int64?, undecryptableIds: Int) {
            self.lastReplacementAt = lastReplacementAt
            self.confirmedAt = confirmedAt
            self.lastResetSentAt = lastResetSentAt
            self.undecryptableIds = undecryptableIds
        }
    }

    /// How a call moves the floors held in memory once its unit commits (``RatchetSessions/settle(_:)``).
    public struct Settlement: Sendable, Equatable {
        /// The peer whose floors move.
        public let peer: NodeId
        /// A replacement adopted, or a race lost, at this time: the replacement floor starts, and the heuristic's ids from
        /// the era left are moot.
        let replacementAdoptedAt: Int64?
        /// The peer answered our own init at this time.
        let initAnsweredAt: Int64?
        /// We sealed a reset at this time, which answers the heuristic's ids.
        let resetSealedAt: Int64?
        /// Our init's answer is moot: we left that root.
        let clearsConfirmedAt: Bool

        /// Whether the heuristic's frame ids go: a fresh session or our own reset makes them moot (`RatchetSessions.kt:211`,
        /// `:435`, `:466`).
        var clearsUndecryptable: Bool {
            replacementAdoptedAt != nil || resetSealedAt != nil
        }

        /// Nothing moves.
        static func unchanged(_ peer: NodeId) -> Self {
            Self(peer: peer, replacementAdoptedAt: nil, initAnsweredAt: nil, resetSealedAt: nil, clearsConfirmedAt: false)
        }

        /// An open at `now` that adopted a replacement, or answered our own init.
        static func opened(from peer: NodeId, at now: Int64, adoptedReplacement: Bool, answeredOurInit: Bool) -> Self {
            Self(
                peer: peer,
                replacementAdoptedAt: adoptedReplacement ? now : nil,
                initAnsweredAt: answeredOurInit ? now : nil,
                resetSealedAt: nil,
                clearsConfirmedAt: false
            )
        }

        /// A reset sealed at `now`, under a fresh root when `reRooted`.
        static func reset(to peer: NodeId, at now: Int64, reRooted: Bool) -> Self {
            Self(peer: peer, replacementAdoptedAt: nil, initAnsweredAt: nil, resetSealedAt: now, clearsConfirmedAt: reRooted)
        }

        /// Every row dropped.
        static func forgotten(_ peer: NodeId) -> Self {
            Self(peer: peer, replacementAdoptedAt: nil, initAnsweredAt: nil, resetSealedAt: nil, clearsConfirmedAt: true)
        }
    }
}

extension RatchetSessions.Answer: Sendable where Result: Sendable {}

extension RatchetSessions.Answer: Equatable where Result: Equatable {}

extension RatchetSessions.Opening: Sendable where Work: Sendable {}

extension RatchetSessions.Opening: Equatable where Work: Equatable {}
