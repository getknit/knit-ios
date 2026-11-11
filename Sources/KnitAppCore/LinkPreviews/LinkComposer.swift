public import KnitMesh
public import KnitWire
public import Observation

/// The composer's half of link previews (`ChatViewModel`'s `watchDraftForLinks`, `considerCard`, `stageCard` and
/// `attachmentForSend` in knit-next, ADR 2026-11.hcvg): the first link in the draft that ``LinkPreviewPolicy`` takes
/// becomes a card held for Send, once the draft has rested ``debounce`` on it and every gate agrees.
///
/// - **The gates.** The thread says whether it wants one now: the setting is on, the one attachment slot is free, and
///   everyone the message goes to draws cards. A link the user removed the card of, or that gave none, is not fetched
///   again until the draft empties or is sent. Without a route nothing is fetched or recorded, so the link is tried
///   again at its next edit or at Send.
/// - **One slot.** A photo or a voice note held for Send hides the card and goes in its place; the thread decides that.
/// - **The send hold.** With no card held, Send waits up to ``sendHold`` for the draft's card: it joins a fetch already
///   under way or makes one, so a link handed over from the share sheet carries its card. Past the hold the words go
///   alone.
/// - **Staleness.** A new link, a removed card or a send moves the draft on, and a fetch for what it was lands nowhere.
@preconcurrency
@MainActor
@Observable
public final class LinkComposer {
    /// A card held for Send, and the link in the draft it was fetched for.
    public struct Staged: Sendable, Equatable {
        /// The card.
        public var blob: LinkPreviewBlob
        /// The draft's link it describes, normalized.
        public var url: String

        /// The card as the message's attachment: its encoded bytes, typed as a card.
        public var attachment: OutgoingPhoto {
            OutgoingPhoto(bytes: blob.encoded, mime: LinkPreviewBlob.mime)
        }
    }

    /// How long the draft rests on a link before its card is fetched (`PREVIEW_DEBOUNCE_MS`), in milliseconds.
    nonisolated public static let debounceMilliseconds = 600
    /// How long the draft rests on a link before its card is fetched.
    nonisolated public static let debounce = Duration.milliseconds(debounceMilliseconds)
    /// The longest Send waits for the draft's card (`SEND_CARD_HOLD_MS`), in seconds.
    nonisolated public static let sendHoldSeconds = 5
    /// The longest Send waits for the draft's card.
    nonisolated public static let sendHold = Duration.seconds(sendHoldSeconds)

    /// The card held for Send, or `nil`.
    public private(set) var staged: Staged?
    /// Whether a card is being fetched for the draft, which the composer says ("Loading preview…").
    public private(set) var isLoading = false

    @ObservationIgnored private let previews: LinkPreviews
    @ObservationIgnored private let service: LinkPreviewService
    @ObservationIgnored private let room: LinkPreviewService.RoomScreens?
    @ObservationIgnored private let wanted: @MainActor () -> Bool
    @ObservationIgnored private var draft = ""
    /// The link the user removed the card of, for the rest of this draft.
    @ObservationIgnored private var dismissedURL: String?
    /// The links that gave no card in this draft.
    @ObservationIgnored private var failedURLs: Set<String> = []
    /// Moves when a card is removed or the draft is sent, so a fetch still running lands nowhere.
    @ObservationIgnored private var epoch = 0
    /// What the running watch was started for.
    @ObservationIgnored private var watched: (url: String?, epoch: Int)?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var fetching: Task<Void, Never>?

    /// A composer fetching with `previews`' service, screening a room's card with `room`, and asking `wanted` whether the
    /// thread takes a card now.
    @preconcurrency
    public init(
        previews: LinkPreviews, service: LinkPreviewService, room: LinkPreviewService.RoomScreens?,
        wanted: @escaping @MainActor () -> Bool
    ) {
        self.previews = previews
        self.service = service
        self.room = room
        self.wanted = wanted
    }

    /// The draft as it now reads. A blank one forgets what this draft refused, and a new first link is fetched once the
    /// draft rests on it.
    public func draftChanged(_ text: String) {
        draft = text
        if TextLimits.isBlank(text) {
            dismissedURL = nil
            failedURLs.removeAll()
        }
        watchDraft()
    }

