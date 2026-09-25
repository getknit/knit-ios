public import KnitWire

extension NodeId {
    private static let derivationSalt = "knit-node-id-v2:"

    /// knit-next's `NodeId.derive`: base32 of the first 16 bytes of SHA-256 of `"knit-node-id-v2:" + seed`.
    ///
    /// The seed that matters is a public key bundle's base64 text (``PublicKeyBundle/nodeId``). That makes an
    /// id self-certifying: only whoever holds a bundle's private keys can sign as the id it derives to.
    public init(deriving seed: String) {
        let digest = sha256(Self.derivationSalt + seed)
        guard let id = Self(bytes: Array(digest.prefix(Self.byteCount))) else {
            preconditionFailure("SHA-256 yields 32 bytes, and any 16 bytes are a node id")
        }
        self = id
    }
}
