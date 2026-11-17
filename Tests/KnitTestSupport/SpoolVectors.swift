import KnitWire

/// knit-next's spool vectors (ADR 2026-11.adrq), read by `scripts/sync-vectors.py` out of `docs/SPOOL_PROTOCOL.md` §13 and
/// `docs/RELAY_INVITE.md` §5 into `Tests/Vectors/spool-v1.json`: each §13 block a text-only client checks, by the label
/// that opens it, every HELLO variant, and the invite links.
public enum SpoolVectors {
    /// The file's name in `Tests/Vectors/`.
    public static let fileName = "spool-v1.json"

    /// The file's shape.
    public struct File: Decodable, Sendable {
        /// §13's blocks by label (`Inputs`, `Derivations`, `Pair scope`, `Seal`, `Digest`, `PoW`, `Records`), each row's
        /// value lowercase hex, or a quoted string for a node id or a group id.
        public let scope: [String: [String: String]]
        /// Every HELLO a later section adds, by name, as hex.
        public let helloVariants: [String: String]
        /// The invite links by name.
        public let relayInvite: [String: Invite]
    }

    /// One invite link and what it holds.
    public struct Invite: Decodable, Sendable {
        /// The compact invite, base64url.
        public let link: String
        /// The relay URL it carries, `u`.
        public let url: String
        /// Whether it carries a commons secret, `c`.
        public let hasSecret: Bool
        /// The room's name, `n`, if any.
        public let name: String?
        /// Whether it carries an issuer, `i`.
        public let hasIssuer: Bool
        /// Whether it carries a customer key, `k`.
        public let hasKey: Bool

        private enum CodingKeys: String, CodingKey {
            case link = "link"
            case url = "u"
            case hasSecret = "c"
            case name = "n"
            case hasIssuer = "i"
            case hasKey = "k"
        }
    }

    /// The file, read once.
    public static let file = VectorFile.read(fileName, as: File.self)

    /// A row's text, as written.
    public static func text(_ section: String, _ name: String) -> String {
        guard let value = file.scope[section]?[name] else {
            fatalError("\(fileName) has no \(section).\(name); run scripts/sync-vectors.py")
        }
        return value
    }

    /// A row's bytes.
    public static func bytes(_ section: String, _ name: String) -> [UInt8] {
        guard let bytes = Hex.decode(text(section, name)) else {
            fatalError("\(fileName)'s \(section).\(name) is not hex")
        }
        return bytes
    }

    /// A §13 record's bytes.
    public static func record(_ name: String) -> [UInt8] {
        bytes("Records", name)
    }

    /// The spec's byte-array fixture, `fixture(n, seed)[i] = (7·i + seed) mod 256` (knit-next's `bytes(n, seed)`).
    public static func fixture(_ count: Int, seed: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: 7 * $0 + seed) }
    }
}
