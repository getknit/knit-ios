import KnitWire

/// This device's ratchet prekeys, kept beside the identity in its ``SecretStore`` (the prekey half of knit-next's
/// `data/crypto/IdentityKeyStore.kt`: `currentPrekey`, `rotatePrekeyIfDue`, `rotatePrekey` and `prekeyPrivFor`,
/// `:84-128`, and `mint`, `:189-202`). A profile publishes the newest (``newest``), and a peer's X3DH init names the one
/// it started from, which ``prekey(id:)`` finds while it is kept. This port publishes none while the ratchet's switch is
/// off (ADR 2026-10.5sk9).
///
/// **The stored form grows additively.** The store holds `{signingSeed, agreementScalar}`
/// (``IdentityKeys/storedForm``), read by key, so the prekeys join it as a third key and an older build still loads
/// its identity from the grown map: `{signingSeed, agreementScalar, prekeys: [{id, priv, createdAt, sig}]}`, newest
/// first. Each signature is kept from its mint, because CryptoKit randomizes Ed25519; Android signs again on every
/// read (`IdentityKeyStore.kt:209-217`), since Tink's is deterministic.
///
/// **Loading never writes.** A store that holds no prekeys, or another identity's, gives an empty ring, and a store
/// that cannot answer throws, as ``IdentityKeys/load(from:)`` does, so a read before the first unlock is never taken
/// for an empty ring. A stored prekey whose private key makes no key, or whose signature this identity does not
/// verify, is left out of the ring: a peer refuses such a prekey and clears the pin it held for us
/// (`InboundPipeline.kt:3322-3332`).
///
/// **Rotation** mints a new prekey when the ring is empty or the newest is a week old (`SPK_ROTATE_MS`, `:272-276`).
/// Its id is one above the highest id any stored entry names, read or not, the first being 1: a peer may hold an id
/// we published under another public value. Android's restore mints `max(stored) + 1` too (`IdentityKeyStore.kt:195`)
/// and bumps the profile so peers take the new key over an old one under that id (`MeshManager.kt:1011-1016`). It
/// keeps the five highest ids this build reads (`SPK_KEEP`), each entry as it was stored, so a field a newer build added
/// survives. An entry this build cannot read is written back as it was stored
/// and neither counts toward the five nor is ever pruned. Android never mints over prekeys it cannot parse
/// (`IdentityKeyStore.kt:136-137`) and prunes only records it parsed (`:197`). Such an entry may be a newer build's
/// prekey that a peer's init names, and dropping it cannot be undone, while this build never writes one, so the
/// count cannot grow. A `prekeys` entry that is not one list is not minted over at all.
///
/// The write reads the store, checks that the identity there is this one byte for byte, replaces the `prekeys` entry
/// alone and keeps every other entry, writes, and reads back. The ring changes only once all of that succeeds, so a
/// refused write leaves it as it was, and no profile names a prekey whose private half the store does not hold. Key
/// material comes from `keyPair`, the system's generator unless a test fixes it, never the mesh's injected generator
/// (`crypto.md`).
///
/// **The inits this identity answered** ride the same item as a fourth key, `answered`, which loading reads with the
/// prekeys and an older build ignores and writes back as it was stored (``answeredInits``,
/// ``keepAnswered(_:from:now:)``, ADR 2026-10.wcex): a reinstall keeps them with the prekeys, and so knows the peer's
/// opener custody serves back to it for a day as an init it answered in a life whose sessions it has lost.
public struct PrekeyRing: Sendable {
    /// How old the newest prekey grows before a new one is minted: a week (`SPK_ROTATE_MS`).
    public static let rotationMilliseconds: Int64 = 604_800_000
    /// How many prekeys are kept, the newest and four before it, so an init made against one recently replaced still
    /// opens (`SPK_KEEP`).
    public static let keptCount = 5

    private static let prekeysKey = "prekeys"
    private static let idKey = "id"
    private static let privateKeyKey = "priv"
    private static let createdAtKey = "createdAt"
    private static let signatureKey = "sig"
    /// The largest id the wire's `PrekeyInfo.id`, a Kotlin `Int`, carries.
    private static let largestId = Int(Int32.max)

    /// Why a rotation kept nothing. The ring is as it was, and the next heal tries again.
    public enum Failure: Error, Sendable, Equatable {
        /// The store could not be read or written now: before the first unlock since a reboot, or a full disk.
        case store(SecretStoreError)
        /// The store holds no identity, or another one: the identity was replaced, and a prekey this one signs would be
        /// stored beside keys it does not belong to.
        case identityReplaced
        /// The store keeps its prekeys in a form this build cannot read as a list, a newer build's: minting over them
        /// would lose keys a peer's init may name, which Android refuses too (`IdentityKeyStore.kt:136-137`).
        case unreadablePrekeys
        /// The store keeps the inits it answered in a form this build cannot read as a list, a newer build's, which a
        /// write would lose.
        case unreadableAnswers
        /// The store answered the write, and then held something else.
        case readBack
        /// The identity's key would not sign.
        case signing
        /// The next id would not fit the wire's 32-bit `id`.
        case idsExhausted
    }

