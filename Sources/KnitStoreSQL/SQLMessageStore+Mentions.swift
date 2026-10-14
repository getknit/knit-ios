import Foundation
import GRDB
import KnitStore
import KnitWire

extension SQLMessageStore {
    /// The value for a row's `mentions` (schema v14): the CBOR array a frame carries them in, or `NULL` for none.
    static func mentionsValue(_ mentions: [MessageMention]) -> Data? {
        guard !mentions.isEmpty else {
            return nil
        }
        return Data(CBOR.array(mentions.map { Mention(nodeId: $0.nodeId, name: $0.name).cbor }).encoded)
    }

    /// The people a row mentions. `NULL`, or bytes that don't read as a list of mentions, read as nobody, as
    /// `MentionStore.decode` reads malformed JSON (`MessageEntity.kt:331-343`): a mention only adds an alert and a
    /// highlight, so losing one never hides the message.
    static func mentions(_ row: Row) throws -> [MessageMention] {
        guard let data = try row.decode(Data?.self, forColumn: "mentions"),
            case .array(let items) = try? CBOR.decode([UInt8](data))
        else {
            return []
        }
        let mentions = items.compactMap { try? Mention(cbor: $0) }
        guard mentions.count == items.count else {
            return []
        }
        return mentions.map { MessageMention(nodeId: $0.nodeId, name: $0.name) }
    }
}
