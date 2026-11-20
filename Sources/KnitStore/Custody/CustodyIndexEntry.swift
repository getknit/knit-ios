public import KnitWire

/// One live custody row as a digest answer picks from it (``CustodyStore/liveIndex(now:)``): what the pick reads, with
/// nothing decoded from the frame's bytes (ADR 2026-10.f5zs).
///
/// A reply round once read and decoded every live row, up to the 1,000 custody holds, for each digest a neighbour sent,
/// however empty. The round now picks from this index and loads only the frames it serves.
public struct CustodyIndexEntry: Sendable, Equatable {
    /// The frame's id.
    public var id: String
    /// Its sender's id, as the envelope names it.
    public var senderId: String
    /// Its recipient's id, or `nil` for a frame addressed to nobody: a round serves a frame addressed to the asking peer in
    /// its second tier (the `custody-carry-policy` contract, §1).
    public var recipientId: String?
    /// Its type.
    public var type: FrameType
    /// Its group's id, or `nil` for a DM or a room frame. A group frame goes to any peer that lacks it (knit-next ADR
    /// 2026-10.hr9f); its roster, which orders it in a round's third tier, is the engine's memo, never loaded to pick one.
    public var groupId: String?
    /// The originator's clock: the order of a round's second and third tiers, the same on every node.
    public var sentAt: Int64
    /// The key a link remembers it by (``FrameKey/ofSigned(_:)``), or `nil` for an unsigned row.
    public var frameKey: String?
    /// The bytes its re-serve encodes to (``CarriedFrame/reserved``'s `encoded`), as `LinkManager.send` writes it.
    public var reservedBytes: Int

    /// Makes an entry.
    public init(
        id: String, senderId: String, recipientId: String?, type: FrameType, groupId: String?, sentAt: Int64, frameKey: String?,
        reservedBytes: Int
    ) {
        self.id = id
        self.senderId = senderId
        self.recipientId = recipientId
        self.type = type
        self.groupId = groupId
        self.sentAt = sentAt
        self.frameKey = frameKey
        self.reservedBytes = reservedBytes
    }

    /// The entry for a frame held in memory.
    public init(_ frame: CarriedFrame) {
        self.init(
            id: frame.envelope.id,
            senderId: frame.envelope.senderId,
            recipientId: frame.envelope.recipientId,
            type: frame.envelope.type,
            groupId: frame.envelope.group?.id,
            sentAt: frame.envelope.sentAt,
            frameKey: Self.frameKey(sigHead: frame.sig),
            reservedBytes: Self.reservedBytes(sig: frame.sig.count, signed: frame.signed.count)
        )
    }

    /// The link key of a frame whose signature starts with `sigHead`, at least the eight bytes the key reads, or all of a
    /// shorter one: the same string ``FrameKey/ofSigned(_:)`` gives for the whole frame.
    public static func frameKey(sigHead: [UInt8]) -> String? {
        FrameKey.ofSigned(WireEnvelope(sig: sigHead, signed: []))
    }

    /// The length of a fresh re-serve's encoding (``WireEnvelope/cbor`` with `ttl` 8, `hops` 0 and `relay` left out as
    /// defaults) around a `sig` and `signed` of these lengths: a two-entry map of the text keys `sig` and `signed`, each
    /// a byte string with the shortest header that holds its length.
    public static func reservedBytes(sig: Int, signed: Int) -> Int {
        let mapHeader = 1
        let sigKey = 1 + "sig".utf8.count
        let signedKey = 1 + "signed".utf8.count
        return mapHeader + sigKey + header(sig) + sig + signedKey + header(signed) + signed
    }

    /// A CBOR byte string's header for `length` bytes: the argument inline below 24, else in one, two, four or eight
    /// bytes after the initial byte, the shortest that holds it (`CBOR.encoded`).
    private static func header(_ length: Int) -> Int {
        let initialByte = 1
        let immediateLimit = 24
        switch length {
        case ..<immediateLimit:
            return initialByte
        case ...Int(UInt8.max):
            return initialByte + MemoryLayout<UInt8>.size
        case ...Int(UInt16.max):
            return initialByte + MemoryLayout<UInt16>.size
        case ...Int(UInt32.max):
            return initialByte + MemoryLayout<UInt32>.size
        default:
            return initialByte + MemoryLayout<UInt64>.size
        }
    }
}
