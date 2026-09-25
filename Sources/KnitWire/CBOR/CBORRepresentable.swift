/// A wire type with a hand-written CBOR mapping.
///
/// Each conforming type writes its fields in the declaration order of its Kotlin counterpart and omits
/// every field equal to its default, which is what kotlinx does with `encodeDefaults = false`. Decoding
/// ignores unknown keys, so the wire can grow additively.
public protocol CBORRepresentable: Sendable {
    /// Reads the value from a decoded CBOR item.
    init(cbor: CBOR) throws(WireDecodingError)

    /// The value as a CBOR item, ready to encode.
    var cbor: CBOR { get }
}

extension CBORRepresentable {
    /// Decodes the value from its bytes.
    public init(decoding bytes: [UInt8]) throws(WireDecodingError) {
        let item: CBOR
        do {
            item = try CBOR.decode(bytes)
        } catch {
            throw .cbor(error)
        }
        try self.init(cbor: item)
    }

    /// The value's bytes.
    public var encoded: [UInt8] { cbor.encoded }
}
