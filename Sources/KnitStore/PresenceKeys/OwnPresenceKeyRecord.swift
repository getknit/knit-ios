public import KnitCrypto
public import KnitWire

/// One generation of our own presence key (`OwnPresenceKeyEntity`, `data/presencekey/PresenceKeyEntities.kt:17-33` at
/// knit-next `cad69c77b`; ADR 2026-11.prsp): the key our blinded advert's tags are a MAC under, and who may be handed it.
/// At most three are kept: the previous key, the current one (the newest activated) and the next one (never activated,
/// handed to contacts ahead and never aired yet).
///
/// Printing it shows the generation, whether it is activated and how many may hold it, never the key nor who
/// (`Own.toString`, `PresenceKeyPolicy.kt:58-59`): a dated audience says whom the user blocked.
public struct OwnPresenceKeyRecord: Sendable, Equatable, CustomStringConvertible {
    /// Our own order for our keys, positive: `max(last + 1, now)`, never read as a time.
    public let generation: Int64
    /// The key.
    public let key: PresenceKey
    /// Our wall clock when it was minted.
    public let mintedAt: Int64
    /// Our wall clock when it became the one aired, or `nil` while it is the next key.
    public var activatedAt: Int64?
    /// The direct contacts it may be handed to.
    public var audience: Set<NodeId>
    /// The advertiser's high-water mark under it, the last slot and restart aired, or `nil` before it first aired.
    public let mark: PresenceMark?

    /// A key at `generation`.
    public init(
        generation: Int64, key: PresenceKey, mintedAt: Int64, activatedAt: Int64?, audience: Set<NodeId>, mark: PresenceMark? = nil
    ) {
        self.generation = generation
        self.key = key
        self.mintedAt = mintedAt
        self.activatedAt = activatedAt
        self.audience = audience
        self.mark = mark
    }

    /// A row read back from a store that keeps the key's raw bytes, or `nil` unless they are a key's 32: only a damaged
    /// file holds anything else.
    public init?(
        generation: Int64, keyBytes: [UInt8], mintedAt: Int64, activatedAt: Int64?, audience: Set<NodeId>, mark: PresenceMark?
    ) {
        guard let parsed = PresenceKey(bytes: keyBytes) else {
            return nil
        }
        self.init(generation: generation, key: parsed, mintedAt: mintedAt, activatedAt: activatedAt, audience: audience, mark: mark)
    }

    /// The key's raw bytes, for a store that keeps them, as a module that does not reach ``KnitCrypto`` reads them. Never
    /// log them.
    public var keyBytes: [UInt8] { key.bytes }

    /// The generation, the role and the audience's size only.
    public var description: String {
        "OwnPresenceKeyRecord(g=\(generation), activated=\(activatedAt != nil), audience=\(audience.count))"
    }
}

/// The advertiser's high-water mark under one of our keys (`TagSchedule.Mark`): the last slot and restart it aired, so no
/// pair is aired twice.
public struct PresenceMark: Sendable, Equatable {
    /// The slot (``KnitCrypto/BlindTag/slotOf(wallMilliseconds:)``).
    public let slot: Int64
    /// The restart within it.
    public let restart: Int

    /// A mark at `slot` and `restart`.
    public init(slot: Int64, restart: Int) {
        self.slot = slot
        self.restart = restart
    }
}

/// What a durable write of the advertiser's mark came to (`PresenceKeyRepository.markStore`'s `write`,
/// `data/presencekey/PresenceKeyRepository.kt:184-251` at knit-next `cad69c77b`). Only ``durable`` lets a tag air.
public enum PresenceMarkWrite: Sendable, Equatable {
    /// Committed at `synchronous=FULL`.
    case durable
    /// The generation is gone or no longer the current key: a rotation demoted it, so nothing may air under it.
    case refused
    /// The commit would not have run at `synchronous=FULL`, so it was rolled back.
    case notFull
    /// Asked inside a store unit, where SQLite refuses the pragma: refused at once, before anything ran.
    case insideUnit
    /// The store failed.
    case failed
}
