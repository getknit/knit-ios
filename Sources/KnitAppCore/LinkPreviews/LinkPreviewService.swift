public import KnitWire

/// Whether the phone has a route to the Internet a card may be fetched over (`InternetGate` in knit-next). The app's
/// watches the system's path; a test's is a switch.
public protocol InternetGate: Sendable {
    /// Whether a route to the Internet is up now.
    func isOnline() async -> Bool
    /// Whether that route is one the user asked to spare: Low Data Mode, standing in for Android's Data Saver.
    func isRestricted() async -> Bool
}

/// A card's picture made small (`LinkPreviewService.Shrunk`): at most ``LinkPreviewBlob/imageMaxBytes``, typed one of
/// ``LinkPreviewBlob/imageMimes``.
public struct ShrunkPicture: Sendable, Equatable {
    /// The encoded picture.
    public var bytes: [UInt8]
    /// Its type.
    public var mime: String

    /// A picture of `bytes`, typed `mime`.
    public init(bytes: [UInt8], mime: String) {
        self.bytes = bytes
        self.mime = mime
    }
}

/// Why a link did or did not become a card (`CardResult`).
public enum CardResult: Sendable, Equatable {
    /// The card to attach, cleaned, and screened when it goes to the room.
    case card(LinkPreviewBlob)
    /// No route to the Internet: no answer about the link, so it may be asked again when a route comes back.
    case offline
    /// Low Data Mode is on: the same as ``offline``.
    case restricted
    /// The link gives no card: refused by the rules, out of reach, no page, no title, or words the room's filter flags.
    case noCard
}

