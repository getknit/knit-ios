import Crypto

/// X25519's all-zero output, the check RFC 9180 §7.1.4 asks of every exchange. Tink makes it: it refuses the low-order
/// points that cause it (`X25519.computeSharedSecret`), so Android never seals to, opens from or derives a ratchet key
/// with one (`RatchetCrypto.kt:56-60`). swift-crypto and CryptoKit skip it on purpose (`X25519Keys_boring.swift`) and
/// return zeros, so this port makes it, by one rule that v1 (``MessageCrypto``) and the ratchet (``RatchetCrypto``)
/// share.
extension SharedSecret {
    /// An X25519 output's length.
    static let x25519ByteCount = 32

    /// Whether this X25519 output is all zeros, as every exchange with a low-order point is, and no other.
    var isAllZero: Bool {
        self == [UInt8](repeating: 0, count: Self.x25519ByteCount)
    }
}

extension Curve25519.KeyAgreement.PublicKey {
    /// Whether this is a low-order point. Such a point sends every clamped scalar to zero and no other point sends any
    /// there, so one exchange with a throwaway key tells them apart. v1 asks before HPKE runs an exchange of its own,
    /// whose output it never shows us.
    func isLowOrder() throws -> Bool {
        try Curve25519.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(with: self).isAllZero
    }
}
