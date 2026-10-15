extension RatchetVectors {
    /// One scripted transcript (the file's `transcriptFormat`): the parties, every value each one's engine draws, in
    /// order, and the steps. The `group` section's transcripts are not modelled here: they are the group form's (P6).
    public struct Transcript: Decodable, Sendable {
        /// Its name.
        public let name: String
        /// What it shows.
        public let note: String
        /// Each party, by name.
        public let parties: [String: TranscriptParty]
        /// Each party's draws, in the order its engine takes them.
        public let draws: [String: [TranscriptDraw]]
        /// The steps, in order.
        public let steps: [TranscriptStep]
    }

    /// One party: an identity, the prekeys it holds privately, and the peer prekey it seals against.
    public struct TranscriptParty: Decodable, Sendable {
        /// Its entry in `identities`.
        public let identity: String
        /// Its node id.
        public let nodeId: String
        /// The prekeys it holds, by name in `profiles.prekeys`.
        public let holdsPrekeys: [String]
        /// The prekey it pins for each peer, by name in `profiles.prekeys`.
        public let pins: [String: String]
    }

    /// One injected value: an X25519 pair (`keyPair`, `priv` from `fixtureBytes(32, seed)`), or a v2 IV (`iv`). v3
    /// draws no IV.
    public struct TranscriptDraw: Decodable, Sendable {
        /// Its place in the party's plan.
        public let index: Int
        /// The fixture seed.
        public let seed: Int
        /// `keyPair`, `iv` or `groupSeed`.
        public let kind: String
        /// A pair's private scalar.
        public let priv: String?
        /// A pair's public value.
        public let pub: String?
        /// An IV's 12 bytes.
        public let iv: String?
    }

    /// One step. Which fields it carries depends on `op`: `seal`, `open`, `advance`, and stage 3b's `reset` and `skip`.
    /// Only what the engine's replay reads is modelled: not the signed `wire`, the pipeline's drop flags or `applies`.
    public struct TranscriptStep: Decodable, Sendable {
        /// Its index.
        public let step: Int
        /// Who acts, by party name.
        public let actor: String
        /// The step's kind.
        public let op: String
        /// The other party: the recipient of a seal, the sender of an opened frame.
        public let peer: String
        /// The actor's clock.
        public let now: Int64
        /// A seal's pinned peer prekey, by name.
        public let peerPrekey: String?
        /// The indices of the actor's draws a seal or reset used.
        public let drawsUsed: [Int]?
        /// A seal's plaintext, encoded for its scheme.
        public let plaintext: String?
        /// The frame's id.
        public let frameId: String?
        /// The frame's `sentAt`.
        public let sentAt: Int64?
        /// The v1 header, the AAD, as text.
        public let aadText: String?
        /// The same, as bytes.
        public let aad: String?
        /// The envelope's version: 2 or 3.
        public let version: Int?
        /// The ratchet header.
        public let header: TranscriptHeader?
        /// The envelope's nonce: 12 bytes for v2, empty for v3.
        public let nonce: String?
        /// The ciphertext followed by its tag.
        public let ct: String?
        /// The envelope's CBOR.
        public let encEnvelope: String?
        /// An open's frame, by the index of the step that sealed it.
        public let opens: Int?
        /// What a negative case changed in that frame, or `nil` for the frame as sealed.
        public let mutation: String?
        /// Where an open is decided: `engine`, or `pipeline` above it.
        public let layer: String?
        /// An open's outcome: `OPENED`, an `OpenOutcome.Failed` name, or `REFUSED` above the engine.
        public let expect: String?
        /// The drop the pipeline records, or `nil`.
        public let drop: String?
        /// An advance's count of unlisted v3 seals.
        public let count: Int?
        /// The send index an advance starts from.
        public let fromN: Int?
        /// A reset's plan: `REROOT`, `MARK`, `DECLINED` or `NO_PREKEY`.
        public let result: String?
        /// The actor's state for its peer after the step.
        public let state: TranscriptState?

        private enum CodingKeys: String, CodingKey {
            case step = "step"
            case actor = "actor"
            case op = "op"
            case peer = "peer"
            case now = "now"
            case peerPrekey = "peerPrekey"
            case drawsUsed = "drawsUsed"
            case plaintext = "plaintext"
            case frameId = "frameId"
            case sentAt = "sentAt"
            case aadText = "aadText"
            case aad = "aad"
            case version = "v"
            case header = "header"
            case nonce = "nonce"
            case ct = "ct"
            case encEnvelope = "encEnvelope"
            case opens = "opens"
            case mutation = "mutation"
            case layer = "layer"
            case expect = "expect"
            case drop = "drop"
            case count = "count"
            case fromN = "fromN"
            case result = "result"
            case state = "state"
        }
    }

    /// A ratchet header as a step lists it.
    public struct TranscriptHeader: Decodable, Sendable {
        /// The sender's epoch.
        public let se: Int
        /// The sender's epoch key.
        public let ek: String
        /// The receiver's epoch the sender's is based on, 0 for its prekey.
        public let pe: Int
        /// The chain index.
        public let n: Int
        /// The flags.
        public let flags: Int
        /// The init, while the sender's session is unconfirmed.
        public let initial: Init?

        private enum CodingKeys: String, CodingKey {
            case se = "se"
            case ek = "ek"
            case pe = "pe"
            case n = "n"
            case flags = "flags"
            case initial = "init"
        }
    }

    /// The actor's ratchet state for one peer after a step: secrets as SHA-256 hex, root tags as 16 hex digits, skipped
    /// keys as contiguous index runs.
    public struct TranscriptState: Decodable, Sendable {
        /// Whose state, by party name.
        public let of: String
        /// For which peer, by party name.
        public let peer: String
        /// The session, or `nil` for none.
        public let session: TranscriptSession?
        /// The receive chains, by epoch then root tag.
        public let recvEpochs: [TranscriptRecvEpoch]
        /// How many skipped keys are stored.
        public let skippedKeyCount: Int
        /// The skipped keys, as runs per epoch and root tag.
        public let skippedKeys: [TranscriptSkippedRun]
        /// Our own epochs, the most recently minted first.
        public let localEpochs: [TranscriptLocalEpoch]
    }

    /// A session as a state lists it. Its `sendEpochExportSha256` is not read: the spool's exports are not in this port
    /// (ADR 2026-10.5sk9), and the engine keeps no export half.
    public struct TranscriptSession: Decodable, Sendable {
        /// SHA-256 of the root.
        public let rootSha256: String
        /// Whether the session is confirmed.
        public let confirmed: Bool
        /// Whether we initiated it.
        public let weAreInitiator: Bool
        /// When it was established.
        public let establishedAt: Int64
        /// Our pending init's ephemeral.
        public let initEphPub: String?
        /// The peer prekey our init names.
        public let initPkid: Int
        /// The peer init we last resolved.
        public let peerInitEphPub: String?
        /// The peer epoch we DH against.
        public let peerBasePub: String?
        /// Its number.
        public let peerBaseEpoch: Int
        /// Our send epoch.
        public let sendEpoch: Int
        /// Its key.
        public let sendEpochPub: String?
        /// SHA-256 of the next chain key.
        public let sendChainKeySha256: String?
        /// Frames sealed in it.
        public let sendCount: Int
        /// When it started.
        public let sendEpochStartedAt: Int64
        /// The peer epoch it is based on.
        public let sendEpochBaseEpoch: Int
        /// The highest of our epochs the peer sealed against.
        public let highestPeAcked: Int
        /// SHA-256 of the root being drained.
        public let prevRootSha256: String?
        /// Our role under it.
        public let prevRootWeAreInitiator: Bool
        /// When it stops draining.
        public let prevRootExpiresAt: Int64
        /// When we last sealed a reset.
        public let lastResetSentAt: Int64
    }

    /// One receive chain as a state lists it.
    public struct TranscriptRecvEpoch: Decodable, Sendable {
        /// The peer's epoch.
        public let epoch: Int
        /// The tag of the root that derived it, as 16 hex digits.
        public let rootTag: String
        /// Its next index.
        public let next: Int
        /// SHA-256 of its chain key.
        public let chainKeySha256: String
        /// When it last opened a frame.
        public let lastUsedAt: Int64
    }

    /// A run of skipped keys: one epoch, one root, contiguous indices.
    public struct TranscriptSkippedRun: Decodable, Sendable {
        /// The peer's epoch.
        public let epoch: Int
        /// The tag of the root that derived them.
        public let rootTag: String
        /// The first index.
        public let fromIdx: Int
        /// The last index.
        public let toIdx: Int
    }

    /// One of our epochs as a state lists it.
    public struct TranscriptLocalEpoch: Decodable, Sendable {
        /// Its number.
        public let epoch: Int
        /// When it was minted.
        public let createdAt: Int64
        /// Its public key.
        public let pub: String
    }
}
