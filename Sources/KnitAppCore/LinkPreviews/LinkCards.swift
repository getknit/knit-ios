import KnitCrypto
public import KnitWire
public import Observation

/// The link-preview cards this run of the app has opened (`LinkCardStore` in knit-next): the bridge between "the blob is
/// here" and "a thread can draw it". A card is opened once, on request, off the main actor: read from the blob store,
/// opened with its message's key when it is sealed, and read through ``LinkPreviewBlob/decode(_:)``, which is where a
/// peer's card is cleaned or refused.
///
/// It lives in memory and is bounded: the newest 64 cards stay opened, a blob that does not open as a card is
/// remembered so it is never read twice, and nothing is written, since the blob store keeps the bytes as long as a
/// message names them. A blob not yet here is left for a later ask, which the thread makes when the blob lands.
@preconcurrency
@MainActor
@Observable
public final class LinkCards {
    /// One card as it is read: its blob, and the key that opens it when it is sealed. Two messages may name one blob
    /// with different keys, and so different cards.
    private struct Opening: Hashable {
        var hash: BlobHash
        var key: String?
    }

    /// What reading one blob found.
    private enum Found: Sendable {
        /// A card.
        case card(LinkCard)
        /// No bytes under the hash yet.
        case absent
        /// Bytes that do not open as a card: a wrong key, another layout, or a card ``LinkPreviewBlob/decode(_:)``
        /// refuses.
        case refused
    }

    /// How many opened cards stay in memory (`MAX_CARDS`); a thread shows far fewer at once, and opening one again is
    /// cheap.
    public static let cardsKept = 64
    /// How many blobs that did not open are remembered (`MAX_UNDECODABLE`).
    public static let refusalsKept = 256

    /// Moves each time a card opens, so a thread that asked for it before it was open draws it.
    public private(set) var openedCount = 0

    @ObservationIgnored private let read: @Sendable (BlobHash) -> [UInt8]?
    @ObservationIgnored private var cards: [Opening: LinkCard] = [:]
    /// The cards held, least recently asked for first.
    @ObservationIgnored private var order: [Opening] = []
    @ObservationIgnored private var refused: [Opening] = []
    @ObservationIgnored private var refusedSet: Set<Opening> = []
    @ObservationIgnored private var reading: [Opening: Task<Found, Never>] = [:]

    /// Cards whose blobs `read` gives as the store holds them, or `nil` while one is missing.
    @preconcurrency
    public init(read: @escaping @Sendable (BlobHash) -> [UInt8]?) {
        self.read = read
    }

    /// The card under `hash`, opened with `key`, if it is open now. Otherwise `nil`, and the card is read unless it is
    /// being read or is known not to open: ``openedCount`` moves once it opens. The card is labelled as posted outside the
    /// room; the thread says where it was.
    public func card(_ hash: BlobHash, key: String?) -> LinkCard? {
        let opening = Opening(hash: hash, key: key)
        if let card = cards[opening] {
            touch(opening)
            return card
        }
        if !refusedSet.contains(opening), reading[opening] == nil {
            Task { await open(hash, key: key) }
        }
        return nil
    }

    /// The card under `hash`, opened with `key`, reading it once however many ask at the same time; `nil` while its bytes
    /// are missing, and for bytes that do not open as a card.
    @discardableResult
    public func open(_ hash: BlobHash, key: String?) async -> LinkCard? {
        let opening = Opening(hash: hash, key: key)
        if let card = cards[opening] {
            return card
        }
        guard !refusedSet.contains(opening) else {
            return nil
        }
        let task = reading[opening] ?? Task { [read] in await Self.found(opening, read: read) }
        reading[opening] = task
        let found = await task.value
        reading[opening] = nil
        switch found {
        case .card(let card):
            keep(card, as: opening)
            return card
        case .refused:
            refuse(opening)
            return nil
        case .absent:
            return nil
        }
    }

    private func keep(_ card: LinkCard, as opening: Opening) {
        guard cards.updateValue(card, forKey: opening) == nil else {
            return
        }
        order.append(opening)
        if order.count > Self.cardsKept {
            cards[order.removeFirst()] = nil
        }
        openedCount += 1
    }

    private func touch(_ opening: Opening) {
        guard order.last != opening, let at = order.firstIndex(of: opening) else {
            return
        }
        order.remove(at: at)
        order.append(opening)
    }

    private func refuse(_ opening: Opening) {
        guard refusedSet.insert(opening).inserted else {
            return
        }
        refused.append(opening)
        if refused.count > Self.refusalsKept {
            refusedSet.remove(refused.removeFirst())
        }
    }

    /// What the blob `opening` names holds, read and opened off the main actor (`LinkCardStore.open`).
    @concurrent
    nonisolated private static func found(_ opening: Opening, read: @Sendable (BlobHash) -> [UInt8]?) async -> Found {
        guard let stored = read(opening.hash) else {
            return .absent
        }
        let opened = opening.key.map { key in Base64.decode(key).flatMap { AttachmentCrypto.open(stored, key: $0) } } ?? stored
        guard let bytes = opened, let blob = LinkPreviewBlob.decode(bytes) else {
            return .refused
        }
        return .card(LinkCard(blob, hash: opening.hash, key: opening.key, inRoom: false))
    }
}
