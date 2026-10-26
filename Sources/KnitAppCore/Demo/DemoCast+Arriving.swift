// The scene of photos on their way, and what says how far one has got, apart from `DemoScene.swift` only to keep that
// file under the lint's length.
extension DemoCast {
    /// A photo on its way: the bytes in so far, and the size its sender's header declared, if any.
    struct Arriving {
        let bytes: Int
        var total: Int?
    }

    /// How much of Sam's photo is in, of the size its header declared: a ring part full.
    private static let samsBytes = 84_000
    private static let samsTotal = 204_800
    /// How much of Priya's photo is in, from a sender that declared no size: the count alone.
    private static let priyasBytes = 52_000

    /// Two room posts whose photos are streaming in, and Sam linked to bring them: Sam's ringed against its header's size,
    /// Priya's counted alone (ADR 2026-10.y9qh).
    static let photoArriving = Self(
        people: [
            Person(slot: .sam, name: "Sam", status: "At the north gate"),
            Person(slot: .priya, name: "Priya", status: ""),
        ],
        lines: [
            Line(id: "arriving-1", from: .me, to: nil, body: "Anyone got a shot of the view from the ridge?", delivered: true),
            Line(
                id: "arriving-2",
                from: .sam,
                to: nil,
                body: "Sending one now.",
                then: .moment,
                arriving: Arriving(bytes: samsBytes, total: samsTotal)
            ),
            Line(id: "arriving-3", from: .priya, to: nil, body: "Mine's from the old phone.", arriving: Arriving(bytes: priyasBytes)),
        ],
        accepted: [],
        linked: [.sam]
    )
}
