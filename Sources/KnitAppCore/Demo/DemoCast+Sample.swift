/// The sample chats (ADR 2026-11.pydf), apart from ``DemoCast``'s body only to keep it inside the lint's length.
extension DemoCast {
    /// What the stranger says that nothing flags, so a report or a block has a plain post to act on.
    private static let samplePost = "Nobody wants you on this mountain. Go home."

    /// The stranger's posts, which go in just before the room's newest, so the room opens on them and the chat list's
    /// preview stays a friendly one.
    private static let sampleStranger = [
        Line(id: "sample-rude", from: .stranger, to: nil, body: samplePost, then: .moment),
        Line(id: "sample-flagged", from: .stranger, to: nil, body: filteredPost, then: .moment),
        Line(id: "sample-photo", from: .stranger, to: nil, body: "", then: .moment, photo: .forest),
    ]

    /// The marketing scene's people and threads, for anyone to open, with a stranger in the room whose posts show report,
    /// block and the filter. The scene's filters are told to flag one post and one photo, an ordinary one standing in, and
    /// everything the user types still meets the real filter (``SampleTextClassifier``).
    ///
    /// Nobody here wears a face: `App/DemoMedia/`'s licence doesn't reach a store build (ADR 2026-10.2acj), so the app
    /// draws each person's initial, as it does for anyone without a photo.
    ///
    /// Each answer says it is a sample. "On my way" from someone made up could mislead a person in a real outage, so no
    /// line promises anything, whatever the banner says over it.
    static let sample = Self(
        me: marketing.me,
        people: marketing.people + [Person(slot: .stranger, name: "", status: "")],
        lines: marketing.lines.flatMap { $0.id == "room-9" ? sampleStranger + [$0] : [$0] },
        accepted: marketing.accepted,
        linked: marketing.linked,
        group: marketing.group,
        reactions: marketing.reactions,
        flaggedWords: [filteredPost],
        flaggedPhotos: [.forest],
        answers: [
            "Sample reply: a real person's answer would show up here.",
            "Sample reply: nobody real saw your message.",
            "Sample reply: tap Leave to message real people nearby.",
        ],
        answerers: [.sam, .dani, .priya]
    )
}
