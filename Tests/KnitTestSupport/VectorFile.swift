public import Foundation

/// The JSON files in `Tests/Vectors/`. `scripts/sync-vectors.py` copies `wire-v1.json`, `keyed-v1.json`,
/// `ratchet-v1.json`, `custody-v1.json` and `name-key-v1.json` from knit-next's `vectors/`; `ios-emitted-v1.json` is
/// written here and copied the other way.
public enum VectorFile {
    /// Where the files live.
    public static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Vectors")

    /// Whether a test run should rewrite the files this repo emits: `KNIT_WRITE_VECTORS=1`, as in knit-next.
    public static var writing: Bool { ProcessInfo.processInfo.environment["KNIT_WRITE_VECTORS"] == "1" }

    /// A file decoded as `type`. A missing or malformed file is a broken checkout, so it traps with the fix.
    public static func read<Value: Decodable>(_ name: String, as type: Value.Type) -> Value {
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: directory.appendingPathComponent(name)))
        } catch {
            fatalError("Tests/Vectors/\(name) is missing or unreadable (\(error)); run scripts/sync-vectors.py")
        }
    }

    /// Writes `value` as sorted, indented JSON with a final newline.
    public static func write(_ value: some Encodable, to name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(contentsOf: Array("\n".utf8))
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}

/// One fixed identity: its raw private keys, and what they must derive to.
public struct VectorIdentity: Codable, Sendable, Equatable {
    /// The Ed25519 seed, as hex.
    public let signingSeed: String
    /// The X25519 scalar, as hex.
    public let agreementScalar: String
    /// The public bundle's base64.
    public let bundle: String
    /// The node id.
    public let nodeId: String

    /// Makes an identity entry.
    public init(signingSeed: String, agreementScalar: String, bundle: String, nodeId: String) {
        self.signingSeed = signingSeed
        self.agreementScalar = agreementScalar
        self.bundle = bundle
        self.nodeId = nodeId
    }
}

/// A signed frame as it goes on the air, and who sent it.
public struct VectorFrame: Codable, Sendable, Equatable {
    /// The sender's name in `identities`.
    public let sender: String
    /// A DM's recipient, by name.
    public let recipient: String?
    /// A group frame's group id (ADR 2026-09.n393).
    public let groupId: String?
    /// A group frame's founding members, by name.
    public let members: [String]?
    /// A rename's new name.
    public let name: String?
    /// The text a reader should see.
    public let body: String?
    /// A ratchet profile's prekey, by its name in ``EmittedRatchet/prekeys`` (phase P7b).
    public let prekey: String?
    /// A profile's capability bits, where the entry pins them (phase P7b).
    public let capabilities: Int64?
    /// A profile's version, where the entry pins it (phase P7b).
    public let version: Int64?
    /// What a ratchet seal carries and opens to (phase P7b).
    public let sealed: VectorSealed?
    /// The length of the frame's `signed`, where the entry pins it: the profile cap's edge frames (ADR 2026-10.r88m).
    public let signedBytes: Int?
    /// The encoded `WireEnvelope`, as hex.
    public let wire: String

    /// Makes a frame entry.
    public init(
        sender: String,
        recipient: String? = nil,
        groupId: String? = nil,
        members: [String]? = nil,
        name: String? = nil,
        body: String? = nil,
        prekey: String? = nil,
        capabilities: Int64? = nil,
        version: Int64? = nil,
        sealed: VectorSealed? = nil,
        signedBytes: Int? = nil,
        wire: String
    ) {
        self.sender = sender
        self.recipient = recipient
        self.groupId = groupId
        self.members = members
        self.name = name
        self.body = body
        self.prekey = prekey
        self.capabilities = capabilities
        self.version = version
        self.sealed = sealed
        self.signedBytes = signedBytes
        self.wire = wire
    }

    /// The same entry carrying `wire` instead.
    public func carrying(_ wire: String) -> Self {
        Self(
            sender: sender,
            recipient: recipient,
            groupId: groupId,
            members: members,
            name: name,
            body: body,
            prekey: prekey,
            capabilities: capabilities,
            version: version,
            sealed: sealed,
            signedBytes: signedBytes,
            wire: wire
        )
    }
}

/// A safety number and the two identities it is between.
public struct VectorSafetyNumber: Codable, Sendable, Equatable {
    /// The two names in `identities`.
    public let between: [String]
    /// The forty digits.
    public let number: String

    /// Makes a safety-number entry.
    public init(between: [String], number: String) {
        self.between = between
        self.number = number
    }
}

