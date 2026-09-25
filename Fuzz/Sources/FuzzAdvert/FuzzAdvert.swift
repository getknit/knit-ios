import KnitWire

/// Arbitrary bytes as an advert's service data, and as text for the id and text codecs. Anything that parses
/// must write back the bytes it came from.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzAdvert(_ data: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let bytes = Array(unsafe UnsafeBufferPointer(start: data, count: count))
    if let advert = AdvertPayload(serviceData: bytes), bytes.count == AdvertPayload.size {
        precondition(advert.bytes == bytes, "a full advert did not round-trip")
    }
    // Lossy on purpose: every input becomes some string, replacement characters included.
    // swiftlint:disable:next optional_data_string_conversion
    let text = String(decoding: bytes, as: UTF8.self)
    if let node = NodeId(text) {
        precondition(NodeId(bytes: node.bytes) == node, "a canonical node id did not round-trip")
    }
    if let frameBytes = FrameId.bytes(of: text) {
        precondition(FrameId.text(for: frameBytes) == text, "a canonical frame id did not round-trip")
    }
    _ = Base64.decode(text)
    _ = Base64.decode(text, variant: .urlSafeUnpadded)
    _ = Base32.decode(text)
    _ = Hex.decode(text)
    _ = TextLimits.normalizeSingleLine(text)
    _ = TextLimits.truncated(text, toUTF16: TextLimits.displayName)
    _ = TextLimits.isValidReaction(text)
    _ = TextLimits.isBlank(text)
    return 0
}
