public import KnitCrypto
import KnitStore
public import KnitWire

/// Where a card being added came from, which decides what adding it does (ADR 2026-10.tpr5).
public enum ContactSource: Sendable, Equatable {
    /// A contact link or a pasted card (`ContactImporter.import` and `MeshManager.importContact`): pins, accepts and
    /// asks the neighbours for the profile, and never marks the person verified, since the channel it came over is not
    /// authenticated (docs/CONTACT_CARD.md §3).
    case link
    /// A code scanned off the person's own screen (`AddContactViewModel.onScanned`): pins and marks them verified, and
    /// sends nothing.
    case scan
}

/// What adding a contact did.
public enum ContactAdded: Sendable, Equatable {
    /// The key is pinned for this person, now or before.
    case added(NodeId)
    /// The card is our own; nothing was written.
    case ownCode
    /// A different key is pinned for this person; nothing was written.
    case mismatch(NodeId)
    /// The card's bundle does not parse, or the pin did not land in the store.
    case failed
}

extension MeshEngine {
    /// Pins `card`'s key for its owner, from a link or a scan (ADR 2026-10.tpr5, knit-next ADR 042). The card certified
    /// itself before it got here (``ContactCard/parse(_:)``); the engine checks again that its bundle derives to its id,
    /// since a ``ContactCard/Card`` can be made by hand.
    ///
    /// - Our own card answers ``ContactAdded/ownCode`` before anything is written, the block list included.
    /// - A row whose pinned key differs answers ``ContactAdded/mismatch(_:)``, and nothing is written. Kotlin's import
    ///   writes over it unchecked (`ContactImporter.kt:97-114`), relying on its preview; this port checks here as well,
    ///   since a pinned key never changes.
    /// - The row written starts from the row held, never a fresh one: the store replaces whole rows, and a fresh one would
    ///   drop the capabilities, prekey, device tag and watermarks a profile pinned, and the ratchet with them. Only a node
    ///   with no row gets a fresh one, both watermarks at 0, so the first profile that comes applies in full, whatever its
    ///   version (`PeerEntity(id)`, as Kotlin's `(existing ?: PeerEntity(id)).copy(…)`).
    /// - A scan (`AddContactViewModel.kt:221-267`) pins with no name, as Kotlin's scan drops the card's, or finds the same
    ///   key pinned, and marks the person verified. It sends nothing and reads no block.
    /// - A link (`ContactImporter.kt:97-114`, `MeshManager.kt:1108-1113`) lifts a block first when `unblock` says so, pins
    ///   with the name held unless that is blank, the card's otherwise, keeps `verified` as it was, accepts the chat, and
    ///   asks the neighbours for the profile (``requestKey(_:)``, `keyExchange.want`). The intro Kotlin's import also
    ///   registers is not ported.
    ///
    /// Once the pin lands, the frames parked for its key are delivered, after a block that follows the device tag held,
    /// as ``handleProfile(_:_:)`` ends. Kotlin releases them only there (`InboundPipeline.kt:3649`), so on Android they
    /// wait for the profile or age out; here they land, which is safe because the key is the one the id derives from.
    /// What waits for the profile still waits, as on Android: our `pendingKey` messages, which then go with the ratchet
    /// if the profile carries it, and an answer owed to an init of theirs, which needs their prekey. No proof frame is
    /// kept, since there is none, so neither ``KeyExchange/serveKey(_:)`` nor custody can hand this key on.
    ///
    /// Not a store unit, and never called from inside one: ``PeerStore/upsert(_:)`` reports no error, so the row is read
    /// back, and a pin that did not land answers ``ContactAdded/failed`` with nothing sent.
    public func addContact(_ card: ContactCard.Card, from source: ContactSource, unblock: Bool) -> ContactAdded {
        guard card.nodeId != nodeId else {
            return .ownCode
        }
        guard let bundle = PublicKeyBundle(encoded: card.bundle), bundle.nodeId == card.nodeId else {
            log.log(.warning, "mesh added no contact: the card's bundle does not certify \(card.nodeId)")
            return .failed
        }
        let peer = card.nodeId
        let existing = stores.peers.peer(peer)
        if let existing, !existing.publicKey.utf8.elementsEqual(card.bundle.utf8) {
            log.log(.warning, "mesh refused a contact card for pinned \(peer): its key differs")
            return .mismatch(peer)
        }
        if source == .link, unblock {
            self.unblock(peer)
        }
        var record = existing ?? PeerRecord(nodeId: peer, name: "", status: "", publicKey: card.bundle, updatedAt: 0)
        switch source {
        case .scan:
            record.verified = true
        case .link:
            if TextLimits.isBlank(record.name) {
                record.name = card.name
            }
        }
        if record != existing {
            stores.peers.upsert(record)
        }
        guard let landed = stores.peers.peer(peer), landed.publicKey.utf8.elementsEqual(card.bundle.utf8),
            source == .link || landed.verified
        else {
            log.log(.warning, "mesh added no contact: the pin for \(peer) did not land")
            return .failed
        }
        if source == .link {
            accept(peer.string)
        }
        _ = continueBlock(of: peer, deviceTag: landed.deviceTag)
        events.append(.peerUpdated(peer))
        log.log(.info, "mesh pinned \(peer) from a contact card")
        // Replay skips the router: each was admitted, and its relay scheduled, when it first arrived.
        for parked in pendingInbound.release(peer) {
            deliver(parked.frame)
        }
        if source == .link {
            requestKey(peer)
        }
        return .added(peer)
    }

    /// Our own contact card in its three forms (`ContactCards.mint`): our bundle, the name our profile carries, and the
    /// wall clock as its issue time, signed by our identity. It names no relays. `nil` only if signing fails.
    public func ownContactLink() -> ContactCard.Links? {
        ContactCard.encode(identity, name: stores.ownProfile.load().name, issuedAt: clock.wallMilliseconds())
    }
}
