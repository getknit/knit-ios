#if os(iOS) && DEBUG
    import CoreFoundation
    import Foundation

    /// The charsets a page may name that the parser's own decoders do not read, through CFString's IANA names (ADR
    /// 2026-11.hcvg): Shift_JIS, GBK, EUC-KR and the rest. Bytes the charset does not read give `nil`, and the parser
    /// tries the next source, as a name Android's runtime does not know does.
    internal enum CoreCharsets {
        /// `bytes` read as `name`, or `nil`.
        static func decode(_ name: String, _ bytes: [UInt8]) -> String? {
            let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard encoding != kCFStringEncodingInvalidId else {
                return nil
            }
            return String(bytes: bytes, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding)))
        }
    }
#endif