/// Turns a link in the sender's draft into the card that rides with the message (`LinkPreviewService.kt` in knit-next,
/// ADR 2026-11.hcvg). Everything that reaches the Internet sits here and below.
///
/// The order of the gates is the point. The route is asked first, so a phone that is only on the mesh, behind no route
/// or in Low Data Mode never opens a socket. Then the page, bounded by ``PreviewWalk``; then the picture, which may fail
/// on its own and leave a card without one; and, for the Nearby room only, the sender's own filter: words it flags give
/// no card, and a picture it flags is dropped (ADR 2026-10.spcy). A DM's or a group's card is not screened here, as on
/// Android (knit-next ADR 2026-10.9rh6): every reader screens what arrives.
///
/// A short memo keeps a link typed again from being fetched twice. It holds cards unscreened, since only the room
/// screens and one link can be pasted in both.
public actor LinkPreviewService {
    /// The time one link may take, page and picture together (`FETCH_BUDGET_MS`), in seconds: a slow site must not hold
    /// the composer.
    public static let budgetSeconds = 30
    /// The time one link may take.
    public static let budget = Duration.seconds(budgetSeconds)
    /// How long a card is kept for the same link (`MEMO_TTL_MS`), in milliseconds.
    public static let memoMilliseconds: Int64 = 600_000
    /// How many cards are kept (`MEMO_MAX`).
    public static let memoKept = 32

    /// The two screens the room's card passes on this phone: its words, and its picture.
    public struct RoomScreens: Sendable {
        /// Whether words look abusive in the room.
        public var wordsFlagged: @Sendable (String) async -> Bool
        /// Whether a picture about to be sent looks explicit.
        public var pictureFlagged: @Sendable ([UInt8]) async -> Bool

        /// Screens with `wordsFlagged` and `pictureFlagged`.
        @preconcurrency
        public init(
            wordsFlagged: @escaping @Sendable (String) async -> Bool, pictureFlagged: @escaping @Sendable ([UInt8]) async -> Bool
        ) {
            self.wordsFlagged = wordsFlagged
            self.pictureFlagged = pictureFlagged
        }
    }

    private enum Fetched {
        case blob(LinkPreviewBlob)
        case offline
        case nothing
    }

    /// One card the memo keeps, and when it was fetched.
    private struct Remembered {
        var url: String
        var at: Int64
        var blob: LinkPreviewBlob
    }

    private let gate: any InternetGate
    private let fetcher: any PreviewFetcher
    private let shrink: @Sendable ([UInt8]) async -> ShrunkPicture?
    private let charsets: OpenGraphParser.CharsetDecoder?
    private let now: @Sendable () -> Int64
    private let sleep: @Sendable (Duration) async throws -> Void
    private let log: @Sendable (String) -> Void
    /// The cards fetched, oldest first.
    private var memo: [Remembered] = []

    /// A service asking `gate` for a route, fetching with `fetcher`, making pictures small with `shrink`, reading a page in
    /// a charset the parser does not know with `charsets`, telling the time with `now`, timing the budget with `sleep` and
    /// logging hosts, never addresses, to `log`.
    @preconcurrency
    public init(
        gate: any InternetGate, fetcher: any PreviewFetcher, shrink: @escaping @Sendable ([UInt8]) async -> ShrunkPicture?,
        charsets: OpenGraphParser.CharsetDecoder? = nil,
        now: @escaping @Sendable () -> Int64, sleep: @escaping @Sendable (Duration) async throws -> Void,
        log: @escaping @Sendable (String) -> Void = { _ in
            // Nothing is said where nobody listens.
        }
    ) {
        self.gate = gate
        self.fetcher = fetcher
        self.shrink = shrink
        self.charsets = charsets
        self.now = now
        self.sleep = sleep
        self.log = log
    }

    /// The card for `url` as the draft has it, screened by `room` when it goes to the Nearby room (`fetchCard`).
    public func fetchCard(_ url: String, room: RoomScreens?) async -> CardResult {
        guard let normalized = LinkPreviewPolicy.normalize(url) else {
            return .noCard
        }
        guard await gate.isOnline() else {
            return .offline
        }
        guard await !gate.isRestricted() else {
            return .restricted
        }
        let blob: LinkPreviewBlob
        if let remembered = memoized(normalized) {
            blob = remembered
        } else {
            switch await fetchWithinBudget(normalized) {
            case .blob(let fetched):
                remember(fetched, as: normalized)
                blob = fetched
            case .offline:
                return .offline
            case .nothing:
                return .noCard
            }
        }
        guard let room else {
            return .card(blob)
        }
        if await room.wordsFlagged(blob.moderationText) {
            log("card words flagged for \(blob.host), no card")
            return .noCard
        }
        guard let image = blob.image, await room.pictureFlagged(image) else {
            return .card(blob)
        }
        log("card picture flagged for \(blob.host), dropped")
        return .card(LinkPreviewBlob(version: blob.version, url: blob.url, title: blob.title, description: blob.description))
    }

    /// The fetch, given up on past ``budget``.
    private func fetchWithinBudget(_ url: String) async -> Fetched {
        let fetched = await withTaskGroup(of: Fetched?.self) { group in
            group.addTask { await self.fetch(url) }
            group.addTask { [sleep] in
                try? await sleep(Self.budget)
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first.flatMap(\.self)
        }
        guard let fetched else {
            log("gave up on \(LinkPreviewBlob.host(of: url)) after \(Self.budget)")
            return .nothing
        }
        return fetched
    }

    private func fetch(_ url: String) async -> Fetched {
        let host = LinkPreviewBlob.host(of: url)
        let page = await fetcher.fetchPage(url)
        guard case .html(let bytes, let contentType, let finalURL) = page else {
            if page == .offline {
                return .offline
            }
            log("no page for \(host): \(page)")
            return .nothing
        }
        let text = OpenGraphParser.decode(bytes, contentType: contentType, decoder: charsets)
        guard let meta = OpenGraphParser.parse(text, finalURL: finalURL) else {
            log("no title for \(host)")
            return .nothing
        }
        var picture: ShrunkPicture?
        if let imageURL = meta.imageURL {
            picture = await fetchPicture(imageURL)
        }
        let blob = LinkPreviewBlob(
            url: url, title: meta.title, description: meta.description, image: picture?.bytes, imageMime: picture?.mime
        ).normalized()
        return blob.map(Fetched.blob) ?? .nothing
    }

    /// The card's picture, or `nil` on any failure at all: a card without a picture is still a card.
    private func fetchPicture(_ imageURL: String) async -> ShrunkPicture? {
        guard let normalized = LinkPreviewPolicy.normalize(imageURL), case .image(let bytes, _) = await fetcher.fetchImage(normalized)
        else {
            return nil
        }
        return await shrink(bytes)
    }

    private func memoized(_ url: String) -> LinkPreviewBlob? {
        let at = now()
        memo.removeAll { at - $0.at > Self.memoMilliseconds }
        return memo.first { $0.url == url }?.blob
    }

    private func remember(_ blob: LinkPreviewBlob, as url: String) {
        memo.removeAll { $0.url == url }
        memo.append(Remembered(url: url, at: now(), blob: blob))
        if memo.count > Self.memoKept {
            memo.removeFirst()
        }
    }
}
