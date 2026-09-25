/// RFC 4648 base64 in the two forms knit-next uses: standard with padding (public key bundles, attachment
/// keys) and URL-safe without padding (frame ids).
///
/// Decoding is strict in the way `java.util.Base64` is: a character outside the alphabet fails. Callers that
/// need the canonical form (a bundle, a frame id) re-encode and compare, as knit-next does.
public enum Base64 {
    /// Which alphabet and padding rule to use.
    public enum Variant: Sendable {
        /// `A–Z a–z 0–9 + /`, padded with `=`.
        case standard
        /// `A–Z a–z 0–9 - _`, unpadded.
        case urlSafeUnpadded
    }

    private static let standardAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    private static let urlAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
    private static let pad = UInt8(ascii: "=")
    private static let groupBytes = 3
    private static let groupSymbols = 4
    private static let bitsPerSymbol = 6
    private static let symbolMask: UInt32 = 0x3F

    /// Encodes bytes.
    public static func encode(_ bytes: [UInt8], variant: Variant = .standard) -> String {
        let alphabet = variant == .standard ? standardAlphabet : urlAlphabet
        var output: [UInt8] = []
        output.reserveCapacity((bytes.count + groupBytes - 1) / groupBytes * groupSymbols)
        var index = 0
        while index < bytes.count {
            let chunk = bytes[index..<min(index + groupBytes, bytes.count)]
            var group: UInt32 = 0
            for (offset, byte) in chunk.enumerated() {
                group |= UInt32(byte) << UInt32((groupBytes - 1 - offset) * UInt8.bitWidth)
            }
            let symbols = chunk.count + 1
            for position in 0..<symbols {
                let shift = UInt32((groupSymbols - 1 - position) * bitsPerSymbol)
                output.append(alphabet[Int((group >> shift) & symbolMask)])
            }
            if variant == .standard {
                output += Array(repeating: pad, count: groupSymbols - symbols)
            }
            index += groupBytes
        }
        return String(ascii: output)
    }

    /// Decodes text, or `nil` if it is not valid for the variant.
    public static func decode(_ text: String, variant: Variant = .standard) -> [UInt8]? {
        let alphabet = variant == .standard ? standardAlphabet : urlAlphabet
        var symbols = Array(text.utf8)
        if variant == .standard {
            while symbols.last == pad {
                symbols.removeLast()
            }
            // Padding is optional, but when present it completes the final group with exactly the one or two
            // symbols that group lacks. `java.util.Base64` refuses `QUJD=` and `QQ=`, and so does this.
            let padding = text.utf8.count - symbols.count
            guard padding == 0 || (padding < groupSymbols - 1 && (symbols.count + padding).isMultiple(of: groupSymbols)) else {
                return nil
            }
        }
        guard symbols.count % groupSymbols != 1 else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(symbols.count * bitsPerSymbol / UInt8.bitWidth)
        var value: UInt32 = 0
        var bits = 0
        for symbol in symbols {
            guard let index = alphabet.firstIndex(of: symbol) else {
                return nil
            }
            value = (value << UInt32(bitsPerSymbol)) | UInt32(index)
            bits += bitsPerSymbol
            if bits >= UInt8.bitWidth {
                bits -= UInt8.bitWidth
                bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(bits)))
                value &= (1 << UInt32(bits)) - 1
            }
        }
        return bytes
    }
}
