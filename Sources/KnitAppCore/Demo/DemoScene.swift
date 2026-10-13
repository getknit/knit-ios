/// Someone's face, which the demo gives them as their profile photo: a picture of a person who does not exist, which only a
/// debug build bundles, named its raw value (ADR 2026-10.2acj).
public enum DemoPortrait: String, Sendable, CaseIterable {
    case maya = "face-maya"
    case sam = "face-sam"
    case dani = "face-dani"
    case theo = "face-theo"
    case priya = "face-priya"
    case jonas = "face-jonas"
    case lena = "face-lena"
    case river = "face-river"
}

/// A photo of a place, which a message in the demo carries and Choose photo picks: a licensed photograph, which only a
/// debug build bundles, named its raw value (ADR 2026-10.2acj).
public enum DemoSnapshot: String, Sendable, CaseIterable {
    /// Peaks in silhouette at dusk.
    case summit = "photo-summit"
    /// The sun going down behind a ridge.
    case sunset = "photo-sunset"
    /// A path through a pine forest.
    case forest = "photo-forest"
    /// A trail across a meadow to the pines.
    case trail = "photo-trail"
    /// A lake under snowy peaks.
    case lake = "photo-lake"
    /// A campfire at night.
    case campfire = "photo-campfire"
}

/// Which cast `-seedDemo` seeds, as `-demoScene` names it.
public enum DemoScene: String, Sendable, CaseIterable {
    /// The states a screen must handle: two peers with one name, a stranger with none, someone blocked, a message still
    /// waiting to be delivered, and nobody linked. The default.
    case edgeCases = "edge-cases"
    /// A first launch: nobody met and nothing in the room, so the chat list shows its first-run card.
    case fresh = "fresh"
    /// A day on the trail for store screenshots and social posts, with three peers linked, and most people wearing a
    /// profile photo. After knit-next's hiking theme (`DemoScenarios.kt`), less what the iPhone does not do yet: voice
    /// notes, LoRa and Internet relays.
    case marketing = "marketing"
    /// The marketing scene with a room far longer than the screen, for the walk that opens one: the lazy stack opens it on
    /// rows whose height it has only guessed.
    case longRoom = "long-room"
    /// The marketing scene with the room down to its opening and one peer linked, and a script that ``DemoDirector``
    /// plays once the room is on screen: the user types and posts, and the room answers. `KnitTrailer` opens the room
    /// while `check.sh trailer` films it for the store's video (ADR 2026-10.g3k9).
    case trailer = "trailer"
    /// The trailer's room with a stranger in it who turns on the user, and a script that waits for the user to report
    /// them: `KnitClips` reports and blocks them, then unblocks them, while `check.sh clips` films it for App Review
    /// (ADR 2026-10.yddp).
    case block = "block"
    /// The trailer's room with a stranger whose post and photo the demo's filters are told to flag, and a script that
    /// posts them: `KnitClips` shows each hidden, the words shown on a tap, the room refusing flagged words, and Settings'
    /// switch, while `check.sh clips` films it for App Review (ADR 2026-10.yddp).
    case filter = "filter"

    /// Who and what the scene seeds.
    var cast: DemoCast {
        switch self {
        case .edgeCases:
            .edgeCases
        case .fresh:
            .fresh
        case .marketing:
            .marketing
        case .longRoom:
            .longRoom
        case .trailer:
            .trailer
        case .block:
            .block
        case .filter:
            .filter
        }
    }

    /// The words the demo's text filter flags in this scene, beyond `-demoSensitive`'s everything.
    public var flaggedWords: Set<String> {
        cast.flaggedWords
    }