/// knit-next's link vectors: the HELLO, DIGEST and FILE_HEADER records, the custody fingerprint, an advert, and a link
/// proof (`link-hello-proof`, knit-next ADR 2026-11.264w). The headers are a whole photo's and the rest of a cut one's,
/// which answers a `blobreq` naming an offset (knit-next ADR 2026-10.wtyc).
public struct VectorLink: Decodable, Sendable {
    /// A HELLO record and its text payload. This port's emitted link proofs carry their HELLOs in the same shape.
    public struct Hello: Codable, Sendable, Equatable {
        /// `nodeId|version|capsHex`, then `|n<nonce>` from a build that proves its id.
        public let payload: String
        /// The whole record, as hex.
        public let record: String

        /// Makes an entry.
        public init(payload: String, record: String) {
            self.payload = payload
            self.record = record
        }
    }

    /// The bytes one side of a proven link signs (`LinkProof.transcript`).
    public struct Transcript: Decodable, Sendable {
        /// The keyed identity that signs it.
        public let signer: String
        /// The signer's role byte: 1 when it dialed, 2 when it answered.
        public let role: UInt8
        /// The transcript, as hex.
        public let hex: String
    }

    /// A PROOF record (tag 8): the signer's two raw public keys, then its signature. Tink signed it, so Android rebuilds it
    /// byte for byte; this port checks the header and keys and verifies the signature.
    public struct Proof: Decodable, Sendable {
        /// The keyed identity that signed it.
        public let signer: String
        /// The whole record, as hex.
        public let record: String
    }

    /// A PROOF record that must fail.
    public struct ProofReject: Decodable, Sendable {
        /// What it is checked as: `<identity>, <role>, <transcript entry>`.
        public let checkedAs: String
        /// Why it must fail, in words.
        public let reason: String
        /// The whole record, as hex.
        public let record: String
    }

    /// A DIGEST record and the ids in it.
    public struct Digest: Decodable, Sendable {
        /// The ids, in the order sent.
        public let ids: [String]
        /// The whole record, as hex.
        public let record: String
    }

    /// The custody fingerprint of an id set.
    public struct Fold: Decodable, Sendable {
        /// The ids.
        public let ids: [String]
        /// The XOR of their FNV-1a hashes, as sixteen hex digits.
        public let fold: String
    }

    /// A FILE_HEADER record and its fields.
    public struct FileHeader: Decodable, Sendable {
        /// `AVATAR` or `ATTACHMENT`.
        public let kind: String
        /// The blob's content hash.
        public let key: String
        /// The blob's type.
        public let mime: String
        /// The length of the stream that follows.
        public let size: Int
        /// The blob's byte the stream starts at, for the rest of a cut transfer; absent from a whole file's.
        public let offset: Int?
        /// The whole record, as hex.
        public let record: String
    }

    /// A 24-byte advert and its fields.
    public struct Advert: Decodable, Sendable {
        /// The advertised node id.
        public let nodeId: String
        /// The capability bits.
        public let capabilities: Int64
        /// The low 32 bits of the custody fingerprint.
        public let digestCue: UInt32
        /// The L2CAP PSM.
        public let psm: UInt16
        /// The flags byte.
        public let flags: UInt8
        /// The service data, as hex.
        public let serviceData: String
    }

    /// The HELLO.
    public let hello: Hello
    /// The DIGEST.
    public let digest: Digest
    /// The fingerprint.
    public let digestFold: Fold
    /// A photo's header, as a sender writes it.
    public let fileHeader: FileHeader
    /// The header of the rest of a photo whose transfer a link drop cut off, as a holder writes it.
    public let fileHeaderResumed: FileHeader
    /// The advert.
    public let advert: Advert
    /// Alice's HELLO dialing Bob, with the bit and her nonce `00..0f`.
    public let helloProofDialer: Hello
    /// Bob's reply, with his nonce `10..1f`.
    public let helloProofReply: Hello
    /// What Alice signs as the dialer.
    public let proofTranscriptDialer: Transcript
    /// What Bob signs as the responder.
    public let proofTranscriptResponder: Transcript
    /// Alice's PROOF.
    public let proofDialer: Proof
    /// Bob's PROOF.
    public let proofResponder: Proof
    /// Records that must fail against the dialer's transcript, by name: `wrongRole`, `otherResponderNonce`, `idMismatch`
    /// and `short`.
    public let proofRejects: [String: ProofReject]
}

