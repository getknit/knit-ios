public import KnitWire

/// knit-next's codec vectors, `vectors/wire-v1.json`, copied into `Tests/Vectors/` by `scripts/sync-vectors.py`.
///
/// This target holds what more than one test target reads. It is not a product, and xtool never builds it.
public enum GoldenVectors {
    /// The JSON file's shape.
    public struct File: Decodable, Sendable {
        /// Where the vectors came from.
        public struct Source: Decodable, Sendable {
            /// The knit-next commit.
            public let commit: String
        }

        /// GoldenVectorTest's raw-key bundle probe: `sigPub = bytes(32, 10)`, `hpkePub = bytes(32, 20)`.
        public struct Bundle: Decodable, Sendable {
            /// The bundle's base64.
            public let encoded: String
            /// The node id derived from it.
            public let nodeId: String
        }

        /// Where the vectors came from.
        public let source: Source
        /// Each fixture's name and its expected bytes, as hex.
        public let vectors: [String: String]
        /// The bundle probe.
        public let bundle: Bundle
    }

    /// The file, read once.
    public static let file = VectorFile.read("wire-v1.json", as: File.self)

    /// Every fixture's name, sorted.
    public static var names: [String] { file.vectors.keys.sorted() }

    /// A fixture's expected bytes.
    public static func bytes(_ name: String) -> [UInt8] {
        guard let hex = file.vectors[name], let bytes = Hex.decode(hex) else {
            fatalError("no golden vector named \(name)")
        }
        return bytes
    }
}

/// knit-next's generated test input, `bytes(n, seed)[i] = (7 * i + seed) & 0xFF`, which GoldenVectorTest and
/// ContactCardTest both use.
public func fixtureBytes(_ count: Int, seed: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: $0 * 7 + seed) }
}

/// GoldenVectorTest's `frameId(seed)`.
public func fixtureFrameId(_ seed: Int) -> String {
    FrameId.text(for: fixtureBytes(FrameId.byteCount, seed: seed))
}

/// GoldenVectorTest's `nodeId(seed)`: the node id of `bytes(16, seed)`.
public func fixtureNodeId(_ seed: Int) -> NodeId {
    guard let id = NodeId(bytes: fixtureBytes(NodeId.byteCount, seed: seed)) else {
        fatalError("any 16 bytes are a node id")
    }
    return id
}
