/// Why a byte sequence is not one well-formed CBOR item.
///
/// Every input off the radio is hostile until proven otherwise, so the decoder reports these instead of
/// trapping, and a caller drops the frame.
public enum CBORError: Error, Sendable, Equatable {
    /// The input ended inside an item.
    case truncated
    /// A complete item was followed by more bytes.
    case trailingBytes
    /// An additional-information value that RFC 8949 reserves (28, 29 or 30), or a form that is invalid for
    /// its major type, such as an indefinite-length integer.
    case malformedHeader(UInt8)
    /// A break byte (`FF`) outside an indefinite-length item.
    case unexpectedBreak
    /// A chunk of an indefinite-length string that is not a definite string of the same major type.
    case invalidChunk
    /// A text string that is not valid UTF-8.
    case invalidUTF8
    /// A declared length or element count larger than the bytes that remain.
    case lengthExceedsInput
    /// Containers nested deeper than ``CBORDecodingLimits/maxDepth``.
    case nestingTooDeep
}
