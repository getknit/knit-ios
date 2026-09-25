/// Why signing or sealing produced nothing. Opening and verifying never throw: they answer `nil` or `false`.
public enum CryptoFailure: Error, Sendable, Equatable {
    /// The crypto library refused to sign.
    case signing
    /// A recipient's key would not take a wrapped key, or the body would not seal. A peer's X25519 key that is a
    /// low-order point does this.
    case sealing
}
