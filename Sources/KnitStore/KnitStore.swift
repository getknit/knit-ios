/// The repositories the mesh reads and writes, as protocols, with in-memory implementations for the Linux peer
/// and the tests. The SQL store (P5) implements the same protocols; custody applies the same ``CustodyRules``.
public enum KnitStore {
    /// The schema generation the SQL store will freeze as its v1 baseline.
    public static let schemaVersion = 1
}