    /// The identity's item as stored: its map's entries, and its `prekeys` list entry by entry, in the order stored.
    private struct Item {
        let entries: [CBOR.Entry]
        let prekeys: [StoredEntry]
    }

    /// One entry of the stored `prekeys` list, and what this build reads of it.
    private struct StoredEntry {
        /// The entry as it was stored, written back as it is: decoded and encoded again, which gives the same bytes for
        /// anything a Knit build writes, with definite lengths and the shortest integers (``CBOR``).
        let item: CBOR
        /// The id it names, when that is an integer the wire carries, even if nothing else in it reads.
        let id: Int?
        /// The whole prekey, when this build reads it and the identity verifies it.
        let prekey: SignedPrekey?
    }

    /// The identity that signs these prekeys.
    public let identity: IdentityKeys
    /// The prekeys kept, newest first.
    public private(set) var prekeys: [SignedPrekey]
    /// The inits this identity answered within ``answeredMilliseconds``, as the store held them when the ring loaded or
    /// last wrote them, oldest first (``keepAnswered(_:from:now:)``).
    public internal(set) var answeredInits: [AnsweredInit]
    let store: any SecretStore
    private let keyPair: @Sendable () -> RatchetCrypto.KeyPair

    private init(
        identity: IdentityKeys,
        prekeys: [SignedPrekey],
        answeredInits: [AnsweredInit],
        store: any SecretStore,
        keyPair: @escaping @Sendable () -> RatchetCrypto.KeyPair
    ) {
        self.identity = identity
        self.prekeys = prekeys
        self.answeredInits = answeredInits
        self.store = store
        self.keyPair = keyPair
    }

    /// The prekeys `identity` keeps in `store`, and the inits it answered, without writing anything. Load the identity
    /// first, from the same store. A store that cannot answer throws, so neither is ever taken for empty then.
    @preconcurrency
    public static func load(
        for identity: IdentityKeys,
        from store: some SecretStore,
        keyPair: @escaping @Sendable () -> RatchetCrypto.KeyPair = { RatchetCrypto.generateKeyPair() }
    ) throws(SecretStoreError) -> Self {
        let stored = try store.read()
        let held = (try? item(stored, of: identity))?.prekeys ?? []
        let answered = (try? storedAnswers(stored, of: identity)) ?? []
        return Self(identity: identity, prekeys: ring(of: held), answeredInits: answered, store: store, keyPair: keyPair)
    }

    /// The prekey a profile publishes, or `nil` before the first is minted (`currentPrekey`, `:84-94`).
    public var newest: SignedPrekey? { prekeys.first }

    /// Prekey `id`, or `nil` once it has been dropped (`prekeyPrivFor`, `:122-128`): an init made against it must start
    /// again.
    public func prekey(id: Int) -> SignedPrekey? {
        prekeys.first { $0.id == id }
    }

    /// Mints and keeps a new prekey when the ring is empty or the newest is a week old or more, and answers it; `nil`
    /// when none is due (`rotatePrekeyIfDue`, `:96-109`). A newest prekey stamped so far from `now` that its age does
    /// not fit is due.
    public mutating func rotateIfDue(now: Int64) throws(Failure) -> SignedPrekey? {
        if let newest {
            let (age, overflow) = now.subtractingReportingOverflow(newest.createdAt)
            if !overflow, age < Self.rotationMilliseconds {
                return nil
            }
        }
        return try rotate(now: now)
    }

    /// Mints and keeps a new prekey whatever the newest one's age, and answers it (`rotatePrekey`, `:111-120`, and
    /// `mint`, `:189-202`): a start over a database a reinstall emptied.
    @discardableResult
    public mutating func rotate(now: Int64) throws(Failure) -> SignedPrekey {
        let held = try Self.item(read(), of: identity)
        // Above every id stored, read or not, and every id this ring holds, in case the store lost one since it loaded.
        let id = ((held.prekeys.compactMap(\.id) + prekeys.map(\.id)).max() ?? 0) + 1
        guard id <= Self.largestId else {
            throw .idsExhausted
        }
        let fresh: SignedPrekey
        do {
            fresh = try SignedPrekey.mint(id: id, signedBy: identity, createdAt: now, keyPair: keyPair)
        } catch {
            throw .signing
        }
        let kept = Array(([fresh] + Self.ring(of: held.prekeys)).prefix(Self.keptCount))
        let keptIds = Set(kept.map(\.id))
        // Only an entry this build reads is ever pruned; every other one is written back as it was, in the order stored.
        let list = [Self.cbor(fresh)] + held.prekeys.filter { entry in entry.prekey.map { keptIds.contains($0.id) } ?? true }.map(\.item)
        try persist(.array(list), as: Self.prekeysKey, beside: held.entries)
        prekeys = kept
        return fresh
    }

