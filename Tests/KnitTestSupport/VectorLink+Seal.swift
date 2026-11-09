extension VectorLink {
    /// knit-next's sealed link (`link.seal`, the `link-seal` contract's "Vectors"): Alice dials Bob with fixed ephemeral
    /// scalars, both HELLOs at caps `140009`; the KEY_SHAREs, keys, sealed HELLOs, v2 transcripts, sealed PROOFs, frame
    /// splits and the frames and records that must fail.
    public struct Seal: Decodable, Sendable {
        /// One side's fixed ephemeral key and the `KEY_SHARE` record it writes.
        public struct KeyShare: Codable, Sendable, Equatable {
            /// The X25519 private scalar, as hex.
            public let scalar: String
            /// The whole `KEY_SHARE` record (tag 10), as hex.
            public let record: String

            /// Makes an entry.
            public init(scalar: String, record: String) {
                self.scalar = scalar
                self.record = record
            }
        }

        /// A HELLO sealed in one `SEALED` frame.
        public struct SealedHello: Codable, Sendable, Equatable {
            /// The HELLO payload text.
            public let payload: String
            /// The direction key it is sealed under, by its entry name: `keyD2R` or `keyR2D`.
            public let key: String
            /// The frame's counter in its direction.
            public let counter: UInt64
            /// The whole `SEALED` record (tag 11), as hex.
            public let frame: String

            /// Makes an entry.
            public init(payload: String, key: String, counter: UInt64, frame: String) {
                self.payload = payload
                self.key = key
                self.counter = counter
                self.frame = frame
            }
        }

        /// A PROOF record (tag 8) sealed in one `SEALED` frame.
        public struct SealedProof: Codable, Sendable, Equatable {
            /// The identity that signed it.
            public let signer: String
            /// The inner PROOF record, as hex.
            public let record: String
            /// The direction key it is sealed under, by its entry name.
            public let key: String
            /// The frame's counter in its direction.
            public let counter: UInt64
            /// The whole `SEALED` record, as hex.
            public let frame: String

            /// Makes an entry.
            public init(signer: String, record: String, key: String, counter: UInt64, frame: String) {
                self.signer = signer
                self.record = record
                self.key = key
                self.counter = counter
                self.frame = frame
            }
        }

        /// Records spread across frames in a way other than one record per frame.
        public struct Split: Decodable, Sendable {
            /// The direction key, by its entry name.
            public let key: String
            /// The `SEALED` records, as hex, at counters from 0.
            public let frames: [String]
            /// The inner records they open to, as hex.
            public let records: [String]
        }

        /// A frame or record that must fail. Which fields it carries depends on where it fails.
        public struct Reject: Decodable, Sendable {
            /// Why it must fail, in words.
            public let reason: String
            /// A `SEALED` record, as hex, for one that fails to open.
            public let frame: String?
            /// The direction key the reader opens with, by its entry name.
            public let key: String?
            /// The counter the reader is at.
            public let counter: UInt64?
            /// A record, as hex, for one that fails from its header, its key share or its signature.
            public let record: String?
            /// The identity that reads it.
            public let readBy: String?
            /// The identity whose PROOF it claims to be.
            public let signer: String?
            /// The transcript entry it is verified against.
            public let verifyAs: String?
        }

        /// What the section is.
        public let about: String
        /// The identity that dials: `alice`.
        public let dialer: String
        /// The identity that answers: `bob`.
        public let responder: String
        /// Both HELLOs' capabilities, as hex.
        public let capabilities: String
        /// Alice's key and `KEY_SHARE`.
        public let keyShareDialer: KeyShare
        /// Bob's key and `KEY_SHARE`.
        public let keyShareResponder: KeyShare
        /// The X25519 output, as hex.
        public let shared: String
        /// The dialer-to-responder key, as hex.
        public let keyD2R: String
        /// The responder-to-dialer key, as hex.
        public let keyR2D: String
        /// Alice's HELLO, sealed at counter 0 under `keyD2R`.
        public let helloSealedDialer: SealedHello
        /// Bob's reply, sealed at counter 0 under `keyR2D`.
        public let helloSealedReply: SealedHello
        /// What Alice signs as the dialer: the v2 transcript.
        public let transcriptDialer: Transcript
        /// What Bob signs as the responder.
        public let transcriptResponder: Transcript
        /// Bob's PROOF, sealed at counter 1.
        public let proofResponder: SealedProof
        /// Alice's PROOF, sealed at counter 1.
        public let proofDialer: SealedProof
        /// `replyAndProofInOneFrame` and `dialerHelloInTwoFrames`.
        public let splits: [String: Split]
        /// What must fail, by name.
        public let sealRejects: [String: Reject]
    }
}

