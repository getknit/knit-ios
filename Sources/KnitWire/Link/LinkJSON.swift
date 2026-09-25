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

    /// A file header's fields, or `nil` when it is not one. The MVP reads headers only to discard the file
    /// that follows.
    public static func fileHeader(from payload: [UInt8]) -> FileHeader? {
        guard let decoded = try? JSONDecoder().decode(FileHeaderJSON.self, from: Data(payload)) else {
            return nil
        }
        return FileHeader(kind: decoded.kind, key: decoded.key, mime: decoded.mime)
    }

    /// A JSON string literal, escaped per RFC 8259.
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
    /// `AVATAR` or `ATTACHMENT`; any other value is treated as an attachment.
    public var kind: String
    /// The blob's content hash, 64 lowercase hex characters.
    public var key: String
    /// The blob's type.
    public var mime: String

    /// Makes a header.
    public init(kind: String, key: String, mime: String) {
        self.kind = kind
        self.key = key
        self.mime = mime
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
