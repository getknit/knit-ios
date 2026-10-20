public import KnitCrypto
public import KnitMesh

// Add contact (ADR 2026-10.tpr5), apart from the class only to keep its body inside the lint's length.
extension AppSession {
    /// Adds the person a contact link or a scanned code names (ADR 2026-10.tpr5). A link accepts their conversation, which
    /// leaves the requests for the list, and takes back the requests notification once none waits.
    public func addContact(_ card: ContactCard.Card, from source: ContactSource, unblock: Bool) async -> ContactAdded {
        let added = await mesh.addContact(card, from: source, unblock: unblock)
        revision += 1
        syncBadge()
        if threads().requests.isEmpty {
            await notifier?.withdraw(threadId: NotificationPolicy.requestsThread)
        }
        return added
    }

    /// Our contact link, signed now, or `nil` when it could not be.
    public func ownContactLink() async -> ContactCard.Links? {
        await mesh.ownContactLink()
    }
}
