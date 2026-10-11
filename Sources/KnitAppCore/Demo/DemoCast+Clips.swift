/// The scenes App Review's clips film (ADR 2026-10.yddp), apart from ``DemoCast``'s body only to keep it inside the
/// lint's length.
extension DemoCast {
    /// The trailer's room and people, with a stranger in range who turns on the user. Its script posts the stranger's
    /// line, waits for the user to block them, then has them post again, which the block stops, and Sam answer, which
    /// it does not. `KnitClips.testBlock` reports the line from its menu, then unblocks the stranger from Settings.
    ///
    /// The stranger keeps no name, so the room shows their alias, as it would for someone nobody has met. Their words
    /// are rude, not abusive: nothing in the repository is, and the demo's text filter passes them (``DemoTextClassifier``).
    static let block = Self(
        me: trailer.me,
        people: trailer.people + [Person(slot: .stranger, name: "", status: "")],
        lines: trailer.lines,
        accepted: trailer.accepted,
        linked: [.sam, .stranger],
        group: trailer.group,
        reactions: trailer.reactions,
        script: [
            Cue(
                after: .moment,
                beat: .post(Line(id: "block-1", from: .stranger, to: nil, body: "Nobody wants you on this mountain. Go home."))),
            Cue(after: .glance, beat: .blocks(.stranger)),
            Cue(after: .reply, beat: .post(Line(id: "block-2", from: .stranger, to: nil, body: "You can't ignore me forever."))),
            Cue(after: .reply, beat: .post(Line(id: "block-3", from: .sam, to: nil, body: "Fire's going by the lake, come on over 🔥"))),
        ]
    )

    /// What the stranger says in the filter clip, which the demo's text filter is told to flag.
    static let filteredPost = "You're pathetic. Nobody here wants you around."
    /// What the user tries to post back in the filter clip, which the demo's text filter is told to flag too.
    static let filteredReply = "Get lost, creep."

    /// The trailer's room and people, with the stranger in range again. The demo's filters are told to flag the stranger's
    /// post and their photo, and the reply `KnitClips.testFilter` types: nothing else in the demo looks abusive or
    /// explicit to them, and nothing in the repository is either. The photo is an ordinary one standing in, which the
    /// clip never shows, and the post's words are rude, not abusive. Sam's post, which nobody flags, lands after them.
    static let filter = Self(
        me: trailer.me,
        people: trailer.people + [Person(slot: .stranger, name: "", status: "")],
        lines: trailer.lines,
        accepted: trailer.accepted,
        linked: [.sam, .stranger],
        group: trailer.group,
        reactions: trailer.reactions,
        script: [
            Cue(after: .moment, beat: .post(Line(id: "filter-1", from: .stranger, to: nil, body: filteredPost))),
            Cue(after: .reply, beat: .post(Line(id: "filter-2", from: .stranger, to: nil, body: "", photo: .forest))),
            Cue(after: .reply, beat: .post(Line(id: "filter-3", from: .sam, to: nil, body: "Fire's going by the lake, come on over 🔥"))),
        ],
        flaggedWords: [filteredPost, filteredReply],
        flaggedPhotos: [.forest]
    )
}
