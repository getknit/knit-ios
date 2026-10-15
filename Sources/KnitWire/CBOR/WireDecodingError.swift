/// Why bytes that are well-formed CBOR are still not the wire type they claim to be.
///
/// These mirror the cases in which knit-next's kotlinx decoder throws, so a frame Android would drop is one
/// we drop too.
public enum WireDecodingError: Error, Sendable, Equatable {
    /// The bytes were not one well-formed CBOR item.
    case cbor(CBORError)
    /// A named-layout type was not encoded as a map.
    case notAMap(type: String)
    /// A named-layout map had a key that is not text, or a labelled one (``MessageContentV2``) a key that is neither
    /// text nor an unsigned label.
    case nonTextKey(type: String)
    /// A field with no default was absent.
    case missingField(type: String, field: String)
    /// A field that is not nullable was present as `null`.
    case unexpectedNull(type: String, field: String)
    /// A field held the wrong kind of value, or an integer outside its Kotlin type's range.
    case invalidValue(type: String, field: String)
}
