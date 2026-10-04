#if os(iOS) && DEBUG
    import Foundation
    import KnitAppCore
    import KnitControl
    import KnitMesh
    import KnitStore
    import KnitWire
    import UIKit

    /// `{"cmd":"photos","conv":"nearby"}`: whether each photo in a thread shows, decoded as the thread draws it: read
    /// from the blob store, opened in memory with its message's key when it is sealed, and read by ImageIO under the
    /// rules for a photo from the mesh (ADR 2026-10.6cas), and whether the content filter hides it behind a tap (ADR
    /// 2026-10.rpmq). The control lines say whether a photo's bytes are here, and only the app can say whether they open
    /// or hide, so the bridge answers it rather than ``MeshControl``.
    internal struct PhotosCommand: Decodable {
        static let name = "photos"
        /// The size each photo decodes at: the viewer's, past any photo the mesh carries.
        private static let pixels = 2048

        let cmd: String
        let conv: String
        let tag: String?

        /// The command on `line`, when it is this one.
        static func parse(_ line: String) -> Self? {
            guard let command = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)), command.cmd == name else {
                return nil
            }
            return command
        }

        /// Every photo in the thread, with whether it shows, at what size, and whether `screening` hides it.
        @MainActor
        func answer(_ session: AppSession, photos: BlobImageCache, screening: PhotoScreening) async -> String {
            var reply: [String: JSONValue] = ["reply": .string(Self.name), "ok": true, "conv": .string(conv)]
            if let tag {
                reply["tag"] = .string(tag)
            }
            var lines: [JSONValue] = []
            for message in session.stores.messages.messages(in: conv) {
                guard let attachment = message.attachment else {
                    continue
                }
                let image = await photos.attachment(attachment.hash, key: attachment.key, pixels: Self.pixels)
                var hidden = false
                // Held or not, the screen reads the store itself, and lets missing bytes through.
                if let shown = ChatAttachment(attachment, isHeld: true) {
                    hidden = await screening.hides(shown, isMine: message.senderId == session.identity.nodeId)
                }
                lines.append(
                    .object([
                        "id": .string(message.id),
                        "hash": .string(attachment.hash.string),
                        "sealed": .bool(attachment.key != nil),
                        "shown": .bool(image != nil),
                        "hidden": .bool(hidden),
                        "width": .int(Int64(image?.size.width ?? 0)),
                        "height": .int(Int64(image?.size.height ?? 0)),
                    ])
                )
            }
            reply["photos"] = .array(lines)
            return JSONValue.object(reply).line
        }
    }
#endif
