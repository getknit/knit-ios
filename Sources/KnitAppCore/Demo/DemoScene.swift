/// A picture the demo gives someone as their profile photo. The app paints it, so no photograph ships in the app.
public enum DemoPortrait: Sendable, CaseIterable {
    /// Snow on a peak under a clear sky.
    case summit
    /// A low sun over hills.
    case sunset
    /// Pines under a pale sky.
    case forest
    /// Mountains over still water.
    case lake
    /// A fire under the stars.
    case campfire
}

/// Which cast `-seedDemo` seeds, as `-demoScene` names it.
public enum DemoScene: String, Sendable, CaseIterable {
    /// The states a screen must handle: two peers with one name, a stranger with none, someone blocked, a message still
    /// waiting to be delivered, and nobody linked. The default.
    case edgeCases = "edge-cases"
    /// A day on the trail for store screenshots and social posts, with three peers linked, and most people wearing a
    /// profile photo. After knit-next's hiking theme (`DemoScenarios.kt`), less what the iPhone does not do yet: voice
    /// notes, LoRa and Internet relays.
    case marketing = "marketing"

    /// Who and what the scene seeds.
    var cast: DemoCast {
        switch self {
        case .edgeCases:
            .edgeCases
        case .marketing:
            .marketing
        }
    }
}

/// One scene's people and threads. Lines are oldest first, and the newest was sent a pause before now.
internal struct DemoCast {
    /// Everyone a scene can cast, this device first. Each one's keys come from its raw value, so its node id, alias
    /// and safety number are the same every launch and in every scene.
    enum Slot: UInt8 {
        case me = 0
        case sam = 1
        case priya = 2
        case stranger = 3
        case otherSam = 4
        case dani = 5
        case theo = 6
        case jonas = 7
        case lena = 8
        case river = 9
    }

    /// Our own profile.
    struct Own {
        let name: String
        let status: String
        var portrait: DemoPortrait?
    }

    /// A pinned peer.
    struct Person {
        let slot: Slot
        let name: String
        let status: String
        var verified = false
        var openToChat = false
        var portrait: DemoPortrait?
        /// Whether the user blocked them (ADR 2026-10.5wgg).
        var blocked = false
    }

    /// How long passed after a line, before the next one or now.
    enum Pause: Int64 {
        case moment = 60_000
        case minutes = 180_000
        case quarterHour = 900_000
        case halfHour = 1_800_000
    }

    /// A message.
    struct Line {
        let id: String
        let from: Slot
        /// `nil` for a room post or a group message.
        let to: Slot?
        let body: String
        var delivered = false
        var then = Pause.minutes
        /// Whether it is a message in the scene's group.
        var inGroup = false
        /// The photo a room post carries, painted by whoever seeds the scene.
        var photo: DemoPortrait?
    }

    /// Someone's reaction to one of the scene's lines, a moment after it (ADR 2026-10.ehe6).
    struct Reaction {
        let line: String
        let by: Slot
        let emoji: String
    }

    /// The scene's group: its members besides us, in pick order, and who started it.
    struct Group {
        let members: [Slot]
        let createdBy: Slot
        /// Its name, or `nil` for one titled after its members.
        var name: String?
        /// Members who left, a moment after it started.
        var departed: [Slot] = []
    }

    /// Our own profile, or `nil` to leave it unset.
    var me: Own?
    let people: [Person]
    let lines: [Line]
    /// The DMs accepted.
    let accepted: [Slot]
    /// The peers shown as linked.
    let linked: [Slot]
    /// The scene's group, if it has one.
    var group: Group?
    /// The reactions, in the order they were made.
    var reactions: [Reaction] = []

    private static let thumbs = "\u{1F44D}"
    private static let heart = "\u{2764}\u{FE0F}"

    /// Two peers share a name, to show a discriminated label; the stranger has none, to show an alias. Jonas is blocked,
    /// so Settings lists someone and his profile shows the badge. Our room post has a count above one, an emoji outside
    /// the six, and a heart from Jonas that his block hides; Sam's DM has ours, and a stranger's that a DM does not show.
    static let edgeCases = Self(
        people: [
            Person(slot: .sam, name: "Sam", status: "At the north gate", verified: true),
            Person(slot: .priya, name: "Priya", status: ""),
            Person(slot: .stranger, name: "", status: ""),
            Person(slot: .otherSam, name: "Sam", status: "Lost my group"),
            Person(slot: .jonas, name: "Jonas", status: "", blocked: true),
        ],
        lines: [
            Line(id: "room-1", from: .sam, to: nil, body: "Is anyone else at the festival without signal?"),
            Line(id: "room-2", from: .otherSam, to: nil, body: "Same here. Knit is the only thing working."),
            Line(id: "room-3", from: .me, to: nil, body: "Meet at the food trucks at 6?", delivered: true),
            Line(id: "room-4", from: .priya, to: nil, body: "On my way."),
            Line(id: "group-1", from: .priya, to: nil, body: "Who's bringing the tent?", inGroup: true),
            Line(id: "group-2", from: .me, to: nil, body: "I've got it.", inGroup: true),
            Line(id: "dm-1", from: .me, to: .sam, body: "Which gate are you at?", delivered: true),
            Line(id: "dm-2", from: .sam, to: .me, body: "North gate, by the big tent."),
            Line(id: "dm-3", from: .me, to: .sam, body: "Be there in 10."),
            Line(id: "request-1", from: .stranger, to: .me, body: "Hi! Are you the one with the blue tent?"),
        ],
        accepted: [.sam],
        linked: [],
        group: Group(members: [.sam, .priya, .otherSam], createdBy: .priya, departed: [.otherSam]),
        reactions: [
            Reaction(line: "room-3", by: .sam, emoji: thumbs),
            Reaction(line: "room-3", by: .priya, emoji: thumbs),
            Reaction(line: "room-3", by: .otherSam, emoji: "\u{1F525}"),
            Reaction(line: "room-3", by: .jonas, emoji: heart),
            Reaction(line: "dm-2", by: .me, emoji: thumbs),
            Reaction(line: "dm-2", by: .stranger, emoji: "\u{1F602}"),
            Reaction(line: "group-1", by: .sam, emoji: thumbs),
        ]
    )

