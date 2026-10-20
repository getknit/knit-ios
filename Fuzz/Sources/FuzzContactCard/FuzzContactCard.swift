import KnitCrypto
import KnitWire

/// Arbitrary bytes as a pasted text, a link or a scanned code, through the contact card's parser (ADR 2026-10.tpr5), and
/// as a compact card's bytes behind the scheme link. Whatever parses must certify itself: its bundle's text derives to its
/// id, and a card that carries keys rebuilds that bundle.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzContactCard(_ data: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let bytes = Array(unsafe UnsafeBufferPointer(start: data, count: count))
    // Lossy on purpose: every input becomes some string, replacement characters included.
    // swiftlint:disable:next optional_data_string_conversion
    let text = String(decoding: bytes, as: UTF8.self)
    check(ContactCard.parse(text))
    _ = ContactCard.looksLikeCard(text)
    check(ContactCard.parse(ContactCard.schemePrefix + Base64.encode(bytes, variant: .urlSafeUnpadded)))
    _ = try? ContactCardSigned(decoding: bytes)
    _ = try? ContactCardBody(decoding: bytes)
    return 0
}

private func check(_ parsed: ContactCard.Parsed) {
    guard let card = parsed.card else {
        return
    }
    precondition(NodeId(deriving: card.bundle) == card.nodeId, "a card whose bundle does not derive to its id")
    precondition(card.name.utf16.count <= TextLimits.displayName, "a name past its limit")
    precondition(card.spools.count <= ContactCard.maxSpools, "more relays than a card yields")
}
