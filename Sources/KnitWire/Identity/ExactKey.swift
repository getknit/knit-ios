/// Wire text used as a map key, compared by its UTF-8 bytes, the way Kotlin compares strings.
///
/// Swift's `String` equality is canonical equivalence: `"K"` equals the Kelvin sign `"\u{212A}"`, and `"é"`
/// equals `"e\u{301}"`, for hashing too. Kotlin compares UTF-16 code units, and the CBOR decoder admits only
/// valid UTF-8, which maps one-to-one onto them, so two ids are the same frame on Android exactly when their
/// bytes match. Keyed by `String`, a seen set would take a crafted id that Android treats as new for a
/// duplicate of a real frame's, and the real frame would then be dropped on every Swift node the crafted one
/// reached first. Frame ids, frame keys and every set built from them key on this instead.
public struct ExactKey: Hashable, Sendable {
    /// The text's UTF-8.
    public let bytes: [UInt8]

    /// The key for `text`.
    public init(_ text: String) {
        bytes = Array(text.utf8)
    }
}