/// Carol's sealed links in `ios-emitted-v1.json` (`link.seal`, the `link-seal` contract's "Vectors"): she dials Alice, and
/// Alice dials her, with Carol's ephemeral scalar `80..9f` and nonce `20..2f` and Alice's `a0..bf` and `30..3f` in both.
/// knit-next's `IosEmittedVectorTest` rebuilds every KEY_SHARE, key and sealed HELLO byte for byte, and opens and verifies
/// Carol's PROOF frames.
public struct EmittedLinkSeal: Codable, Sendable, Equatable {
    /// What the section is, for a reader who opens it cold.
    public let about: String
    /// Carol dials Alice: Carol's sealed HELLO and her dialer PROOF.
    public let carolDialsAlice: EmittedLinkSealCase
    /// Alice dials Carol: Carol's sealed reply and her responder PROOF.
    public let aliceDialsCarol: EmittedLinkSealCase

    /// Makes the section.
    public init(about: String, carolDialsAlice: EmittedLinkSealCase, aliceDialsCarol: EmittedLinkSealCase) {
        self.about = about
        self.carolDialsAlice = carolDialsAlice
        self.aliceDialsCarol = aliceDialsCarol
    }
}

/// One sealed link of Carol's: both sides' keys and `KEY_SHARE`s, the keys they derive, both HELLO payloads, and what
/// Carol writes in it, her sealed HELLO at counter 0 and her sealed PROOF at counter 1.
public struct EmittedLinkSealCase: Codable, Sendable, Equatable {
    /// The identity that dialed: `carol` or `alice`.
    public let dialer: String
    /// The identity that answered.
    public let responder: String
    /// The identity whose frames these are: always `carol`.
    public let signer: String
    /// The signer's role byte: 1 when it dialed, 2 when it answered.
    public let role: UInt8
    /// Both HELLOs' capabilities, as hex.
    public let capabilities: String
    /// The dialer's key and `KEY_SHARE`.
    public let keyShareDialer: VectorLink.Seal.KeyShare
    /// The responder's key and `KEY_SHARE`.
    public let keyShareResponder: VectorLink.Seal.KeyShare
    /// The X25519 output, as hex.
    public let shared: String
    /// The dialer-to-responder key, as hex.
    public let keyD2R: String
    /// The responder-to-dialer key, as hex.
    public let keyR2D: String
    /// The dialer's HELLO payload text, as it crossed inside its frame.
    public let helloDialer: String
    /// The responder's HELLO payload text.
    public let helloResponder: String
    /// Carol's HELLO, sealed at counter 0 in her direction.
    public let helloSealed: VectorLink.Seal.SealedHello
    /// The v2 transcript Carol signed, as hex.
    public let transcript: String
    /// Carol's PROOF, sealed at counter 1 in her direction. CryptoKit randomizes Ed25519: verify it, never compare it.
    public let proof: VectorLink.Seal.SealedProof

    /// Makes an entry.
    public init(
        dialer: String, responder: String, signer: String, role: UInt8, capabilities: String,
        keyShareDialer: VectorLink.Seal.KeyShare, keyShareResponder: VectorLink.Seal.KeyShare, shared: String, keyD2R: String,
        keyR2D: String, helloDialer: String, helloResponder: String, helloSealed: VectorLink.Seal.SealedHello, transcript: String,
        proof: VectorLink.Seal.SealedProof
    ) {
        self.dialer = dialer
        self.responder = responder
        self.signer = signer
        self.role = role
        self.capabilities = capabilities
        self.keyShareDialer = keyShareDialer
        self.keyShareResponder = keyShareResponder
        self.shared = shared
        self.keyD2R = keyD2R
        self.keyR2D = keyR2D
        self.helloDialer = helloDialer
        self.helloResponder = helloResponder
        self.helloSealed = helloSealed
        self.transcript = transcript
        self.proof = proof
    }
}
