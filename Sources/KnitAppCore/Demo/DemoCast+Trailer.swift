/// The trailer's scene and the script ``DemoDirector`` plays (ADR 2026-10.g3k9), apart from ``DemoCast``'s body only to
/// keep it inside the lint's length.
extension DemoCast {
    /// One thing that happens while ``DemoDirector`` plays a scene.
    enum Beat {
        /// Someone links, and is shown as linked from then on.
        case link(Slot)
        /// Someone else's room post arrives. Its `then` is not read: it arrives now.
        case post(Line)
        /// Someone reacts to a line of the script or the scene.
        case react(Reaction)
        /// The user types these words into the room's composer, a key at a time, and sends them.
        case type(String)
        /// The user's newest room post is heard: it shows delivered.
        case heard
        /// The script waits until the user blocks this person, however they do it (ADR 2026-10.yddp).
        case blocks(Slot)
    }

    /// How long a beat waits after the one before it, in milliseconds: a person's pauses, not a test's.
    enum Wait: Int64 {
        /// One key, as someone types: knit-next's director types at 65 ms a key.
        case key = 65
        /// A second reaction after the first, or a tick after a post.
        case glance = 600
        /// Someone reacting to what they just read.
        case beat = 1200
        /// Someone linking, or a post landing on the chat list.
        case moment = 1500
        /// Someone answering.
        case reply = 1800
    }

    /// A beat, and how long after the one before it it happens.
    struct Cue {
        let after: Wait
        let beat: Beat
    }

    /// The room posts the trailer opens on: the storm, and ours about the mud, which the user's first post follows.
    private static let trailerOpening: Set = ["room-1", "room-2", "room-3"]

    /// The marketing scene's people, DMs, group and request, with the room down to its opening and only Sam linked. Its
    /// script is a short film in the room, after knit-next's: the user asks who is still up top, Sam answers, Lena warns
    /// of the bridge, Dani posts the fire, and Priya posts the sunset, with reactions between. Each reply lands as someone
    /// reading it would expect, and `build-trailer.sh` speeds the whole up to fit.
    static let trailer = Self(
        me: marketing.me,
        people: marketing.people,
        lines: marketing.lines.filter { !$0.id.hasPrefix("room-") || trailerOpening.contains($0.id) },
        accepted: marketing.accepted,
        linked: [.sam],
        group: marketing.group,
        reactions: marketing.reactions.filter { !$0.line.hasPrefix("room-") },
        script: [
            Cue(after: .moment, beat: .type("Anyone still up top?")),
            Cue(after: .glance, beat: .heard),
            Cue(after: .glance, beat: .link(.dani)),
            Cue(after: .glance, beat: .link(.priya)),
            Cue(after: .reply, beat: .post(Line(id: "trailer-1", from: .sam, to: nil, body: "Trail's clear up top, Maya 🎉 Come join us!"))),
            Cue(
                after: .reply,
                beat: .post(
                    Line(id: "trailer-2", from: .lena, to: nil, body: "Heads up: the bridge near the falls is out. Take the upper loop."))
            ),
            Cue(after: .beat, beat: .react(Reaction(line: "trailer-2", by: .priya, emoji: "\u{1F64F}"))),
            Cue(after: .glance, beat: .react(Reaction(line: "trailer-2", by: .sam, emoji: "\u{1F64F}"))),
            Cue(
                after: .reply,
                beat: .post(Line(id: "trailer-3", from: .dani, to: nil, body: "Saved you a spot by the fire 🔥", photo: .campfire))
            ),
            Cue(after: .moment, beat: .react(Reaction(line: "trailer-3", by: .sam, emoji: heart))),
            Cue(after: .glance, beat: .react(Reaction(line: "trailer-3", by: .priya, emoji: heart))),
            Cue(
                after: .reply,
                beat: .post(
                    Line(id: "trailer-4", from: .priya, to: nil, body: "Sunset from the summit is unreal tonight 🌄", photo: .sunset))
            ),
            Cue(after: .moment, beat: .react(Reaction(line: "trailer-4", by: .dani, emoji: heart))),
        ]
    )
}
