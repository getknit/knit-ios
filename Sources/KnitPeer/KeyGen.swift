public import KnitCrypto
public import KnitWire

/// Makes an identity whose node id sorts inside a window: `knit-peer keygen --above/--below`, so an interop run can
/// put the peer on either side of a phone and check both dial orders (MVP item 2). Both bounds together put it
/// between two phones: below the one that should dial it, and above the rest, which then never do.
public enum KeyGen {
    /// Where the new node id must sort, as node ids compare: as ASCII strings, the order Android's tie-break uses.
    public struct Window: Equatable, Sendable {
        /// The id must sort above this one.
        public var above: NodeId?
        /// The id must sort below this one.
        public var below: NodeId?

        /// A window between `above` and `below`, either of which may be open.
        public init(above: NodeId? = nil, below: NodeId? = nil) {
            self.above = above
            self.below = below
        }

        /// Whether `nodeId` is inside the window, bounds excluded.
        public func contains(_ nodeId: NodeId) -> Bool {
            (above.map { nodeId > $0 } ?? true) && (below.map { nodeId < $0 } ?? true)
        }
    }

    /// Why no identity was made.
    public enum Failure: Error, Equatable, Sendable {
        /// Nothing landed inside the window in the attempts allowed: it is empty or too narrow.
        case noRoom(attempts: Int)
    }

    /// How many identities to try. A window between two phones' ids is rarely narrower than a few percent of the
    /// order, so the limit only stops the hopeless case.
    public static let attempts = 100_000

    /// The first identity from `generate` whose node id sorts inside `window`.
    public static func identity(
        in window: Window,
        attempts: Int = attempts,
        generate: () -> IdentityKeys = IdentityKeys.generate
    ) throws(Failure) -> IdentityKeys {
        for _ in 0..<attempts {
            let keys = generate()
            if window.contains(keys.nodeId) {
                return keys
            }
        }
        throw .noRoom(attempts: attempts)
    }
}
