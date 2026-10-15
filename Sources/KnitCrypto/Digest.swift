import Crypto
import Foundation

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

/// A copy of the bytes of a key or a shared secret, which swift-crypto and CryptoKit hand out only through a pointer.
/// The ratchet keeps its keys as raw bytes, as knit-next's does (`RatchetCrypto.kt`), so every derivation ends here.
internal func copiedBytes(_ value: some ContiguousBytes) -> [UInt8] {
    // Sound: the buffer is valid for the closure's duration, and `Array(_:)` copies every byte out before it returns,
    // so no pointer outlives the call.
    unsafe value.withUnsafeBytes { unsafe Array($0) }
}