    /// Looks at the draft's link again, as when the slot frees: a photo or a voice note held for Send was removed.
    public func reconsider() {
        watched = nil
        watchDraft()
    }

    /// Removes the card held, and fetches none again for its link until the draft empties or is sent.
    public func remove() {
        guard let held = staged else {
            return
        }
        staged = nil
        dismissedURL = held.url
        epoch += 1
        watchDraft()
    }

    /// What Send attaches for `body` when nothing else is held: the card held for its link, else the card it can get
    /// within ``sendHold``.
    public func attachment(forSending body: String) async -> OutgoingPhoto? {
        guard let url = LinkPreviewPolicy.firstEligible(body) else {
            return nil
        }
        if let staged, staged.url == url {
            return staged.attachment
        }
        let hold = Self.sendHold
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.joinOrFetch(url) }
            group.addTask { [sleep = previews.sleep] in try? await sleep(hold) }
            await group.next()
            group.cancelAll()
        }
        return staged.flatMap { $0.url == url ? $0.attachment : nil }
    }

    /// The draft was sent: nothing it held or refused carries over, and a fetch for it lands nowhere.
    public func sent() {
        staged = nil
        dismissedURL = nil
        failedURLs.removeAll()
        epoch += 1
        draft = ""
        watchDraft()
    }

    /// The thread left the screen: whatever is waiting or fetching stops.
    public func leave() {
        watch?.cancel()
        fetching?.cancel()
        watched = nil
    }

    /// Waits until the draft's watch and any fetch it started have run out. Tests read the composer then.
    public func settled() async {
        await watch?.value
        await fetching?.value
    }

    // MARK: The loop

    /// Starts a new watch when the draft's link or the epoch moved, cancelling the last, as `collectLatest` does.
    private func watchDraft() {
        let url = LinkPreviewPolicy.firstEligible(draft)
        if let watched, watched.url == url, watched.epoch == epoch {
            return
        }
        watched = (url, epoch)
        watch?.cancel()
        fetching?.cancel()
        watch = Task { [sleep = previews.sleep] in
            guard (try? await sleep(Self.debounce)) != nil, !Task.isCancelled else {
                return
            }
            await self.consider(url)
        }
    }

    /// What the draft's link asks for once the draft rested on it (`considerCard`): no link takes the card away, and a
    /// link other than the card's takes it away too, so a card never rides beside another page's link.
    private func consider(_ url: String?) async {
        if staged?.url != url {
            staged = nil
        }
        guard let url, staged == nil, await cardWanted(url) else {
            return
        }
        await stage(url)
    }

    /// Every gate a fetch for `url` passes (`cardWanted`), the route last since it is asked of the system.
    private func cardWanted(_ url: String) async -> Bool {
        guard staged == nil, !isLoading, url != dismissedURL, !failedURLs.contains(url), wanted() else {
            return false
        }
        return await previews.gate?.isOnline() ?? false
    }

    /// One fetch for `url`, said while it runs (`stageCard`); holds what it yields if the draft still asks for it.
    private func stage(_ url: String) async {
        let at = epoch
        isLoading = true
        let task = Task { await self.service.fetchCard(url, room: self.room) }
        fetching = Task { _ = await task.value }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        isLoading = false
        switch result {
        case .card(let blob):
            guard !Task.isCancelled, at == epoch, staged == nil, LinkPreviewPolicy.firstEligible(draft) == url else {
                return
            }
            staged = Staged(blob: blob, url: url)
        case .noCard:
            // A fetch cancelled with its draft gave no answer about the link.
            if !Task.isCancelled {
                failedURLs.insert(url)
            }
        case .offline, .restricted:
            // No answer about the link: it is asked again at its next edit or at Send.
            break
        }
    }

    /// Send's hold: the fetch already running for `url`, or one made now when the draft would make it.
    private func joinOrFetch(_ url: String) async {
        if isLoading {
            await fetching?.value
            return
        }
        if await cardWanted(url) {
            await stage(url)
        }
    }
}
