import KnitCrypto
import KnitMesh
import KnitStore
import KnitSync
import KnitWire

@testable import KnitAppCore

/// What Add contact asked of a ``FakeMesh``, in order, and the answer it gives whatever the stores hold, if one is set.
struct ContactLog {
    var calls: [String] = []
    var answer: ContactAdded?
}

// Add contact's half of the fake mesh (ADR 2026-10.tpr5), apart from the class to keep its file inside the lint's length.
extension FakeMesh {
    /// Each `addContact` asked, as `<source> <node id>`, with ` unblocking` when it unblocks.
    var contactCalls: [String] { contactLog.withLock { $0.calls } }

    /// Makes every later ``addContact(_:from:unblock:)`` give `answer` and write nothing, as the engine does when the
    /// store refuses the pin, or when its re-check finds a key that pinned between the preview and the tap.
    func answersContacts(_ answer: ContactAdded) {
        contactLog.withLock { $0.answer = answer }
    }

    /// What `MeshEngine.addContact` does to the stores: our own id and another key write nothing; a scan pins verified,
    /// and a link pins under the stored name, else the card's, and accepts the conversation.
    func addContact(_ card: ContactCard.Card, from source: ContactSource, unblock: Bool) -> ContactAdded {
        let answer = contactLog.withLock { log in
            log.calls.append("\(source) \(card.nodeId)\(unblock ? " unblocking" : "")")
            return log.answer
        }
        if let answer {
            return answer
        }
        guard card.nodeId != nodeId else {
            return .ownCode
        }
        let existing = stores.peers.peer(card.nodeId)
        if let existing, existing.publicKey != card.bundle {
            return .mismatch(card.nodeId)
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
