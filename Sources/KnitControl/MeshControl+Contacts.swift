import KnitCrypto
import KnitMesh
import KnitWire

extension MeshControl {
    /// Our contact link, signed now, in its three forms (ADR 2026-10.tpr5): what Android's bridge prints for
    /// `INTRO --ez card true` (`DebugBridgeReceiver.kt:1673-1700`).
    func contactLink() async -> Result<[String: JSONValue], ControlError> {
        guard let links = await mesh.ownContactLink() else {
            return .failure(.refused("our identity could not sign a card"))
        }
        return .success(["url": .string(links.url), "scheme": .string(links.scheme), "compact": .string(links.compact)])
    }

    /// Adds the person a contact link or a scanned code names, as Add contact does: `scan` takes the scanner's path, which
    /// verifies them, and a link's path accepts them and asks for their key, unblocking them first when `unblock` says so.
    /// A text that is no card answers why, in Kotlin's words for the reason.
    func addContact(_ text: String, scan: Bool, unblock: Bool) async -> Result<[String: JSONValue], ControlError> {
        let card: ContactCard.Card
        switch ContactCard.parse(text) {
        case .card(let parsed):
            card = parsed
        case .invalid(let reason):
            return .failure(.refused("not a contact card: \(reason)"))
        }
        switch await actions.addContact(card, from: scan ? .scan : .link, unblock: unblock) {
        case .added(let peer):
            return .success(["peer": .string(peer.string), "name": .string(card.name), "verified": .bool(scan)])
        case .ownCode:
            return .failure(.refused("our own card"))
        case .mismatch(let peer):
            return .failure(.refused("another key is pinned for \(peer)"))
        case .failed:
            return .failure(.refused("the pin did not land"))
        }
    }
}
