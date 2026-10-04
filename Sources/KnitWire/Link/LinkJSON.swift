import Foundation

/// The two link records whose payload is JSON rather than CBOR (`LinkFraming.kt` in knit-next). They are
/// never signed, so a JSON codec is safe here; the CBOR types never use one.
public enum LinkJSON {
    /// A custody digest's payload, `{"ids":[…]}`, compact, as kotlinx's `Json` writes it.
    public static func digestPayload(ids: [String]) -> [UInt8] {
        var output = Array(#"{"ids":["#.utf8)
        for (index, id) in ids.enumerated() {
            if index > 0 {
                output.append(UInt8(ascii: ","))
            }
            output += quoted(id)
        }
        output += Array("]}".utf8)
        return output
    }

    /// The ids in a digest payload, or `nil` when it is not one. Android ignores an undecodable digest, and so
    /// does the link session.
    public static func digestIds(from payload: [UInt8]) -> [String]? {
        (try? JSONDecoder().decode(DigestJSON.self, from: Data(payload)))?.ids
    }

    /// A file header's payload, `{"kind":…,"key":…,"mime":…,"size":…}`, compact and in that order, as kotlinx's `Json`
    /// writes `FileHeaderWire` (`LinkFraming.encodeFileHeader`, `LinkFraming.kt:150-195`). A header with no size is the
    /// three keys every build before knit-next ADR 2026-10.y9qh wrote; a sender always fills it.
    public static func fileHeaderPayload(_ header: FileHeader) -> [UInt8] {
        var output = Array(#"{"kind":"#.utf8) + quoted(header.kind.rawValue) + Array(#","key":"#.utf8) + quoted(header.key)
        output += Array(#","mime":"#.utf8) + quoted(header.mime)
        if let size = header.size {
            output += Array(#","size":"#.utf8) + Array(String(size).utf8)
        }
        output.append(UInt8(ascii: "}"))
        return output
    }

    /// A file header's fields, or `nil` when it is not one (`LinkFraming.decodeFileHeader`): all three keys present as
    /// strings, in any order, with unknown keys ignored. Android drops the file after a header it cannot read and keeps
    /// the link (`FramedLink.kt:404-410`). A size that is not an integer is read as none, so it costs the label and
    /// never the file.
    public static func fileHeader(from payload: [UInt8]) -> FileHeader? {
        let data = Data(payload)
        guard let decoded = try? JSONDecoder().decode(FileHeaderJSON.self, from: data) else {
            return nil
        }
        // Decoded apart, as Android falls back to `FileHeaderCore`: a failed header aborts the file behind it.
        let size = (try? JSONDecoder().decode(FileHeaderSizeJSON.self, from: data))?.size
        return FileHeader(kind: FileHeader.Kind(wire: decoded.kind), key: decoded.key, mime: decoded.mime, size: size)
    }

    /// A JSON string literal, escaped as kotlinx's `Json` escapes one (`ESCAPE_STRINGS` in its `StringOps.kt`): the
    /// quote, the backslash and the five short forms, and any other control character as a lowercase `\u` escape.
    private static func quoted(_ text: String) -> [UInt8] {
        let controlLimit: UInt32 = 0x20
        let hexWidth = 4
        let hexRadix = 16
        var output: [UInt8] = [UInt8(ascii: "\"")]
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"":
                output += Array(#"\""#.utf8)
            case "\\":
                output += Array(#"\\"#.utf8)
            case "\n":
                output += Array(#"\n"#.utf8)
            case "\r":
                output += Array(#"\r"#.utf8)
            case "\t":
                output += Array(#"\t"#.utf8)
            case "\u{8}":
                output += Array(#"\b"#.utf8)
            case "\u{C}":
                output += Array(#"\f"#.utf8)
            default:
                if scalar.value < controlLimit {
                    let hex = String(scalar.value, radix: hexRadix)
                    output += Array(#"\u"#.utf8) + Array(repeating: UInt8(ascii: "0"), count: hexWidth - hex.count) + Array(hex.utf8)
                } else {
                    output += Array(String(scalar).utf8)
                }
            }
        }
        output.append(UInt8(ascii: "\""))
        return output
    }
}

/// A file record's header (`FileHeaderWire` in knit-next).
public struct FileHeader: Sendable, Equatable {
    /// What a file is (`FileKind`, `MeshTransport.kt:108-123`). The tokens are frozen.
    public enum Kind: String, Sendable {
        /// The sender's own profile photo, pushed at link-up.
        case avatar = "AVATAR"
        /// Any other blob: a photo in a chat, a group's photo, or a profile photo served on request.
        case attachment = "ATTACHMENT"

        /// The kind a token names. Any token but `AVATAR`, compared by its bytes, is an attachment, as on Android
        /// (`entries.firstOrNull { it.wire == token } ?: ATTACHMENT`).
        public init(wire token: String) {
            self = token.utf8.elementsEqual(Self.avatar.rawValue.utf8) ? .avatar : .attachment
        }
    }

    /// What the file is.
    public var kind: Kind
    /// The blob's content hash: 64 lowercase hex characters from an honest sender. The receiver checks it when the
    /// file ends (``FileIntake``).
    public var key: String
    /// The blob's type.
    public var mime: String
    /// The length of the stream that follows, as its sender declared it, so the receiver can show how far it has got
    /// (knit-next ADR 2026-10.y9qh). The sender's claim: a label, never a bound. `nil` from a build before the field.
    public var size: Int?

    /// Makes a header.
    public init(kind: Kind, key: String, mime: String, size: Int? = nil) {
        self.kind = kind
        self.key = key
        self.mime = mime
        self.size = size
    }
}

private struct DigestJSON: Decodable {
    let ids: [String]
}

private struct FileHeaderJSON: Decodable {
    let kind: String
    let key: String
    let mime: String
}

private struct FileHeaderSizeJSON: Decodable {
    let size: Int?
}
