public import KnitCrypto
public import KnitWire

/// One key a peer handed us in a ctl 11, as the receive policy reads it (`PresenceKeyPolicy.Held`,
/// `mesh/crypto/PresenceKeyPolicy.kt:255-261` at knit-next `cad69c77b`): its generation, the key, and the tag of the
/// ratchet root the frame that delivered it opened under (``KnitCrypto/RatchetCrypto/rootTag(_:)``), which tells a new
/// era, a restored sender's, from a late copy of an old one. Printing it shows the generation and the tag's presence only,
/// never the key (``KnitCrypto/PresenceKey``) nor the tag.
public struct HeldPresenceKey: Sendable, Hashable, CustomStringConvertible {
    /// The sender's own order for its keys, positive: never a time of ours, and never compared with a clock.
    public let generation: Int64
    /// The key its blinded adverts' tags are a MAC under.
    public let key: PresenceKey
    /// The tag of the root the delivering frame opened under. Local storage only, never on the wire.
    public let rootTag: Int64

    /// A key held at `generation` under the root tagged `rootTag`.
    public init(generation: Int64, key: PresenceKey, rootTag: Int64) {
        self.generation = generation
        self.key = key
        self.rootTag = rootTag
    }

    /// The key's raw bytes, for a store that keeps them, as a module that does not reach ``KnitCrypto`` reads them. Never
    /// log them.
    public var keyBytes: [UInt8] { key.bytes }

    /// The generation only (`Held.toString`, `PresenceKeyPolicy.kt:260`).
    public var description: String { "HeldPresenceKey(g=\(generation))" }
}

/// A stored presence key: what the policy holds, and when its bytes and root first arrived, on our wall clock
/// (`PeerPresenceKeyEntity`, `data/presencekey/PresenceKeyEntities.kt:44-51` at knit-next `cad69c77b`).
public struct StoredPresenceKey: Sendable, Equatable, CustomStringConvertible {
    /// The key and its era.
    public let held: HeldPresenceKey
    /// When this row's bytes and root first arrived: a re-send of the same key under the same root keeps it.
    public let receivedAt: Int64

    /// A row holding `held` since `receivedAt`.
    public init(held: HeldPresenceKey, receivedAt: Int64) {
        self.held = held
        self.receivedAt = receivedAt
    }

    /// A row read back from a store that keeps the key's raw bytes, or `nil` unless they are a key's 32: only a damaged
    /// file holds anything else, since every write goes through ``PresenceKeyStore/replaceKeys(of:with:now:)``.
    public init?(generation: Int64, keyBytes: [UInt8], rootTag: Int64, receivedAt: Int64) {
        guard let key = PresenceKey(bytes: keyBytes) else {
            return nil
        }
        self.init(held: HeldPresenceKey(generation: generation, key: key, rootTag: rootTag), receivedAt: receivedAt)
    }

    /// The generation only, as ``HeldPresenceKey/description``.
    public var description: String { held.description }
}

/// The presence keys peers handed us over ctl 11 (`PresenceKeyRepository`'s peer half and `PresenceKeyDao`, knit-next
/// `data/presencekey/`, at `cad69c77b`; knit-next ADR 2026-11.xp6d; ADR 2026-11.sv5t): at most three generations per
/// peer, each with the root tag its frame opened under. Receive only: this port keeps no key of its own.
///
/// Like every store here it is synchronous and never throws (ADR 2026-09.nyya): outside a store unit a store that fails
/// answers its fallback, nothing held, and reports the error. So every read a decision rests on runs inside a unit
/// (``StoreTransactor``), where any error fails the unit: the ratchet open that delivers a key reads and writes it in its
/// own unit, and the feed reads the keys with the direct contacts and deletes leavers' keys in one.
///
/// Local only: the database stays out of backups (`StorageDirectory`), as Android keeps these rows out of its
/// (`BackupTables.TRANSIENT`). Android deletes a peer's keys with its peer row (`PeerDao.deleteOrphanPresenceKeys`); this
/// port never deletes a peer row (``PeerStore`` has no delete), so a key goes only when its peer leaves the direct
/// contacts, or at a session's first pass when it is not one.
public protocol PresenceKeyStore: AnyObject, Sendable {
    /// The keys held for `peer`, newest generation first (`heldBy`, `PresenceKeyRepository.kt:70-71`).
    func keys(of peer: NodeId) -> [StoredPresenceKey]

    /// Makes `rows`, the policy's verdict, every key held for `peer`, at `now` (`applyHeld`, `PresenceKeyRepository.kt:77-96`):
    /// a generation not among them goes, and a row already held with the same bytes and root tag keeps its
    /// ``StoredPresenceKey/receivedAt``; any other is stamped `now`.
    func replaceKeys(of peer: NodeId, with rows: [HeldPresenceKey], now: Int64)

    /// Every peer a key is held for, in node id order (`peersWithKeys`, `PresenceKeyRepository.kt:102`).
    func peersWithKeys() -> [NodeId]

    /// Deletes every key `peers` handed us (`deletePeerKeys`, `PresenceKeyRepository.kt:105-108`).
    func deleteKeys(of peers: Set<NodeId>)
}

extension PresenceKeyStore {
    /// The keys held for each of `peers` that holds any, newest first (`presenceKeysFor`, `PresenceKeyRepository.kt:159-164`).
    public func keys(of peers: Set<NodeId>) -> [NodeId: [StoredPresenceKey]] {
        var listing: [NodeId: [StoredPresenceKey]] = [:]
        for peer in peers {
            let held = keys(of: peer)
            if !held.isEmpty {
                listing[peer] = held
            }
        }
        return listing
    }
}