    /// Every name is set and distinct, every message of ours delivered, and three peers are linked, as in knit-next's
    /// store screenshots. Theo is over the ridge, out of range: his posts came relayed.
    static let marketing = Self(
        me: Own(name: "Maya Okonkwo", status: "On the trail 🥾", portrait: .campfire),
        people: [
            Person(slot: .sam, name: "Sam Rivera", status: "Trail mix enthusiast", openToChat: true, portrait: .lake),
            Person(slot: .dani, name: "Dani Cho", status: "Summit or bust", verified: true, openToChat: true, portrait: .summit),
            Person(slot: .theo, name: "Theo Blake", status: "Mostly lost"),
            Person(slot: .priya, name: "Priya N.", status: "Golden hour chaser 🌅", portrait: .sunset),
            Person(slot: .jonas, name: "Jonas W.", status: "Will hike for coffee"),
            Person(slot: .lena, name: "Lena F.", status: "Map nerd", portrait: .forest),
            Person(slot: .river, name: "River Salas", status: "Just got here"),
        ],
        lines: [
            Line(id: "dm-dani-1", from: .dani, to: .me, body: "Hey! Did you make it down okay?", then: .moment),
            Line(
                id: "dm-dani-2",
                from: .me,
                to: .dani,
                body: "Yeah, just got back. That last descent was sketchy 😅",
                delivered: true,
                then: .moment
            ),
            Line(id: "dm-dani-3", from: .dani, to: .me, body: "Told you the trekking poles were worth it 😏", then: .halfHour),
            Line(
                id: "dm-dani-4",
                from: .me,
                to: .dani,
                body: "Fine, you were right. Same time next weekend?",
                delivered: true,
                then: .moment
            ),
            Line(id: "dm-dani-5", from: .dani, to: .me, body: "Absolutely. I'll bring the good coffee ☕", then: .halfHour),
            Line(id: "dm-dani-6", from: .me, to: .dani, body: "Deal.", delivered: true, then: .halfHour),
            Line(id: "room-1", from: .theo, to: nil, body: "Anyone else seeing the storm roll in over the ridge? ⛈️"),
            Line(id: "room-2", from: .priya, to: nil, body: "Yeah, just felt the first drops. Heading back to camp.", then: .moment),
            Line(id: "room-3", from: .me, to: nil, body: "Same here. The east trail's already mud.", delivered: true, then: .quarterHour),
            Line(id: "room-4", from: .sam, to: nil, body: "Trail's clear up top, Maya 🎉 Come join us!"),
            Line(id: "room-5", from: .dani, to: nil, body: "Saved you a spot by the fire 🔥", then: .moment, photo: .campfire),
            Line(id: "room-6", from: .me, to: nil, body: "On my way, give me 20.", delivered: true),
            Line(id: "group-1", from: .dani, to: nil, body: "Sunrise hike tomorrow? Trailhead at 5 🌅", then: .moment, inGroup: true),
            Line(id: "group-2", from: .theo, to: nil, body: "Count me in.", then: .moment, inGroup: true),
            Line(id: "group-3", from: .me, to: nil, body: "I'll bring the stove.", delivered: true, inGroup: true),
            Line(
                id: "request-river-1",
                from: .river,
                to: .me,
                body: "Hi! Saw you on the mesh at the trailhead. Are you with the ridge group?"
            ),
            Line(id: "request-river-2", from: .river, to: .me, body: "No worries if not, just trying to find them 🙂", then: .quarterHour),
            Line(
                id: "room-7",
                from: .lena,
                to: nil,
                body: "Heads up: the bridge near the falls is out. Take the upper loop.",
                then: .moment
            ),
            Line(id: "room-8", from: .jonas, to: nil, body: "Good call, thanks for the warning."),
            Line(id: "dm-sam-1", from: .me, to: .sam, body: "Great hiking with you today!", delivered: true, then: .quarterHour),
            Line(id: "room-9", from: .priya, to: nil, body: "Sunset from the summit is unreal tonight 🌄"),
            Line(id: "dm-sam-2", from: .sam, to: .me, body: "Likewise! Same crew next time?", then: .moment),
            Line(id: "dm-sam-3", from: .sam, to: .me, body: "Oh, and I found your water bottle 💧"),
        ],
        accepted: [.dani, .sam],
        linked: [.sam, .dani, .priya],
        group: Group(members: [.dani, .sam, .theo], createdBy: .me, name: "Summit crew"),
        reactions: [
            Reaction(line: "dm-dani-3", by: .me, emoji: "\u{1F602}"),
            Reaction(line: "room-5", by: .me, emoji: heart),
            Reaction(line: "room-5", by: .sam, emoji: heart),
            Reaction(line: "room-5", by: .priya, emoji: heart),
            Reaction(line: "room-7", by: .sam, emoji: "\u{1F64F}"),
            Reaction(line: "room-7", by: .priya, emoji: "\u{1F64F}"),
            Reaction(line: "room-7", by: .jonas, emoji: thumbs),
            Reaction(line: "group-1", by: .theo, emoji: thumbs),
            Reaction(line: "group-1", by: .me, emoji: thumbs),
        ]
    )
}
