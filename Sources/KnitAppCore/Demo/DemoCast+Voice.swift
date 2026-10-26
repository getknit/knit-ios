// The scene of voice notes and a line's note, apart from `DemoScene.swift` only to keep that file under the lint's length.
extension DemoCast {
    /// A line's voice note.
    enum Voice {
        /// Its bytes are here, so it plays.
        case held
        /// Its bytes are owed, from someone not in range.
        case owed
    }

    /// How much of Sam's last note is in, of the size its header declared: a ring part full.
    private static let notesBytes = 9000
    private static let notesTotal = 27_289

    /// A DM with Sam: a note of Sam's that plays, one of ours, one streaming in and one still owed (knit-next ADR 034).
    static let voice = Self(
        people: [Person(slot: .sam, name: "Sam", status: "At the north gate", portrait: .sam)],
        lines: [
            Line(id: "voice-1", from: .sam, to: .me, body: "", then: .minutes, voice: .held),
            Line(id: "voice-2", from: .me, to: .sam, body: "On my way up.", delivered: true, then: .minutes, voice: .held),
            Line(
                id: "voice-3",
                from: .sam,
                to: .me,
                body: "",
                then: .moment,
                arriving: Arriving(bytes: notesBytes, total: notesTotal),
                voice: .owed
            ),
            Line(id: "voice-4", from: .sam, to: .me, body: "From the gate.", voice: .owed),
        ],
        accepted: [.sam],
        linked: [.sam]
    )
}
