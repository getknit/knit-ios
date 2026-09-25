import Crypto

/// SHA-256 of `text` as UTF-8, the one digest every knit-next identity derivation uses.
internal func sha256(_ text: String) -> [UInt8] {
    Array(SHA256.hash(data: Array(text.utf8)))
}

/// `count` bytes from the system's secure random source. Swift documents `SystemRandomNumberGenerator` as
/// cryptographically secure on every platform it supports, so content keys and nonces come from here and
/// never from an injected generator: a seeded generator in a test must never reach a real key.
internal func secureRandomBytes(_ count: Int) -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<count).map { _ in generator.next() }
}
