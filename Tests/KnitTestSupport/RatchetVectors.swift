/// knit-next's ratchet known answers, `vectors/ratchet-v1.json` (companion change A9): the ratchet's primitives walked
/// through Alice's first exchange with Bob, and one group epoch of Alice's. Every byte string is lowercase hex, and every
/// bundle padded standard base64. `RatchetVectorTests` checks each answer.
public enum RatchetVectors {
    /// The file's shape. Its `export` answers are not modelled: the spool's exports are not in this port (ADR
    /// 2026-10.5sk9), and the file marks them non-normative.
    public struct File: Decodable, Sendable {
        /// Alice, Bob and Carol, from fixed keys.
        public let identities: [String: VectorIdentity]
        /// The known answers.
        public let kats: Kats
    }

    /// The known answers, one per primitive.
    public struct Kats: Decodable, Sendable {
        /// The fixed X25519 pairs, by name: `bobSpk`, `aliceSpk`, `aliceEph`, `aliceEpoch1` and `bobEpoch1`.
        public let draws: [String: Draw]
        /// Alice's init to Bob, from both sides.
        public let x3dh: X3DH
        /// Alice's first epoch on Bob's prekey, then Bob's on Alice's first epoch.
        public let deriveEpoch: [Epoch]
        /// Four steps of each of those epochs' chains.
        public let chain: [Chain]
        /// The nonce of Alice's first v3 frame.
        public let messageNonce: Nonce
        /// Header bindings, by name: `initFlags0`, `initFlags1`, `noInitFlags0` and `noInitFlags1`.
        public let headerBindingBytes: [String: HeaderBinding]
        /// Alice's and Bob's prekeys' signed bytes and signatures.
        public let spkSigningBytes: [SignedPrekeyBytes]
        /// The tag of the X3DH root.
        public let rootTag: RootTag
        /// One group epoch of Alice's, and its chain.
        public let group: Group
        /// One AES-GCM seal.
        public let aesGcm: AESGCM
    }

    /// A fixed X25519 pair: `priv` is `bytes(32, seed)`.
    public struct Draw: Decodable, Sendable {
        /// The fixture seed.
        public let seed: Int
        /// The private scalar.
        public let priv: String
        /// The public value it derives.
        public let pub: String
    }

    /// One X3DH bootstrap, from the initiator's side and the responder's.
    public struct X3DH: Decodable, Sendable {
        /// Who initiated, by name.
        public let initiator: String
        /// Who responded, by name.
        public let responder: String
        /// The initiator's inputs.
        public let initiate: Initiate
        /// The responder's inputs.
        public let respond: Respond
        /// The root both derive.
        public let root: String
    }

    /// `x3dhInitiate`'s inputs.
    public struct Initiate: Decodable, Sendable {
        /// The initiator's identity X25519 scalar.
        public let ikPriv: String
        /// The ephemeral's private scalar.
        public let ekPriv: String
        /// The responder's identity X25519 key.
        public let peerIkPub: String
        /// The responder's prekey.
        public let peerSpkPub: String
    }

    /// `x3dhRespond`'s inputs.
    public struct Respond: Decodable, Sendable {
        /// The responder's identity X25519 scalar.
        public let ikPriv: String
        /// The prekey's private scalar.
        public let spkPriv: String
        /// The initiator's identity X25519 key.
        public let peerIkPub: String
        /// The initiator's ephemeral.
        public let peerEkPub: String
    }

    /// One epoch derivation: its exchange, its HKDF info and its output.
    public struct Epoch: Decodable, Sendable {
        /// What the epoch is.
        public let note: String
        /// The session root, HKDF's salt.
        public let sessionRoot: String
        /// The epoch's private scalar.
        public let senderEpochPriv: String
        /// The epoch's public value, the header's `ek`.
        public let senderEpochPub: String
        /// The receiver's key the epoch is based on.
        public let basePub: String
        /// The exchange, HKDF's input key material.
        public let dhShared: String
        /// `i` or `r`.
        public let dir: String
        /// Whether the epoch's sender initiated the session.
        public let senderIsInitiator: Bool
        /// The epoch's number.
        public let se: Int
        /// The base's number.
        public let pe: Int
        /// The whole HKDF info.
        public let info: String
        /// HKDF's 64 bytes.
        public let okm: String
        /// The first half.
        public let chainKey: String
        /// The second half.
        public let export: String
    }

