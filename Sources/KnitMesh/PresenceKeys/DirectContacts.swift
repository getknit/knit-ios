import KnitStore
import KnitWire

/// The people whose presence keys this phone lists to its radio (knit-next ADR 2026-11.xp6d; ADR 2026-11.sv5t): the ones
/// the user chose, and no one someone else's act can add (`directContactIds`, `contacts/DirectContacts.kt:31-42` at knit-next
/// `cad69c77b`), pure. After removing `me` and `blocked` (everyone blocked by id, and every peer whose pinned device tag the
/// user blocked, Android's `blocked` and `blockedByTag`), a direct contact is a DM-kind id in the union of:
/// - `accepted`: a card imported by link, a request accepted;
/// - `verified`: the out-of-band key check, a scanned card's included;
/// - `authored`: a DM thread the user has written in.
///
/// That is ``Acquaintances`` with blocks applied. It is not ``KnitStore/Conversations/isAccepted(_:accepted:verified:authored:groupSenders:)``,
/// which also counts a group's senders, and a group's roster grows by its members' invitations. iOS has no commons, so
/// Android's commons marks have nothing to subtract here. With no unaccept, and with un-verify and a chat's delete both
/// keeping the thread accepted (``MeshEngine/keepAccepted(_:)``), only a block takes anyone out today.
///
/// Ids are parsed, never matched as text: a conversation id is a DM's when it is a canonical node id (``KnitWire/NodeId/init(_:)``),
/// which the room's `nearby` and a group's `g-` id never are.
internal enum DirectContacts {
    /// The direct contacts among the stored facts.
    static func ids(accepted: Set<String>, verified: Set<NodeId>, authored: Set<String>, blocked: Set<NodeId>, me: NodeId) -> Set<NodeId> {
        candidates(accepted: accepted, verified: verified, authored: authored).subtracting(blocked).subtracting([me])
    }

    /// Every DM-kind id the user chose, before any block.
    static func candidates(accepted: Set<String>, verified: Set<NodeId>, authored: Set<String>) -> Set<NodeId> {
        Set(accepted.union(authored).compactMap(dmPeer)).union(verified)
    }

    /// The peer a DM thread's id names, or `nil` for the room, a group, or anything else that is not a canonical node id.
    static func dmPeer(_ conversationId: String) -> NodeId? {
        guard !Conversations.isGroup(conversationId) else {
            return nil
        }
        return NodeId(conversationId)
    }
}

extension MeshEngine {
    /// The direct contacts, read from the stores (``DirectContacts/ids(accepted:verified:authored:blocked:me:)``). Call it
    /// inside a store unit: outside one a failing read answers its fallback, and nobody would read as a contact.
    func directContacts() -> Set<NodeId> {
        let known = Acquaintances(reading: self)
        let candidates = DirectContacts.candidates(accepted: known.accepted, verified: known.verified, authored: known.authored)
        let tagBlocked = candidates.filter { peer in
            stores.peers.peer(peer)?.deviceTag.map(stores.blocks.isBlocked(deviceTag:)) == true
        }
        let blocked = stores.blocks.blockedNodeIds().union(tagBlocked)
        return DirectContacts.ids(
            accepted: known.accepted, verified: known.verified, authored: known.authored, blocked: blocked, me: nodeId)
    }
}
