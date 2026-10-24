/// Frame ids: 16 random bytes as URL-safe base64 with no padding, 22 characters (`FrameId.kt` in knit-next).
///
/// Profiles use `profile-<nodeId>-<publishedAt>` instead (``profileId(sender:publishedAt:)``), and Android's walkie
/// chunks, `talk`, the first ``talkLength`` characters of a fresh id.
///
/// **Not opaque on the way in** (knit-next ADR 2026-10.9qr4, knit-next #178, mirrored from knit-next `a81f2050`). The
/// router refuses a frame whose id is not the shape its type is minted with (``admits(_:)``), so changing this format,
/// or minting any other shape, is a wire break: every build of either platform that ships before the change drops the
/// new ids unseen. Android needs the gate because its database binds every id as UTF-16 and SQLite drops one leading
/// U+FEFF there, so `"\u{FEFF}" + X` took `X`'s rows. This port keeps every byte (ADR 2026-09.jc2x) and never had the
/// collision, but a frame Android refuses and this port custodies is re-served to every Android neighbour at every
/// exchange for its custody life, so both refuse the same ids at the same door. Past the door an id is opaque again:
/// it is compared by its bytes (`ExactKey`) and never parsed.
public enum FrameId {
    /// An id's length in bytes.
    public static let byteCount = 16
    /// A canonical id's length in characters.
    public static let length = 22
    /// A walkie chunk's id length in characters, all base64url: the prefix of a fresh id Android's `talk` carries
    /// (`TALK_LENGTH`, `FrameId.kt:33` at knit-next `a81f2050`). This port neither sends nor opens one.
    public static let talkLength = 11

    private static let urlAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

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
            Base64.encode(bytes, variant: .urlSafeUnpadded).utf8.elementsEqual(id.utf8)
        else {
            return nil
        }
        return bytes
    }

    /// The id of `sender`'s profile published at `publishedAt`, which is also the frame's `sentAt`
    /// (`FrameId.profileId`, `FrameId.kt:80` at knit-next `a81f2050`). A negative stamp prints its sign, so
    /// `profile-<node>--5` is a profile id.
    public static func profileId(sender: String, publishedAt: Int64) -> String {
        "profile-\(sender)-\(publishedAt)"
    }

    /// Whether an inbound frame's id is the shape its type is minted with: the gate the router asks before it meters,
    /// dedups, delivers, custodies or relays anything (`FrameId.admits`, `FrameId.kt:72` at knit-next `a81f2050`).
    ///
    /// - a `profile`: exactly ``profileId(sender:publishedAt:)`` of its sender and `sentAt`, the sender a canonical
    ///   node id, so nobody files a frame under another node's profile id;
    /// - a `talk`: exactly ``talkLength`` base64url characters;
    /// - anything else, an unknown type included: a canonical frame id (``bytes(of:)``).
    ///
    /// Every admitted shape is ASCII. The id is compared and measured by its UTF-8 bytes: Swift's `==` is canonical
    /// equivalence, which calls a Kelvin sign a `K`, and `count` counts graphemes (ADR 2026-09.jc2x).
    public static func admits(_ envelope: RelayEnvelope) -> Bool {
        switch envelope.type {
        case .profile:
            NodeId(envelope.senderId) != nil
                && envelope.id.utf8.elementsEqual(profileId(sender: envelope.senderId, publishedAt: envelope.sentAt).utf8)
        case .talk:
            envelope.id.utf8.count == talkLength && envelope.id.utf8.allSatisfy(urlAlphabet.contains)
        default:
            bytes(of: envelope.id) != nil
        }
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
