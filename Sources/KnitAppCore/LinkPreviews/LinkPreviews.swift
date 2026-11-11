/// What a build that has link previews hands the session (ADR 2026-11.hcvg): a debug build's alone until the maintainer
/// approves them for the store, as voice notes are (``VoiceNotes``). With it, a thread draws the card Android's sender
/// fetched beside the link it describes, the mesh's signed profile carries `CAP_LINK_PREVIEW`, so an Android phone
/// attaches one to a DM or a group toward this phone, and, with the setting on, the composer fetches a card for a link
/// it holds. A release build hands none, and behaves as it did before: no card drawn or sent, no setting, and
/// `0xC015F` sent.
public struct LinkPreviews: Sendable {
    /// What fetches a card for the composer, or `nil` for a build that draws cards and sends none.
    public let service: LinkPreviewService?
    /// The route to the Internet the composer asks before it fetches, or `nil` for none.
    public let gate: (any InternetGate)?
    /// How the composer waits: the system's sleep in the app, an instant one in a test.
    public let sleep: @Sendable (Duration) async throws -> Void

    /// Link previews fetching with `service` over `gate`, waiting with `sleep`; with no service, cards are drawn and none
    /// is sent.
    @preconcurrency
    public init(
        service: LinkPreviewService? = nil, gate: (any InternetGate)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.gate = gate
        self.sleep = sleep
    }
}
