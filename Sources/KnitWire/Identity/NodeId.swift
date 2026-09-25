/// A node's identity on the mesh: 128 bits, written as 26 characters of lowercase RFC 4648 base32 with no
/// padding (`identity/NodeId.kt` in knit-next).
///
/// Only a canonical id round-trips, which pins its last character to one of `a e i m q u y 4`. Deriving an id
/// from a public key bundle needs SHA-256 and lives in `KnitCrypto`; this type is the id itself.
public struct NodeId: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The id's length in bytes.
    public static let byteCount = 16
    /// The id's length in characters.
    public static let length = 26
    /// The base32 alphabet, RFC 4648 lowercased.
    public static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    /// The canonical 26-character form.
    public let string: String

    /// The id for 16 raw bytes, as the advert carries them.
    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else {
            return nil
        }
        string = Base32.encode(bytes)
    }

    /// The id for its text form, if that form is canonical.
    public init?(_ text: String) {
        guard text.utf8.count == Self.length, let decoded = Base32.decode(text), decoded.count == Self.byteCount,
            Base32.encode(decoded) == text
        else {
            return nil
        }
        string = text
    }

    /// The 16 raw bytes.
    public var bytes: [UInt8] {
        // A canonical id always decodes; the fallback is unreachable.
        Base32.decode(string) ?? []
    }

    /// The id's text.
    public var description: String { string }

    /// knit-next orders ids as Kotlin strings, which for this alphabet is ASCII order: the digits 2 to 7 sort
    /// before the letters. Comparing the raw bytes would give a different answer.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.string.utf8.lexicographicallyPrecedes(rhs.string.utf8)
    }
}

/// Lowercase RFC 4648 base32 without padding, as knit-next writes node ids.
public enum Base32 {
    private static let bitsPerSymbol = 5
    private static let symbolMask = 0x1F
    private static let byteMask = 0xFF

    /// Encodes bytes, zero-padding the final symbol's low bits.
    public static func encode(_ bytes: [UInt8]) -> String {
        var symbols: [UInt8] = []
        symbols.reserveCapacity((bytes.count * UInt8.bitWidth + bitsPerSymbol - 1) / bitsPerSymbol)
        var value = 0
        var bits = 0
        for byte in bytes {
            value = (value << UInt8.bitWidth) | Int(byte)
            bits += UInt8.bitWidth
            while bits >= bitsPerSymbol {
                symbols.append(NodeId.alphabet[(value >> (bits - bitsPerSymbol)) & symbolMask])
                bits -= bitsPerSymbol
            }
            value &= (1 << bits) - 1
        }
        if bits > 0 {
            symbols.append(NodeId.alphabet[(value << (bitsPerSymbol - bits)) & symbolMask])
        }
        return String(ascii: symbols)
    }

    /// Decodes text, or `nil` if it holds a character outside the alphabet. Leftover bits are discarded, as
    /// knit-next does; callers that need a canonical form re-encode and compare.
    public static func decode(_ text: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count * bitsPerSymbol / UInt8.bitWidth)
        var value = 0
        var bits = 0
        for character in text.utf8 {
            guard let index = NodeId.alphabet.firstIndex(of: character) else {
                return nil
            }
            value = (value << bitsPerSymbol) | index
            bits += bitsPerSymbol
            if bits >= UInt8.bitWidth {
                bytes.append(UInt8((value >> (bits - UInt8.bitWidth)) & byteMask))
                bits -= UInt8.bitWidth
            }
            value &= (1 << bits) - 1
        }
        return bytes
    }
}