    // MARK: The store

    /// Writes `value` as the item's `key`, beside every other entry of `entries`, and proves it reads back.
    func persist(_ value: CBOR, as key: String, beside entries: [CBOR.Entry]) throws(Failure) {
        let replaced = CBOR.Entry(key: .text(key), value: value)
        let grown = CBOR.map(
            entries.contains { $0.key == replaced.key } ? entries.map { $0.key == replaced.key ? replaced : $0 } : entries + [replaced]
        )
        .encoded
        do {
            try store.write(grown)
        } catch {
            throw .store(error)
        }
        guard try read() == grown else {
            throw .readBack
        }
    }

    func read() throws(Failure) -> [UInt8]? {
        do {
            return try store.read()
        } catch {
            throw .store(error)
        }
    }

    /// The item `stored` holds for `identity`. It throws when `stored` holds no identity or another one, and when its
    /// `prekeys` is not one list.
    private static func item(_ stored: [UInt8]?, of identity: IdentityKeys) throws(Failure) -> Item {
        let entries = try entries(stored, of: identity)
        let lists = entries.filter { $0.key == .text(prekeysKey) }
        guard let list = lists.first else {
            return Item(entries: entries, prekeys: [])
        }
        guard lists.count == 1, case .array(let items) = list.value else {
            throw .unreadablePrekeys
        }
        let parsed = items.map { item in StoredEntry(item: item, id: storedId(of: item), prekey: prekey(from: item, of: identity)) }
        return Item(entries: entries, prekeys: parsed)
    }

    /// The entries of the item `stored` holds for `identity`. It throws when `stored` holds no identity or another one.
    static func entries(_ stored: [UInt8]?, of identity: IdentityKeys) throws(Failure) -> [CBOR.Entry] {
        guard let stored, holds(identity, in: stored), case .map(let entries) = try? CBOR.decode(stored) else {
            throw .identityReplaced
        }
        return entries
    }

    /// Whether `stored` holds `identity`, read the way ``IdentityKeys/init(storedForm:)`` reads it.
    private static func holds(_ identity: IdentityKeys, in stored: [UInt8]) -> Bool {
        guard let keys = IdentityKeys(storedForm: stored) else {
            return false
        }
        return keys.signingSeed == identity.signingSeed && keys.agreementScalar == identity.agreementScalar
    }

    /// The prekeys this build reads among `entries`, newest first, each id once: the first stored, as `prekeyPrivFor`
    /// finds it.
    private static func ring(of entries: [StoredEntry]) -> [SignedPrekey] {
        var ids = Set<Int>()
        return entries.compactMap(\.prekey).filter { ids.insert($0.id).inserted }.sorted { $0.id > $1.id }
    }

    /// The value of `key` in `item`, when `item` is a map.
    static func field(_ key: String, of item: CBOR) -> CBOR? {
        guard case .map(let fields) = item else {
            return nil
        }
        return fields.last { $0.key == .text(key) }?.value
    }

    /// The id `item` names, or `nil` unless it is an integer that fits the wire, from 1 up.
    private static func storedId(of item: CBOR) -> Int? {
        guard let id = field(idKey, of: item)?.int64, (1...Int64(largestId)).contains(id) else {
            return nil
        }
        return Int(id)
    }

    /// One stored prekey, or `nil` unless its id fits the wire, its private key makes a key, and `identity` verifies its
    /// signature.
    private static func prekey(from item: CBOR, of identity: IdentityKeys) -> SignedPrekey? {
        guard let id = storedId(of: item),
            case .bytes(let privateKey) = field(privateKeyKey, of: item), let pair = try? RatchetCrypto.KeyPair(privateKey: privateKey),
            let createdAt = field(createdAtKey, of: item)?.int64, case .bytes(let signature) = field(signatureKey, of: item),
            identity.bundle.isValidSignature(signature, for: RatchetCrypto.spkSigningBytes(id: id, pub: pair.publicKey))
        else {
            return nil
        }
        return SignedPrekey(id: id, privateKey: pair.privateKey, publicKey: pair.publicKey, signature: signature, createdAt: createdAt)
    }

    /// A new prekey's entry: `{id, priv, createdAt, sig}`.
    private static func cbor(_ prekey: SignedPrekey) -> CBOR {
        .map([
            CBOR.Entry(key: .text(idKey), value: CBOR(Int64(prekey.id))),
            CBOR.Entry(key: .text(privateKeyKey), value: .bytes(prekey.privateKey)),
            CBOR.Entry(key: .text(createdAtKey), value: CBOR(prekey.createdAt)),
            CBOR.Entry(key: .text(signatureKey), value: .bytes(prekey.signature)),
        ])
    }
}
