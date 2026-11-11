#if os(iOS) && DEBUG
    import Foundation
    import KnitAppCore
    import KnitControl
    import KnitStore
    import KnitWire

    /// `{"cmd":"linkpreview","url":"https://example.com/"}`: fetches the card for a link as the composer would, and says
    /// what came back (ADR 2026-11.hcvg), so a device check can try real sites and a hostile server without typing. A card's
    /// reply carries its container as `blob`, which `dm`, `group-send` or `room` can send with
    /// `"mime":"application/vnd.knit.link-preview"`, as the composer would. `"conv":"nearby"` screens it as a room post's.
    /// It asks the setting nothing: the bridge is a debug build's own. A card fetched in the last ten minutes comes from
    /// the service's memo.
    internal struct LinkPreviewCommand: Decodable {
        static let name = "linkpreview"

        let cmd: String
        let url: String
        /// The thread it would go to: the room's card is screened as a room post's (`nearby`); any other or none is not.
        let conv: String?
        let tag: String?

        /// The command on `line`, when it is this one.
        static func parse(_ line: String) -> Self? {
            guard let command = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)), command.cmd == name else {
                return nil
            }
            return command
        }

        /// The card `session`'s service fetches for ``url``, screened with `screening` when it goes to the room.
        @MainActor
        func answer(_ session: AppSession, screening: PhotoScreening) async -> String {
            var reply: [String: JSONValue] = ["reply": .string(Self.name)]
            if let tag {
                reply["tag"] = .string(tag)
            }
            guard let service = session.linkPreviews?.service else {
                reply["ok"] = false
                reply["error"] = "this build sends no link previews"
                return JSONValue.object(reply).line
            }
            let words = session.textScreening
            let screens =
                conv.map { ExactKey($0) == ExactKey(Conversations.nearby) } == true
                ? LinkPreviewService.RoomScreens(
                    wordsFlagged: { await words?.isAbusive($0, inRoom: true) ?? false },
                    pictureFlagged: { await screening.isExplicit(outgoing: $0) }) : nil
            reply["ok"] = true
            switch await service.fetchCard(url, room: screens) {
            case .card(let blob):
                reply["outcome"] = "card"
                reply["url"] = .string(blob.url)
                reply["host"] = .string(blob.host)
                reply["title"] = .string(blob.title)
                reply["description"] = .text(blob.description)
                reply["imageBytes"] = .int(Int64(blob.image?.count ?? 0))
                reply["imageMime"] = .text(blob.imageMime)
                let encoded = blob.encoded
                reply["blobBytes"] = .int(Int64(encoded.count))
                reply["blob"] = .string(Base64.encode(encoded))
            case .offline:
                reply["outcome"] = "offline"
            case .restricted:
                reply["outcome"] = "restricted"
            case .noCard:
                reply["outcome"] = "noCard"
            }
            return JSONValue.object(reply).line
        }
    }
#endif
