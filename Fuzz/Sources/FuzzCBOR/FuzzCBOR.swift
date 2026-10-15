import KnitWire

/// Arbitrary bytes into the CBOR decoder and every typed decoder, the v3 compact plaintext's included. Nothing may
/// trap, and anything that decodes must be stable under encode and decode: `encode(decode(encode(x))) == encode(x)`.
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
    _ = try? ProfilePayload(cbor: item)
    _ = try? GroupKeyPayload(cbor: item)
    _ = try? GroupSeed(cbor: item)
    _ = try? GroupRootPayload(cbor: item)
    _ = try? PublicKeyBundleProto(cbor: item)
    compactPlaintext(bytes)
    return 0
}

/// The v3 compact plaintext (`MessageContentV2`). Whatever decodes must encode again, since every id, hash and key it
/// decodes is canonical by construction, and must decode back to the same content.
private func compactPlaintext(_ bytes: [UInt8]) {
    guard let content = MessageContentV2.decode(bytes) else {
        return
    }
    guard let again = MessageContentV2.encode(content) else {
        fatalError("decoded compact content would not encode")
    }
    precondition(MessageContentV2.decode(again) == content, "compact content changed on a round trip")
}