/// knit-next's keyed vectors, `vectors/keyed-v1.json`: identities, Alice's signed frames and her DM to Bob, and
/// the link records a peer reads before any frame.
public enum KeyedVectors {
    /// The file's shape.
    public struct File: Decodable, Sendable {
        /// Alice and Bob.
        public let identities: [String: VectorIdentity]
        /// Their safety number.
        public let safetyNumber: VectorSafetyNumber
        /// `aliceProfile`, `aliceRoomPost` and `aliceDmToBob`, and the profile cap's edge, `aliceProfileAtCap` and
        /// `aliceProfileOverCap`.
        public let frames: [String: VectorFrame]
        /// The link vectors.
        public let link: VectorLink
        /// Blinded adverts' vectors.
        public let blind: VectorBlind
    }

    /// The file, read once.
    public static let file = VectorFile.read("keyed-v1.json", as: File.self)
}

/// What this port emits for knit-next to check, `Tests/Vectors/ios-emitted-v1.json`: Carol's identity, her
/// signed frames, her DM to knit-next's Bob, and their safety number.
public struct EmittedVectors: Codable, Sendable, Equatable {
    /// The file's name, here and in knit-next's `vectors/`.
    public static let fileName = "ios-emitted-v1.json"

    /// What the file is, for a reader who opens it cold.
    public let about: String
    /// Carol.
    public let identities: [String: VectorIdentity]
    /// Carol and Bob's safety number.
    public let safetyNumber: VectorSafetyNumber
    /// Carol's frames by name: her v1 frames, and her ratchet frames, which ``ratchet`` says how to open.
    public let frames: [String: VectorFrame]
    /// What a reader needs to open Carol's ratchet frames (phase P7b); absent before it.
    public let ratchet: EmittedRatchet?
    /// Carol's link proofs (`link-hello-proof`); absent before it.
    public let link: EmittedLink?

    /// Makes the file's content.
    public init(
        about: String, identities: [String: VectorIdentity], safetyNumber: VectorSafetyNumber, frames: [String: VectorFrame],
        ratchet: EmittedRatchet? = nil, link: EmittedLink? = nil
    ) {
        self.about = about
        self.identities = identities
        self.safetyNumber = safetyNumber
        self.frames = frames
        self.ratchet = ratchet
        self.link = link
    }

    /// The committed file, or `nil` before it has been written.
    public static var committed: Self? {
        guard FileManager.default.fileExists(atPath: VectorFile.directory.appendingPathComponent(fileName).path) else {
            return nil
        }
        return VectorFile.read(fileName, as: Self.self)
    }
}

/// Carol's link proofs in `ios-emitted-v1.json` (`link-hello-proof`): one as the dialer and one as the responder, each
/// with both HELLOs as they crossed, so knit-next's `IosEmittedVectorTest` can verify them with Tink and check that each
/// fails under the other role.
public struct EmittedLink: Codable, Sendable, Equatable {
    /// What the section is, for a reader who opens it cold.
    public let about: String
    /// Carol dials Alice, Carol's nonce `20..2f` and Alice's `30..3f`: Carol's dialer PROOF.
    public let carolDialsAlice: EmittedLinkProof
    /// Alice dials Carol, Alice's nonce `30..3f` and Carol's `20..2f`: Carol's responder PROOF.
    public let aliceDialsCarol: EmittedLinkProof

    /// Makes the section.
    public init(about: String, carolDialsAlice: EmittedLinkProof, aliceDialsCarol: EmittedLinkProof) {
        self.about = about
        self.carolDialsAlice = carolDialsAlice
        self.aliceDialsCarol = aliceDialsCarol
    }
}

/// One link's proof by Carol: who dialed, both HELLOs, the transcript she signed and her PROOF record.
public struct EmittedLinkProof: Codable, Sendable, Equatable {
    /// The identity that dialed: `carol` or `alice`.
    public let dialer: String
    /// The identity that answered.
    public let responder: String
    /// The identity whose PROOF this is: always `carol`.
    public let signer: String
    /// The signer's role byte: 1 when it dialed, 2 when it answered.
    public let role: UInt8
    /// The dialer's HELLO.
    public let helloDialer: VectorLink.Hello
    /// The responder's reply HELLO.
    public let helloResponder: VectorLink.Hello
    /// The signed transcript, as hex.
    public let transcript: String
    /// The PROOF record (tag 8), as hex: header, Carol's two raw keys, her signature. CryptoKit's signature is randomized,
    /// so verify it; never compare it.
    public let proof: String

    /// Makes an entry.
    public init(
        dialer: String, responder: String, signer: String, role: UInt8, helloDialer: VectorLink.Hello,
        helloResponder: VectorLink.Hello, transcript: String, proof: String
    ) {
        self.dialer = dialer
        self.responder = responder
        self.signer = signer
        self.role = role
        self.helloDialer = helloDialer
        self.helloResponder = helloResponder
        self.transcript = transcript
        self.proof = proof
    }
}
