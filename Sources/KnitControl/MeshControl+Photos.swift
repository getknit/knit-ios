import KnitMesh
import KnitStore
import KnitWire

// A sent message's reply, and a photo sent as a pick would be (ADR 2026-10.f3mv), apart so `MeshControl` stays inside
// the lint's length.
extension MeshControl {
    /// A sent message's reply: its id, whether it waits for a key, the blob its photo is kept under, and for a photo
    /// whether it went as a picture this node already held.
    static func sent(_ record: MessageRecord, reusing photo: OutgoingPhoto?) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "id": .string(record.id), "pendingKey": .bool(record.pendingKey), "attachmentHash": .text(record.attachment?.hash.string),
        ]
        if let photo {
            fields["reused"] = .bool(photo.identity != nil)
        }
        return fields
    }

    /// `photo` as the picture this node already holds it as, the way a pick goes (ADR 2026-10.f3mv), or as given.
    func identified(_ photo: OutgoingPhoto?) async -> OutgoingPhoto? {
        guard let photo else {
            return nil
        }
        return await actions.heldPhoto(picked: photo.bytes) ?? photo
    }
}
