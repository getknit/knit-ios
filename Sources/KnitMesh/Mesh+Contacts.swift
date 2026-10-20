public import KnitCrypto

extension Mesh {
    /// Pins a contact card's key, from a link or a scanned code (``MeshEngine/addContact(_:from:unblock:)``, ADR
    /// 2026-10.tpr5).
    public func addContact(_ card: ContactCard.Card, from source: ContactSource, unblock: Bool) -> ContactAdded {
        let added = engine.addContact(card, from: source, unblock: unblock)
        settle()
        return added
    }

    /// Our own contact card, signed now (``MeshEngine/ownContactLink()``).
    public func ownContactLink() -> ContactCard.Links? {
        engine.ownContactLink()
    }
}
