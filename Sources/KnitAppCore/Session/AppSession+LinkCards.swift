import KnitWire

// A session's link-preview cards (ADR 2026-11.hcvg): their pictures, which the cards opened in memory leave out, are read
// from the blob again when a card is drawn or screened (`LinkCardStore.imageBytes`).
extension AppSession {
    /// The picture `card` carries, read from its blob and opened as ``attachment(_:key:)`` opens a photo, or `nil` when
    /// it has none, or its blob is missing or no longer opens as a card. It reads the disk, so the app calls it off the
    /// main actor.
    nonisolated public func picture(of card: LinkCard) -> [UInt8]? {
        attachment(card.hash, key: card.key).flatMap(LinkPreviewBlob.decode)?.image
    }
}
