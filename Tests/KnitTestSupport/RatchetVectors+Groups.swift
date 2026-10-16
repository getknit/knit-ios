extension RatchetVectors {
    /// One group-section transcript (`transcriptFormat.group`, written by knit-next's `RatchetGroupVectors` and
    /// `GroupTranscript.kt` on the A9 branch): one group of Alice, Bob and Carol, the rows each party holds at the start,
    /// and steps in the DM transcripts' shape, which add `groupSeal`, `groupOpen`, `depart` and `restore`, and a
    /// `groupState` after every step. The seed, ack and request DMs are DM steps the session layer seals and opens.
    public struct GroupTranscript: Decodable, Sendable {
        /// Its name.
        public let name: String
        /// What it shows.
        public let note: String
        /// The group's id, the hash of the founding set.
        public let groupId: String
        /// The founding roster, by party name, in the creator's order.
        public let founders: [String]
        /// The parties that hold the group's row at the start.
        public let holdsAtStart: [String]
        /// Each party, by name.
        public let parties: [String: TranscriptParty]
        /// Each party's draws, in the order its engines take them: the DM and the group engine share one source.
        public let draws: [String: [TranscriptDraw]]
        /// The steps, in order.
        public let steps: [GroupStep]
    }

    /// One group-section step. A DM step (`seal`, `open`, `reset`) also decodes as the ``TranscriptStep`` it is, in
    /// ``dm``; every step lists the actor's `groupState`, and an open of a group-key DM what the pipeline did with it.
    public struct GroupStep: Decodable, Sendable {
        /// Its index.
        public let step: Int
        /// Who acts, by party name.
        public let actor: String
        /// The step's kind.
        public let op: String
        /// The actor's clock.
        public let now: Int64
        /// The step as a DM transcript's, for `seal`, `open` and `reset`.
        public let dm: TranscriptStep?
        /// A `groupOpen`'s sender, by party name.
        public let peer: String?
        /// A `depart`'s leaver, by party name.
        public let leaver: String?
        /// The indices of the actor's draws a `groupSeal` used.
        public let drawsUsed: [Int]?
        /// A group frame's plaintext, a `MessageContent`.
        public let plaintext: String?
        /// The frame's id.
        public let frameId: String?
        /// The frame's `sentAt`.
        public let sentAt: Int64?
        /// The AAD, `id|sender|sentAt|groupId`, as bytes.
        public let aad: String?
        /// A group frame's header.
        public let groupHeader: GroupHeader?
        /// The carried IV.
        public let nonce: String?
        /// The ciphertext followed by its tag.
        public let ct: String?
        /// The envelope's CBOR.
        public let encEnvelope: String?
        /// A `groupOpen`'s frame, by the index of the step that sealed it.
        public let opens: Int?
        /// A `groupOpen`'s outcome: `OPENED`, or a `GroupRatchetEngine.OpenOutcome.Failed` name.
        public let expect: String?
        /// Whether a `NO_KEY` or `AEAD_FAIL` fired the key-request heuristic, from A9's mirror of the pipeline.
        public let keyRequestDue: Bool? // swiftlint:disable:this discouraged_optional_boolean - absent on every other step
        /// What the pipeline did with an open: a group-key DM's verdicts and acks, or a group frame's row.
        public let applies: GroupApplies?
        /// The actor's group state after the step.
        public let groupState: GroupState

        // swiftlint:disable redundant_string_enum_value - explicit_enum_raw_value wants every key spelled, and each is its name
        private enum CodingKeys: String, CodingKey {
            case step = "step"
            case actor = "actor"
            case op = "op"
            case now = "now"
            case peer = "peer"
            case leaver = "leaver"
            case drawsUsed = "drawsUsed"
            case plaintext = "plaintext"
            case frameId = "frameId"
            case sentAt = "sentAt"
            case aad = "aad"
            case groupHeader = "groupHeader"
            case nonce = "nonce"
            case ct = "ct"
            case encEnvelope = "encEnvelope"
            case opens = "opens"
            case expect = "expect"
            case keyRequestDue = "keyRequestDue"
            case applies = "applies"
            case groupState = "groupState"
        }
        // swiftlint:enable redundant_string_enum_value

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            step = try container.decode(Int.self, forKey: .step)
            actor = try container.decode(String.self, forKey: .actor)
            op = try container.decode(String.self, forKey: .op)
            now = try container.decode(Int64.self, forKey: .now)
            dm = ["seal", "open", "reset"].contains(op) ? try TranscriptStep(from: decoder) : nil
            peer = try container.decodeIfPresent(String.self, forKey: .peer)
            leaver = try container.decodeIfPresent(String.self, forKey: .leaver)
            drawsUsed = try container.decodeIfPresent([Int].self, forKey: .drawsUsed)
            plaintext = try container.decodeIfPresent(String.self, forKey: .plaintext)
            frameId = try container.decodeIfPresent(String.self, forKey: .frameId)
            sentAt = try container.decodeIfPresent(Int64.self, forKey: .sentAt)
            aad = try container.decodeIfPresent(String.self, forKey: .aad)
            groupHeader = try container.decodeIfPresent(GroupHeader.self, forKey: .groupHeader)
            nonce = try container.decodeIfPresent(String.self, forKey: .nonce)
            ct = try container.decodeIfPresent(String.self, forKey: .ct)
            encEnvelope = try container.decodeIfPresent(String.self, forKey: .encEnvelope)
            opens = try container.decodeIfPresent(Int.self, forKey: .opens)
            expect = try container.decodeIfPresent(String.self, forKey: .expect)
            keyRequestDue = try container.decodeIfPresent(Bool.self, forKey: .keyRequestDue)
            applies = try container.decodeIfPresent(GroupApplies.self, forKey: .applies)
            groupState = try container.decode(GroupState.self, forKey: .groupState)
        }
    }

    /// A group frame's header, `{se, n}`.
    public struct GroupHeader: Decodable, Sendable, Equatable {
        /// The sender's epoch.
        public let se: Int
        /// The index within it.
        public let n: Int
    }

    /// What the pipeline did with an open of a group-key DM or a group frame: exactly these, and nothing else.
    public struct GroupApplies: Decodable, Sendable {
        /// Each seed a distribution carried and the engine's verdict on it: `ADOPT`, `ALREADY_KNOWN` or `STALE`, or
        /// `NOT_GATED` when the roster gate kept it from the engine.
        public let seeds: [GroupSeedVerdict]?
        /// The epoch acknowledged back in a `CTL_GROUP_KEY_ACK`, or `nil` for none.
        public let groupKeyAckBack: Int?
        /// The epoch an inbound ack stamped in the outbox.
        public let groupKeyAcked: Int?
        /// Whether a key request went on to the re-distribution after the commit.
        public let redistribute: Bool? // swiftlint:disable:this discouraged_optional_boolean - absent unless a request opened
        /// The roster a seed's receiver pinned from it, holding no row: the pipeline's, phase P6a2's.
        public let groupPinned: GroupRoster?
        /// A group frame's row.
        public let message: TranscriptMessage?
        /// A group frame's reaction.
        public let reaction: TranscriptReaction?
    }

    /// One seed a distribution carried, and what became of it.
    public struct GroupSeedVerdict: Decodable, Sendable {
        /// Its epoch.
        public let epoch: Int
        /// Its mint.
        public let mintedAt: Int64
        /// The verdict.
        public let outcome: String
    }

    /// A roster, by party names.
    public struct GroupRoster: Decodable, Sendable, Equatable {
        /// The members.
        public let members: [String]
        /// The departed.
        public let departed: [String]
        /// Who founded it.
        public let createdBy: String
    }

    /// A party's group state after a step (`GroupWorld.stateJson`, `GroupTranscript.kt:646-728` on the A9 branch): the
    /// roster it holds, its send chains newest epoch first, the receive chains by sender, epoch and mint, the skipped keys
    /// by sender, epoch, mint and index, and the outbox by member. Secrets are SHA-256 hex; a retired chain's are `nil`.
    /// The shared spool root it lists is not modelled: this port keeps `gr` raw and holds no root (ADR 2026-10.5sk9).
    public struct GroupState: Decodable, Sendable {
        /// Whose state, by party name.
        public let of: String
        /// The roster held, or `nil` for no row.
        public let roster: GroupRoster?
        /// The send chains.
        public let sendChains: [GroupSendChainState]
        /// The receive chains.
        public let recvChains: [GroupRecvChainState]
        /// The skipped keys.
        public let skippedKeys: [GroupSkippedKeyState]
        /// The seed outbox.
        public let outbox: [GroupOutboxState]
    }

    /// One send chain as a state lists it.
    public struct GroupSendChainState: Decodable, Sendable {
        /// Its epoch.
        public let epoch: Int
        /// Its mint.
        public let mintedAt: Int64
        /// Frames sealed in it.
        public let count: Int
        /// Whether a forced rekey retired it.
        public let retired: Bool
        /// SHA-256 of its seed, `nil` once retired.
        public let seedSha256: String?
        /// SHA-256 of its next chain key, `nil` once retired.
        public let chainKeySha256: String?
    }

    /// One receive chain as a state lists it.
    public struct GroupRecvChainState: Decodable, Sendable {
        /// Whose chain, by party name.
        public let sender: String
        /// Its epoch.
        public let epoch: Int
        /// Its mint, on the sender's clock.
        public let mintedAt: Int64
        /// Its next index.
        public let next: Int
        /// SHA-256 of its chain key.
        public let chainKeySha256: String
        /// When it last opened a frame.
        public let lastUsedAt: Int64
    }

    /// One skipped key as a state lists it.
    public struct GroupSkippedKeyState: Decodable, Sendable {
        /// Whose chain banked it, by party name.
        public let sender: String
        /// Its epoch.
        public let epoch: Int
        /// Its chain's mint.
        public let mintedAt: Int64
        /// Its index.
        public let idx: Int
    }

    /// One outbox row as a state lists it.
    public struct GroupOutboxState: Decodable, Sendable {
        /// The member, by party name.
        public let member: String
        /// The newest epoch sent it.
        public let sentEpoch: Int
        /// When.
        public let sentAt: Int64
        /// The newest epoch it acknowledged.
        public let ackedEpoch: Int
        /// When.
        public let ackedAt: Int64
    }
}
