import KnitWire

/// Arbitrary bytes into the CBOR decoder and every typed decoder. Nothing may trap, and anything that decodes
/// must be stable under encode and decode: `encode(decode(encode(x))) == encode(x)`.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzCBOR(_ data: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let bytes = Array(unsafe UnsafeBufferPointer(start: data, count: count))
    guard let item = try? CBOR.decode(bytes) else {
        return 0
    }
    let once = item.encoded
    guard let again = try? CBOR.decode(once) else {
        fatalError("an encoded item failed to decode")
    }
    precondition(again.encoded == once, "encoding is not stable")
    _ = try? WireEnvelope(cbor: item)
    _ = try? RelayEnvelope(cbor: item)
    _ = try? ChatContent(cbor: item)
    _ = try? ProfileContent(cbor: item)
    _ = try? ReceiptContent(cbor: item)
    _ = try? ReactionContent(cbor: item)
    _ = try? KeyRequestContent(cbor: item)
    _ = try? BlobRequestContent(cbor: item)
    _ = try? BlobHaveContent(cbor: item)
    _ = try? BlobHasContent(cbor: item)
    _ = try? BlobProgressContent(cbor: item)
    _ = try? BlobCancelContent(cbor: item)
    _ = try? TypingContent(cbor: item)
    _ = try? GroupLeaveContent(cbor: item)
    _ = try? EncEnvelope(cbor: item)
    _ = try? MessageContent(cbor: item)
    _ = try? PublicKeyBundleProto(cbor: item)
    return 0
}
