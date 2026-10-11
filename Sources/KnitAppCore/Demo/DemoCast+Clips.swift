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
}
