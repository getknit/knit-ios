import KnitWire

/// Arbitrary bytes as a link's preview card, and as an address a card might carry (knit-next ADR 2026-09.n752). Nothing
/// traps. A card that decodes keeps a safe address, its texts and picture within their limits, and decodes again from its
/// own bytes to the same address and picture. The address check, its host and the text hygiene never trap on any text.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzLinkPreview(_ data: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let bytes = Array(unsafe UnsafeBufferPointer(start: data, count: count))
    if let text = String(validating: bytes, as: UTF8.self) {
        _ = LinkPreviewBlob.host(of: text)
        _ = LinkPreviewBlob.isSafeHttpURL(text)
        let cleaned = LinkPreviewBlob.clean(text, limit: LinkPreviewBlob.titleMax)
        precondition(cleaned.utf16.count <= LinkPreviewBlob.titleMax, "cleaned text past its limit")
    }
    guard let card = LinkPreviewBlob.decode(bytes) else {
        return 0
    }
    precondition(LinkPreviewBlob.isSafeHttpURL(card.url), "a card kept an unsafe address")
    precondition(card.title.utf16.count <= LinkPreviewBlob.titleMax, "a title past its limit")
    precondition((card.description?.utf16.count ?? 0) <= LinkPreviewBlob.descriptionMax, "a description past its limit")
    precondition(card.description?.isEmpty != true, "an empty description kept")
    if let image = card.image {
        precondition(!image.isEmpty && image.count <= LinkPreviewBlob.imageMaxBytes, "a picture past its limit")
        precondition(card.imageMime.map(LinkPreviewBlob.imageMimes.contains) == true, "a picture of a type no card draws")
    } else {
        precondition(card.imageMime == nil, "a picture's type without a picture")
    }
    guard let again = LinkPreviewBlob.decode(card.encoded) else {
        fatalError("a decoded card did not decode from its own bytes")
    }
    precondition(again.url == card.url && again.image == card.image, "a card changed its address or picture on a round trip")
    return 0
}
