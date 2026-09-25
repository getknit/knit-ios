/// Frame ids: 16 random bytes as URL-safe base64 with no padding, 22 characters (`FrameId.kt` in knit-next).
///
/// Profiles use `profile-<nodeId>-<publishedAt>` instead, so an id is opaque everywhere except where a
/// canonical one is needed.
public enum FrameId {
    /// An id's length in bytes.
    public static let byteCount = 16
    /// A canonical id's length in characters.
    public static let length = 22

    /// A fresh id, from the injected generator so a test or a chaos run can reproduce it.
    public static func generate(using generator: inout some RandomNumberGenerator) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(byteCount)
        while bytes.count < byteCount {
            let word: UInt64 = generator.next()
            for shift in stride(from: 0, to: UInt64.bitWidth, by: UInt8.bitWidth) where bytes.count < byteCount {
                bytes.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
        return text(for: bytes)
    }

    /// The id for 16 bytes.
    public static func text(for bytes: [UInt8]) -> String {
        precondition(bytes.count == byteCount, "a frame id is \(byteCount) bytes, got \(bytes.count)")
        return Base64.encode(bytes, variant: .urlSafeUnpadded)
    }

    /// The 16 bytes of a canonical id, or `nil` for any other string.
    public static func bytes(of id: String) -> [UInt8]? {
        guard id.utf8.count == length, let bytes = Base64.decode(id, variant: .urlSafeUnpadded), bytes.count == byteCount,
            Base64.encode(bytes, variant: .urlSafeUnpadded) == id
        else {
            return nil
        }
        return bytes
    }
}

/// The key a Bluetooth link uses to remember which frames crossed it (`FrameKey.kt` in knit-next): the first
/// eight signature bytes as lowercase hex, or `u:<id>` for an unsigned frame.
public enum FrameKey {
    private static let signatureBytes = 8

    /// The key for a frame.
    public static func of(_ wire: WireEnvelope, _ envelope: RelayEnvelope) -> String {
        ofSigned(wire) ?? "u:\(envelope.id)"
    }

    /// The key for a frame whose envelope was not decoded, or `nil` when it is unsigned (`FrameKey.ofSigned`). An
    /// unsigned frame is point to point and never fanned out, so a send skips the memo for it.
    public static func ofSigned(_ wire: WireEnvelope) -> String? {
        wire.sig.isEmpty ? nil : Hex.encode(Array(wire.sig.prefix(signatureBytes)))
    }
}

/// Lowercase hexadecimal, the form knit-next writes hashes, device tags and frame keys in.
public enum Hex {
    private static let digits = Array("0123456789abcdef".utf8)
    private static let nibbleBits: UInt8 = 4
    private static let nibbleMask: UInt8 = 0x0F
    private static let digitsPerByte = 2

    /// Encodes bytes as lowercase hex.
    public static func encode(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count * digitsPerByte)
        for byte in bytes {
            output.append(digits[Int(byte >> nibbleBits)])
            output.append(digits[Int(byte & nibbleMask)])
        }
        return String(ascii: output)
    }

    /// Decodes lowercase hex, or `nil` for odd lengths and other characters.
    public static func decode(_ text: String) -> [UInt8]? {
        let symbols = Array(text.utf8)
        guard symbols.count.isMultiple(of: digitsPerByte) else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(symbols.count / digitsPerByte)
        var index = 0
        while index < symbols.count {
            guard let high = digits.firstIndex(of: symbols[index]), let low = digits.firstIndex(of: symbols[index + 1]) else {
                return nil
            }
            bytes.append(UInt8(high) << nibbleBits | UInt8(low))
            index += digitsPerByte
        }
        return bytes
    }
}

/// The custody digest fold (`StoreDigest.kt` in knit-next): FNV-1a-64 over each id's UTF-8 bytes, XORed across
/// the set. The advert carries its low 32 bits.
public enum StoreDigest {
    private static let offsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01B3

    /// FNV-1a-64 of one id.
    public static func hash(_ id: String) -> UInt64 {
        var hash = offsetBasis
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return hash
    }

    /// The fold over a set of ids; order does not matter.
    public static func fingerprint(of ids: some Sequence<String>) -> UInt64 {
        ids.reduce(0) { $0 ^ hash($1) }
    }
}