    /// The photos the demo's photo filter flags in this scene, beyond `-demoSensitive`'s everything.
    public var flaggedPhotos: Set<DemoSnapshot> {
        cast.flaggedPhotos
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
        /// The photo it carries, made by whoever seeds the scene.
        var photo: DemoSnapshot?
        /// The line it replies to, an earlier one in its thread, which it quotes as Android's composer would (ADR
        /// 2026-10.mn29, `DemoScenarios.kt:54-70`).
        var replyTo: String?
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
    /// Who is typing, and where.
    var typing: [Typist] = []
    /// What ``DemoDirector`` plays once the mesh starts; nothing, in a scene for stills.
    var script: [Cue] = []
    /// The words the demo's text filter flags, for a scene that shows the filter at work (ADR 2026-10.yddp).
    var flaggedWords: Set<String> = []
    /// The photos the demo's photo filter flags, for the same.
    var flaggedPhotos: Set<DemoSnapshot> = []

    private static let thumbs = "\u{1F44D}"
    static let heart = "\u{2764}\u{FE0F}"

    /// Two peers share a name, to show a discriminated label; the stranger has none, to show an alias. Jonas is blocked,
    /// so Settings lists someone and his profile shows the badge. Our room post has a count above one, an emoji outside
    /// the six, and a heart from Jonas that his block hides; Sam's DM has ours, and a stranger's that a DM does not show.
    /// Priya's room post replies to ours, and ours in the group replies to hers. Priya and Sam are typing in the room, and
    /// Jonas too, whom his block hides; Priya is typing in the group.
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
            Line(id: "room-4", from: .priya, to: nil, body: "On my way.", replyTo: "room-3"),
            Line(id: "group-1", from: .priya, to: nil, body: "Who's bringing the tent?", inGroup: true),
            Line(id: "group-2", from: .me, to: nil, body: "I've got it.", inGroup: true, replyTo: "group-1"),
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
        ],
        typing: [Typist(slot: .sam), Typist(slot: .priya), Typist(slot: .jonas), Typist(slot: .priya, inGroup: true)]
    )

    /// Nothing at all, as a phone has before it meets anyone.
    static let fresh = Self(people: [], lines: [], accepted: [], linked: [])

    /// Every name is set and distinct, everyone wears a face, every message of ours delivered, and three peers are linked,
    /// as in knit-next's store screenshots. Theo is over the ridge, out of range: his posts came relayed. Each DM and the
    /// group run longer than a screen, so a shot of one shows a whole conversation; their earlier lines come first in the
    /// list, so they move nothing later, and the chat list keeps its order and its previews.
    static let marketing = Self(
        me: Own(name: "Maya Okonkwo", status: "On the trail 🥾", portrait: .maya),
        people: [
            Person(slot: .sam, name: "Sam Rivera", status: "Trail mix enthusiast", openToChat: true, portrait: .sam),
            Person(slot: .dani, name: "Dani Cho", status: "Summit or bust", verified: true, openToChat: true, portrait: .dani),
            Person(slot: .theo, name: "Theo Blake", status: "Mostly lost", portrait: .theo),
            Person(slot: .priya, name: "Priya N.", status: "Golden hour chaser 🌅", portrait: .priya),
            Person(slot: .jonas, name: "Jonas W.", status: "Will hike for coffee", portrait: .jonas),
            Person(slot: .lena, name: "Lena F.", status: "Map nerd", portrait: .lena),
            Person(slot: .river, name: "River Salas", status: "Just got here", portrait: .river),
        ],
        lines: [
            Line(id: "dm-dani-a", from: .me, to: .dani, body: "Still on for the north ridge?", delivered: true, then: .moment),
            Line(id: "dm-dani-b", from: .dani, to: .me, body: "Yep. I'll wait by the trailhead sign.", then: .moment),
            Line(id: "dm-dani-c", from: .me, to: .dani, body: "Perfect. Bringing extra water.", delivered: true, then: .halfHour),
            Line(id: "dm-dani-d", from: .dani, to: .me, body: "Made it to the top 🏔️ Where are you?", then: .moment, photo: .summit),
            Line(
                id: "dm-dani-e",
                from: .me,
                to: .dani,
                body: "Twenty minutes behind you. Save me some of that view!",
                delivered: true,
                then: .moment
            ),
            Line(id: "dm-dani-f", from: .dani, to: .me, body: "Take your time, the wind's picking up.", then: .halfHour),
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
            Line(id: "group-a", from: .me, to: nil, body: "Everyone make it back to camp?", delivered: true, then: .moment, inGroup: true),
            Line(id: "group-b", from: .sam, to: nil, body: "Yep, drying off by the fire.", then: .moment, inGroup: true),
            Line(id: "group-c", from: .theo, to: nil, body: "Still on the ridge. Took a wrong turn 🙃", then: .moment, inGroup: true),
            Line(id: "group-d", from: .dani, to: nil, body: "Theo 😂 Follow the cairns down.", then: .minutes, inGroup: true),
            Line(
                id: "group-e",
                from: .theo,
                to: nil,
                body: "Found the trail. This is where I am.",
                then: .moment,
                inGroup: true,
                photo: .trail
            ),
            Line(id: "group-f", from: .sam, to: nil, body: "That's the upper loop. You're 20 minutes out.", then: .moment, inGroup: true),
            Line(id: "group-g", from: .theo, to: nil, body: "On my way 🏃", then: .quarterHour, inGroup: true),
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
            Line(id: "dm-sam-a", from: .sam, to: .me, body: "Are you at the lake yet?", then: .moment),
            Line(id: "dm-sam-b", from: .me, to: .sam, body: "Almost. Lost signal about a mile back.", delivered: true, then: .moment),
            Line(id: "dm-sam-c", from: .sam, to: .me, body: "Same. Meet you on the north shore?", then: .moment),
            Line(id: "dm-sam-d", from: .me, to: .sam, body: "See you there 👋", delivered: true, then: .minutes),
            Line(id: "dm-sam-e", from: .sam, to: .me, body: "Water's freezing but worth it 🥶", then: .moment, photo: .lake),
            Line(id: "dm-sam-f", from: .me, to: .sam, body: "Wow. I'm jumping in when I get there.", delivered: true, then: .moment),
            Line(id: "dm-sam-g", from: .sam, to: .me, body: "Brave. I'll have a towel ready.", then: .halfHour),
            Line(id: "dm-sam-1", from: .me, to: .sam, body: "Great hiking with you today!", delivered: true, then: .quarterHour),
            Line(id: "room-9", from: .priya, to: nil, body: "Sunset from the summit is unreal tonight 🌄"),
            Line(id: "dm-sam-2", from: .sam, to: .me, body: "Likewise! Same crew next time?", then: .moment),
            Line(id: "dm-sam-3", from: .sam, to: .me, body: "Oh, and I found your water bottle 💧"),
        ],
        accepted: [.dani, .sam],
        linked: [.sam, .dani, .priya],
        group: Group(members: [.dani, .sam, .theo], createdBy: .me, name: "Summit crew"),
        reactions: [
            Reaction(line: "dm-dani-d", by: .me, emoji: heart),
            Reaction(line: "group-c", by: .dani, emoji: "\u{1F602}"),
            Reaction(line: "group-c", by: .sam, emoji: "\u{1F602}"),
            Reaction(line: "dm-sam-e", by: .me, emoji: "\u{1F525}"),
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

    /// How many posts the long room adds to the marketing scene's: enough that it opens on rows the lazy stack has only
    /// guessed the height of, few enough to seed in a moment.
    private static let longRoomPosts = 240
    /// Every how many posts one from someone else carries a photo.
    private static let longRoomPhotoEvery = 3
    /// What the long room's posts say, in turn: rows of one line, of several, and of an emoji.
    private static let longRoomBodies = [
        "Anyone on the ridge?",
        "Water's running at the second creek crossing. Bring a filter.",
        "Made it to the hut. The fire's going and there's room for four more if anyone's coming down before dark.",
        thumbs,
        "Lost the markers past the boulder field, so we're heading back the way we came.",
    ]

    /// The marketing scene with ``longRoomPosts`` more posts in the room, from everyone in turn, each a few minutes after
    /// the last. Every few from someone else carries a photo, which stands at a spinner's height until it is read.
    static let longRoom: Self = {
        let authors: [Slot] = [.sam, .dani, .theo, .priya, .jonas, .lena, .me]
        let photos = DemoSnapshot.allCases
        let posts = (0..<longRoomPosts).map { index in
            let author = authors[index % authors.count]
            return Line(
                id: "long-\(index)",
                from: author,
                to: nil,
                body: longRoomBodies[index % longRoomBodies.count],
                delivered: author == .me,
                photo: author != .me && index.isMultiple(of: longRoomPhotoEvery) ? photos[index % photos.count] : nil
            )
        }
        return Self(
            me: marketing.me,
            people: marketing.people,
            lines: marketing.lines + posts,
            accepted: marketing.accepted,
            linked: marketing.linked,
            group: marketing.group,
            reactions: marketing.reactions
        )
    }()
}
