public import KnitCrypto
public import KnitWire

extension GroupRatchetSessions {
    /// What one of the facade's calls came to, under the store unit's contract (ADR 2026-10.5sk9's P4a amendment), as
    /// ``RatchetSessions/Answer`` has it.
    public enum Answer<Result> {
        /// The call's unit ended on its own, committed as the outermost or having changed nothing, and the floors held in
        /// memory already moved: `Result` may be used now.
        case settled(Result)
        /// The call ran inside a unit the caller opened. `Result` stands only once that outermost unit commits; the caller
        /// then passes the ``Settlement`` to ``GroupRatchetSessions/settle(_:)``, and only then sends or delivers what
        /// `Result` holds. A frame sent on a joined seal whose outer unit then failed would have spent a chain key the
        /// rollback gave back, and the next seal would reuse it.
        case joined(Result, Settlement)
        /// A store failed: nothing persisted, no floor moved, and nothing in the call may be used.
        case failed
    }

    /// An open's result (`peekOpen` and `commitOpen`, `GroupRatchetSessions.kt:57-99`, in one phase).
    public enum Opening<Work> {
        /// The frame opened, and its changes stand with the caller's: the plaintext, a `MessageContent`, and the work the
        /// caller's body answered for after the commit.
        case opened(plaintext: [UInt8], work: Work)
        /// The engine refused the frame with a typed failure: nothing changed. Only `NO_KEY` and `AEAD_FAIL` may go on to
        /// ``GroupRatchetSessions/noteUndecryptable(in:from:frameId:sentAt:now:)``.
        case refused(GroupRatchetEngine.OpenOutcome.Failed)
        /// It opened, and the caller's body answered `nil`: every write of the unit, the open's included, is undone.
        case abandoned
    }

    /// A group seal's result (`SealedGroup`, `GroupRatchetSessions.kt:167-172`).
    public enum Sealing: Sendable, Equatable {
        /// The group-form envelope, `{v: 2, nonce, ct, keys: [], g}`, persisted with the chain it spent. `minted` is the
        /// seed of the epoch this seal started, if it started one: the caller distributes it to the roster, and records
        /// the outbox rows, before the frame floods.
        case sealed(EncEnvelope, minted: GroupSeed?)
        /// The engine would not seal, and nothing changed: only an IV source that is not 12 bytes, a test's, comes here.
        case unavailable
    }

    /// What one `CTL_GROUP_KEY` distribution came to (`AdoptResult`, `GroupRatchetSessions.kt:101-106`), with each seed's
    /// verdict, which Kotlin does not hand back.
    public struct Adoption: Sendable, Equatable {
        /// What became of one seed.
        public enum Verdict: Sendable, Equatable {
            /// A fresh chain, stored.
            case adopted
            /// The same `(epoch, mintedAt)` was held: a re-serve, acknowledged again, its chain untouched.
            case alreadyKnown
            /// An older mint of an epoch held under a newer one: ignored, and not acknowledged.
            case stale
            /// A fresh chain past the floor of ``GroupRatchetSessions/maxAdoptionsPerDay``: nothing stored, nothing
            /// acknowledged.
            case floored
        }

        /// The highest epoch worth acknowledging with a `CTL_GROUP_KEY_ACK`, or `nil` for none.
        public let ackEpoch: Int?
        /// How many chains were freshly derived: 0 for a pure re-serve.
        public let freshChains: Int
        /// Each seed's verdict, in the distribution's order.
        public let verdicts: [Verdict]
    }

    /// A group frame as an open reads it: the group header, the carried 12-byte IV, the ciphertext with its tag, and the
    /// AAD, the v1 header `"{id}|{senderId}|{sentAt}|{groupId}"`.
    public struct Frame: Sendable, Equatable {
        /// The group header, `{se, n}`.
        public let header: GroupRatchetHeader
        /// The IV the envelope carries.
        public let nonce: [UInt8]
        /// The ciphertext followed by its tag.
        public let ct: [UInt8]
        /// The frame's v1 header, its thread the group id, as bytes.
        public let aad: [UInt8]

        /// A frame.
        public init(header: GroupRatchetHeader, nonce: [UInt8], ct: [UInt8], aad: [UInt8]) {
            self.header = header
            self.nonce = nonce
            self.ct = ct
            self.aad = aad
        }

        /// The frame a v2 envelope with a group header carries, or `nil` for any other. That the frame is addressed to a
        /// group, which is how Kotlin tells the two v2 forms apart (`InboundPipeline.kt:957-966`), is the pipeline's to check.
        public init?(envelope: EncEnvelope, aad: [UInt8]) {
            guard envelope.version == EncEnvelope.Version.ratchet, let groupHeader = envelope.groupRatchet else {
                return nil
            }
            self.init(header: groupHeader, nonce: envelope.nonce, ct: envelope.ct, aad: aad)
        }
    }

    /// The floors held in memory for one group and sender: what A9's mirror of the key-request heuristic and the adoption
    /// floor reads.
    public struct Floors: Sendable, Equatable {
        /// How many fresh chains were adopted within the last day.
        public let adoptions: Int
        /// How many distinct undecryptable frame ids are held.
        public let undecryptableIds: Int
        /// When we last sent a key request, on our clock.
        public let lastKeyRequestAt: Int64?

        /// Floors as stated.
        public init(adoptions: Int, undecryptableIds: Int, lastKeyRequestAt: Int64?) {
            self.adoptions = adoptions
            self.undecryptableIds = undecryptableIds
            self.lastKeyRequestAt = lastKeyRequestAt
        }
    }

    /// How a call moves the floors held in memory once its unit commits (``GroupRatchetSessions/settle(_:)``): only an
    /// adoption moves one.
    public struct Settlement: Sendable, Equatable {
        /// The group and sender whose adoptions these were, or `nil` when nothing moves.
        let adopter: GroupSender?
        /// How many fresh chains were adopted.
        let adoptions: Int
        /// When, on our clock.
        let at: Int64

        /// Nothing moves.
        static let unchanged = Self(adopter: nil, adoptions: 0, at: 0)
    }

    /// A group and one of its senders, the key every floor here is held under: the group by its bytes (ADR 2026-09.jc2x).
    struct GroupSender: Hashable, Sendable {
        let group: ExactKey
        let sender: NodeId

        init(_ group: String, _ sender: NodeId) {
            self.group = ExactKey(group)
            self.sender = sender
        }
    }
}

extension GroupRatchetSessions.Answer: Sendable where Result: Sendable {}

extension GroupRatchetSessions.Answer: Equatable where Result: Equatable {}

extension GroupRatchetSessions.Opening: Sendable where Work: Sendable {}

extension GroupRatchetSessions.Opening: Equatable where Work: Equatable {}
