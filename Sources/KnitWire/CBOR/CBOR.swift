/// One CBOR data item (RFC 8949), in the shape knit-next's kotlinx-serialization codec writes and reads.
///
/// Map entries keep their wire order. The encoder writes them back in that order, which is what lets a
/// decoded item round-trip byte for byte, and what lets a typed encoder match kotlinx's
/// declaration-order keys.
public indirect enum CBOR: Sendable, Hashable {
    /// A non-negative integer, major type 0.
    case unsigned(UInt64)
    /// A negative integer, major type 1, holding `n` for the value `-1 - n` exactly as the wire encodes it.
    case negative(UInt64)
    /// A byte string, major type 2.
    case bytes([UInt8])
    /// A UTF-8 text string, major type 3.
    case text(String)
    /// An array, major type 4.
    case array([Self])
    /// A map, major type 5, with its entries in wire order. Decoded, an empty one is only ever the byte `A0`.
    case map([Entry])
    /// An empty map written any way but `A0`: with a wider length argument (`B8 00`, `B9 0000`, `BA 00000000`,
    /// `BB 0000000000000000`) or in the indefinite form (`BF FF`). Only ``decode(_:limits:)`` makes one, and the encoder
    /// writes it as `A0`, as it writes every other item in its shortest form.
    ///
    /// kotlinx-cbor 1.12.0 reads a nullable field as null when its first byte is `F6` or `A0` (`isNull`, `Decoder.kt:193`),
    /// so this one is not null: it goes to the field's decoder, as any map does (knit-ios #14).
    case longFormEmptyMap
    /// A tagged item, major type 6. knit-next never writes tags; the typed layer skips them before every value and
    /// every key, as kotlinx-cbor 1.12.0 does when a class declares none (`processTags`, `Decoder.kt:304-334`).
    case tagged(UInt64, Self)
    /// A simple value other than the named ones below, major type 7.
    case simple(UInt8)
    /// `false` (`F4`) or `true` (`F5`).
    case bool(Bool)
    /// `null` (`F6`).
    case null
    /// `undefined` (`F7`).
    case undefined
    /// A half-, single- or double-precision float, widened to `Double`.
    case float(Double)

    /// One key and value of a ``CBOR/map(_:)``.
    public struct Entry: Sendable, Hashable {
        /// The entry's key; knit-next's named layouts only ever use text keys.
        public let key: CBOR
        /// The entry's value.
        public let value: CBOR

        /// Makes an entry from a key and its value.
        public init(key: CBOR, value: CBOR) {
            self.key = key
            self.value = value
        }
    }
}

extension CBOR {
    /// The item for a signed integer, choosing the major type the way every CBOR encoder must.
    public init(_ value: Int64) {
        self = value >= 0 ? .unsigned(UInt64(value)) : .negative(UInt64(-(value + 1)))
    }

    /// The item under every leading tag, as kotlinx's `processTags` skips a run of them before it reads a value or a key
    /// (`Decoder.kt:307-318`).
    var untagged: Self {
        var item = self
        while case .tagged(_, let inner) = item {
            item = inner
        }
        return item
    }

    /// The integer this item holds, if it is an integer that fits in `Int64`.
    public var int64: Int64? {
        switch self {
        case .unsigned(let value):
            value <= UInt64(Int64.max) ? Int64(value) : nil
        case .negative(let magnitude):
            magnitude <= UInt64(Int64.max) ? -1 - Int64(magnitude) : nil
        default:
            nil
        }
    }
}
