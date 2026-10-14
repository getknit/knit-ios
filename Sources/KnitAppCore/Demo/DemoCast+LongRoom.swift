// The long room, apart from `DemoScene.swift` only to keep that file under the lint's length.
extension DemoCast {
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
    /// the last. Every few from someone else carries a photo, which stands at a spinner's height until it is read. Nobody
    /// has read anyone else's, so the room's row counts in the hundreds: the widest count the chat list draws.
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
                photo: author != .me && index.isMultiple(of: longRoomPhotoEvery) ? photos[index % photos.count] : nil,
                unread: author != .me
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
