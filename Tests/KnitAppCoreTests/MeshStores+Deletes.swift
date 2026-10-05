import KnitMesh
import KnitStore
import KnitWire

@testable import KnitAppCore

extension MeshStores {
    /// What the engine does to the stores for a message's delete (`MeshEngine+Deletes.swift`, ADR 2026-10.u7cq): a status
    /// line stays, and a thread accepted now is accepted outright before its rows go.
    func deleteMessage(_ id: String, at now: Int64, me: NodeId) -> Bool {
        guard let record = messages.message(id), !record.kind.isNotice else {
            return false
        }
        keepAccepted(record.conversationId, me: me)
        return messages.deleteMessage(id, at: now) != nil
    }

    /// What the engine does to the stores for a chat's delete.
    func deleteChat(_ conversationId: String, at now: Int64, me: NodeId) -> Bool {
        keepAccepted(conversationId, me: me)
        return !messages.deleteMessages(in: conversationId, at: now).isEmpty
    }

    private func keepAccepted(_ conversationId: String, me: NodeId) {
        let table = ThreadTable(stores: self, me: me, verified: peers.verifiedNodeIds(), blocked: blocks.blockedNodeIds())
        if conversationId != Conversations.nearby, !table.isRequest(conversationId) {
            conversations.accept(conversationId)
        }
    }
}
