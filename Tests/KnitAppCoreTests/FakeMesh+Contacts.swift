import KnitCrypto
import KnitMesh
import KnitStore
import KnitSync
import KnitWire

@testable import KnitAppCore

/// What Add contact asked of a ``FakeMesh``, in order, and whether its pins fail.
struct ContactLog {
    var calls: [String] = []
    var refuses = false
}

// Add contact's half of the fake mesh (ADR 2026-10.tpr5), apart from the class to keep its file inside the lint's length.
extension FakeMesh {
    /// Each `addContact` asked, as `<source> <node id>`, with ` unblocking` when it unblocks.
    var contactCalls: [String] { contactLog.withLock { $0.calls } }

    /// Makes every later ``addContact(_:from:unblock:)`` answer that the pin did not land.
    func refusesContacts() {
        contactLog.withLock { $0.refuses = true }
    }

    /// What `MeshEngine.addContact` does to the stores: our own id and another key write nothing; a scan pins verified,
    /// and a link pins under the stored name, else the card's, and accepts the conversation.
    func addContact(_ card: ContactCard.Card, from source: ContactSource, unblock: Bool) -> ContactAdded {
        let refuses = contactLog.withLock { log in
            log.calls.append("\(source) \(card.nodeId)\(unblock ? " unblocking" : "")")
            return log.refuses
        }
        guard card.nodeId != nodeId else {
            return .ownCode
        }
        let existing = stores.peers.peer(card.nodeId)
        if let existing, existing.publicKey != card.bundle {
            return .mismatch(card.nodeId)
        }
        guard !refuses else {
            return .failed
        }
        if unblock {
            stores.blocks.unblock(card.nodeId, deviceTag: existing?.deviceTag)
        }
        var record = existing ?? PeerRecord(nodeId: card.nodeId, name: "", status: "", publicKey: card.bundle, updatedAt: 0)
        switch source {
        case .scan:
            record.verified = true
        case .link:
            if record.name.isEmpty {
                record.name = card.name
            }
            stores.conversations.accept(card.nodeId.string)
        }
        stores.peers.upsert(record)
        return .added(card.nodeId)
    }

    func ownContactLink() -> ContactCard.Links? {
        keys.flatMap { ContactCard.encode($0, name: stores.ownProfile.load().name, issuedAt: clock) }
    }
}
