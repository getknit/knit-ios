import Crypto

/// An RFC 5869 HKDF-SHA256 built on HMAC alone, extract then expand, as knit-next's `RatchetCryptoTest.referenceHkdf`
/// builds one on `javax.crypto.Mac`. Deriving the same bytes through this and through `HKDF<SHA256>` pins every call's
/// argument order: the salt keys the extract, and the input key material is what it authenticates.
func referenceHKDF(ikm: [UInt8], salt: [UInt8], info: [UInt8], count: Int) -> [UInt8] {
    let prk = hmac(key: salt, data: ikm)
    var output: [UInt8] = []
    var previous: [UInt8] = []
    var counter: UInt8 = 1
    while output.count < count {
        previous = hmac(key: prk, data: previous + info + [counter])
        output += previous.prefix(count - output.count)
        counter += 1
    }
    return output
}

private func hmac(key: [UInt8], data: [UInt8]) -> [UInt8] {
    Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
}

/// knit-next's `deterministicBytes(seed)` in `RatchetCryptoTest` and `GroupRatchetCryptoTest`: 32 bytes,
/// `(31 i + 131 seed) & 0xFF`.
func deterministicBytes(_ seed: Int) -> [UInt8] {
    (0..<32).map { UInt8(truncatingIfNeeded: $0 * 31 + seed * 131) }
}

/// 32 zero bytes, the ratchet's zero salt.
let zeroSalt = [UInt8](repeating: 0, count: 32)