    /// The first steps of one epoch's chain.
    public struct Chain: Decodable, Sendable {
        /// Whose chain, by name.
        public let sender: String
        /// The epoch's number.
        public let epoch: Int
        /// Chain key 0.
        public let ck0: String
        /// Steps 0 to 3.
        public let steps: [Step]
    }

    /// One step of a chain.
    public struct Step: Decodable, Sendable {
        /// The index.
        public let n: Int
        /// Chain key n.
        public let ck: String
        /// Message key n.
        public let mk: String
        /// Chain key n + 1.
        public let nextCk: String
    }

    /// A v3 frame's derived nonce.
    public struct Nonce: Decodable, Sendable {
        /// What the frame is.
        public let note: String
        /// Its message key.
        public let mk: String
        /// Its v1 header, as text.
        public let aadText: String
        /// The same header's bytes.
        public let aad: String
        /// The name of the header binding it carries, in `headerBindingBytes`.
        public let headerBinding: String
        /// The header followed by that binding.
        public let boundAad: String
        /// The nonce.
        public let nonce: String
    }

    /// One header and the bytes that bind it.
    public struct HeaderBinding: Decodable, Sendable {
        /// The epoch's number.
        public let se: Int
        /// The epoch's public value.
        public let ek: String
        /// The base's number.
        public let pe: Int
        /// The chain index.
        public let n: Int
        /// The header's flags.
        public let flags: Int
        /// The init, when one rides.
        public let initial: Init?
        /// The binding.
        public let bytes: String

        private enum CodingKeys: String, CodingKey {
            case se = "se"
            case ek = "ek"
            case pe = "pe"
            case n = "n"
            case flags = "flags"
            case initial = "init"
            case bytes = "bytes"
        }
    }

    /// An init's fields.
    public struct Init: Decodable, Sendable {
        /// The initiator's ephemeral.
        public let eph: String
        /// The prekey's id.
        public let pkid: Int
        /// When the session started, in epoch milliseconds.
        public let at: Int64
    }

    /// One prekey's signed bytes, and its owner's signature over them.
    public struct SignedPrekeyBytes: Decodable, Sendable {
        /// Whose prekey, by name.
        public let owner: String
        /// Its id.
        public let id: Int
        /// Its public value.
        public let pub: String
        /// The signed bytes.
        public let bytes: String
        /// Tink's signature: verify it, never compare it.
        public let sig: String
    }

    /// A root's tag.
    public struct RootTag: Decodable, Sendable {
        /// The root.
        public let root: String
        /// The tag's eight bytes.
        public let bytes: String
        /// The same, read as a big-endian signed integer.
        public let int64: Int64
    }

    /// One group epoch of one sender's.
    public struct Group: Decodable, Sendable {
        /// The group's id.
        public let groupId: String
        /// Its founding members, by name.
        public let groupMembers: [String]
        /// The sender's node id.
        public let senderId: String
        /// The sender, by name.
        public let sender: String
        /// The epoch's number.
        public let epoch: Int
        /// The fixture seed of `seed`.
        public let seedSeed: Int
        /// The epoch's seed.
        public let seed: String
        /// The whole HKDF info.
        public let info: String
        /// The first half of the output.
        public let chainKey: String
        /// The second half.
        public let export: String
        /// The first steps of the epoch's chain.
        public let chain: Chain
    }

    /// One AES-GCM seal.
    public struct AESGCM: Decodable, Sendable {
        /// The key.
        public let key: String
        /// The nonce.
        public let iv: String
        /// The associated data.
        public let aad: String
        /// The plaintext.
        public let plaintext: String
        /// The ciphertext followed by its tag.
        public let sealed: String
    }

    /// The file, read once.
    public static let file = VectorFile.read("ratchet-v1.json", as: File.self)
}
