public import Foundation

/// The JSON files in `Tests/Vectors/`. `scripts/sync-vectors.py` copies `wire-v1.json` and `keyed-v1.json` from
/// knit-next's `vectors/`; `ios-emitted-v1.json` is written here and copied the other way.
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
        wire: String
    ) {
        self.sender = sender
        self.recipient = recipient
        self.groupId = groupId
        self.members = members
        self.name = name
        self.body = body
        self.wire = wire
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

/// knit-next's link vectors: the HELLO and DIGEST records, the custody fingerprint and an advert.
public struct VectorLink: Decodable, Sendable {
    /// A HELLO record and its text payload.
    public struct Hello: Decodable, Sendable {
        /// `nodeId|version|capsHex`.
        public let payload: String
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
    /// The advert.
    public let advert: Advert
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
        /// `aliceProfile`, `aliceRoomPost` and `aliceDmToBob`.
        public let frames: [String: VectorFrame]
        /// The link vectors.
        public let link: VectorLink
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
    /// `carolProfile`, `carolRoomPost` and `carolDmToBob`.
    public let frames: [String: VectorFrame]

    /// Makes the file's content.
    public init(about: String, identities: [String: VectorIdentity], safetyNumber: VectorSafetyNumber, frames: [String: VectorFrame]) {
        self.about = about
        self.identities = identities
        self.safetyNumber = safetyNumber
        self.frames = frames
    }

    /// The committed file, or `nil` before it has been written.
    public static var committed: Self? {
        guard FileManager.default.fileExists(atPath: VectorFile.directory.appendingPathComponent(fileName).path) else {
            return nil
        }
        return VectorFile.read(fileName, as: Self.self)
    }
}
