import KnitSync
public import KnitWire

/// A peer whose profile this node has pinned (`PeerEntity` in knit-next, the fields the MVP reads).
///
/// The key is pinned on the first profile whose key derives to the node id, and never changes after. The
/// presentation fields follow the newest profile, ordered by ``updatedAt``, and the prekey follows its own watermark,
/// ``prekeyProfileAt``.
public struct PeerRecord: Sendable, Equatable {
    /// The peer.
    public var nodeId: NodeId
    /// The display name, at most 32 UTF-16 units; empty shows the alias.
    public var name: String
    /// The status line, at most 100 UTF-16 units.
    public var status: String
    /// The pinned public key bundle, base64.
    public var publicKey: String
    /// The key-independent device tag, if the peer sent one.
    public var deviceTag: String?
    /// The peer's protocol version, from its profile.
    public var protocolVersion: Int?
    /// The peer's capability bits, from its signed profile: the copy that gates what we send.
    public var capabilities: Int64?
    /// The presentation watermark: the newest profile's `version`, or its `sentAt` when it has none, clamped to
    /// five minutes past our clock.
    public var updatedAt: Int64
    /// Whether the user compared safety numbers and marked the peer verified.
    public var verified: Bool
    /// Whether the peer invites DMs from people it has not met.
    public var openToChat: Bool
    /// The profile photo shown: one whose bytes are held (`PeerEntity.avatarHash`). It follows
    /// ``advertisedAvatarHash`` once those bytes land, so the photo never blanks while a new one travels.
    public var avatarHash: BlobHash?
    /// The photo the newest signed profile names, held or not: the one to fetch while it differs from
    /// ``avatarHash``. `nil` when that profile names none, or names a hash that is not one.
    public var advertisedAvatarHash: BlobHash?
    /// The peer's ratchet prekey (`PeerEntity.prekeyId`, `prekeyPub` and `prekeySig`), kept only once its signature
    /// verified against the key in the same profile, and its public value was 32 bytes (`InboundPipeline.kt:3353-3368`).
    /// `nil` when the newest profile on ``prekeyProfileAt`` carried none, or a bad one: that clears it.
    public var prekey: PrekeyInfo?
    /// The prekey's watermark (`PeerEntity.prekeyProfileAt`): the `version` of the profile that last set or cleared
    /// ``prekey``, clamped as ``updatedAt`` is, or 0 before any. It moves apart from ``updatedAt``, because a sealed
    /// profile update moves the presentation and carries no prekey (`InboundPipeline.kt:3276-3287`).
    public var prekeyProfileAt: Int64
    /// When a signed frame of this peer's last reached us, by its own `sentAt` capped at our wall clock and floored at 0
    /// (`PeerEntity.lastSeenAt`, knit-next ADR 2026-10.k8ge): what lets a stranger's name clash fade once they have been
    /// quiet for a week. It never moves back (``PeerStore/upsert(_:)`` keeps the larger, ``PeerStore/markSeen(_:gate:)``
    /// only raises it), and 0 means never heard since the column came.
    ///
    /// Presentation only. The peer picks the stamp and custody replays it for hours, so it must never feed a presence tier,
    /// a route, custody, a fetch order or an eviction order; `PresenceTracker`'s own `lastSeenAt` is a different, local
    /// clock. Android also reads it in `PeerDao.facesNeedingFetch` (the face re-want order, knit-next ADR 2026-11.4ckq) and
    /// `MeshcoreClaim.kt:207`; this port takes neither. A new reader here needs an amendment to the ADR that ports the fade
    /// and the blobs reviewer.
    public var lastSeenAt: Int64

    /// Makes a record.
    public init(
        nodeId: NodeId,
        name: String,
        status: String,
        publicKey: String,
        deviceTag: String? = nil,
        protocolVersion: Int? = nil,
        capabilities: Int64? = nil,
        updatedAt: Int64,
        verified: Bool = false,
        openToChat: Bool = false,
        avatarHash: BlobHash? = nil,
        advertisedAvatarHash: BlobHash? = nil,
        prekey: PrekeyInfo? = nil,
        prekeyProfileAt: Int64 = 0,
        lastSeenAt: Int64 = 0
    ) {
        self.nodeId = nodeId
        self.name = name
        self.status = status
        self.publicKey = publicKey
        self.deviceTag = deviceTag
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.updatedAt = updatedAt
        self.verified = verified
        self.openToChat = openToChat
        self.avatarHash = avatarHash
        self.advertisedAvatarHash = advertisedAvatarHash
        self.prekey = prekey
        self.prekeyProfileAt = prekeyProfileAt
        self.lastSeenAt = lastSeenAt
    }

    /// The stamp a row must be older than for `markSeen` to raise it to `at`: `at - gate` (`PeerRepository.flushSeen`'s
    /// `olderThan`), or `nil` where that would overflow, which raises nothing. Both stores compute it here, so they agree.
    public static func seenThreshold(at: Int64, gate: Int64) -> Int64? {
        let (olderThan, overflow) = at.subtractingReportingOverflow(gate)
        return overflow ? nil : olderThan
    }
}

/// The pinned peers (`PeerRepository` in knit-next).
public protocol PeerStore: AnyObject, Sendable {
    /// The pinned peer, or `nil`.
    func peer(_ nodeId: NodeId) -> PeerRecord?

    /// Inserts or replaces a peer, but for ``PeerRecord/lastSeenAt``, which keeps the larger of the row's and `peer`'s
    /// (`PeerDao.upsertRow`'s `MAX(peers.lastSeenAt, excluded.lastSeenAt)`): every writer reads the row, changes it and
    /// writes it back, and a copy read before a ``markSeen(_:gate:)`` must not take its stamp back.
    func upsert(_ peer: PeerRecord)

    /// Raises each row's ``PeerRecord/lastSeenAt`` to its stamp in `stamps` where the row's is older than the stamp by more
    /// than `gate` (`PeerDao.markSeen`, `lastSeenAt < at - gate`), in one write, and answers the ids whose row changed, or
    /// `nil` when the write failed, which changed nothing. A stamp for a node with no row writes nothing.
    func markSeen(_ stamps: [NodeId: Int64], gate: Int64) -> Set<NodeId>?

    /// Every row's ``PeerRecord/lastSeenAt``, and nothing else of it (`PeerDao.namesAll`): what primes the bank's memory of
    /// what it wrote, without decoding every key and prekey.
    func lastSeenStamps() -> [NodeId: Int64]

    /// Every peer the user marked verified.
    func verifiedNodeIds() -> Set<NodeId>

    /// Every pinned peer, for the UI and diagnostics.
    func allPeers() -> [PeerRecord]

    /// Keeps `frame`, the signed `profile` frame `nodeId`'s key was just pinned from, as the proof of that key this
    /// node hands on (`PeerRepository.recordProfileFrame`, knit-next ADR 2026-09.g64k). A copy already held that is
    /// stamped `sentAt` or later stays, so the newest publish wins in any arrival order. The peer picks the stamp,
    /// so the caller clamps it first. It is kept as long as its pin, unless it is longer than custody's profile cap, which
    /// the sweep deletes while the pin stays (``deleteProfileFrames(longerThan:)``).
    func recordProfileFrame(_ frame: WireEnvelope, of nodeId: NodeId, sentAt: Int64)

    /// `nodeId`'s kept proof of key, its signed bytes verbatim in a point-to-point wrapper, or `nil`.
    func profileFrame(of nodeId: NodeId) -> WireEnvelope?

    /// Deletes every kept proof of key whose `signed` is longer than `maxSignedBytes`, custody's profile cap, which a build
    /// without that cap kept, and answers how many (ADR 2026-10.r88m). The pins stay: a pin is only its key, and the key
    /// it holds stays valid. Such a pin then holds no proof to hand on, as a contact card's pin holds none, until its
    /// sender's next profile under the cap arrives. A function of the row alone, so it finds nothing once they are gone.
    @discardableResult
    func deleteProfileFrames(longerThan maxSignedBytes: Int) -> Int
}

/// A ``PeerStore`` in memory, safe to share across threads.
public final class MemoryPeerStore: PeerStore {
    private let peers = Lock<[NodeId: PeerRecord]>([:])
    private let profiles = Lock<[NodeId: (frame: WireEnvelope, sentAt: Int64)]>([:])

    /// An empty store.
    public init() {
        // Nothing to set up.
    }

    public func peer(_ nodeId: NodeId) -> PeerRecord? {
        peers.withLock { $0[nodeId] }
    }

    public func upsert(_ peer: PeerRecord) {
        peers.withLock { peers in
            var row = peer
            row.lastSeenAt = max(peer.lastSeenAt, peers[peer.nodeId]?.lastSeenAt ?? peer.lastSeenAt)
            peers[peer.nodeId] = row
        }
    }

    public func markSeen(_ stamps: [NodeId: Int64], gate: Int64) -> Set<NodeId>? {
        peers.withLock { peers in
            var changed: Set<NodeId> = []
            for (nodeId, at) in stamps {
                guard let olderThan = PeerRecord.seenThreshold(at: at, gate: gate), let held = peers[nodeId]?.lastSeenAt,
                    held < olderThan
                else {
                    continue
                }
                peers[nodeId]?.lastSeenAt = at
                changed.insert(nodeId)
            }
            return changed
        }
    }

    public func lastSeenStamps() -> [NodeId: Int64] {
        peers.withLock { $0.mapValues(\.lastSeenAt) }
    }

    public func verifiedNodeIds() -> Set<NodeId> {
        peers.withLock { Set($0.values.filter(\.verified).map(\.nodeId)) }
    }

    public func allPeers() -> [PeerRecord] {
        peers.withLock { $0.values.sorted { $0.nodeId < $1.nodeId } }
    }

    public func recordProfileFrame(_ frame: WireEnvelope, of nodeId: NodeId, sentAt: Int64) {
        profiles.withLock { profiles in
            if let held = profiles[nodeId], held.sentAt >= sentAt {
                return
            }
            profiles[nodeId] = (WireEnvelope(relay: false, sig: frame.sig, signed: frame.signed), sentAt)
        }
    }

    public func profileFrame(of nodeId: NodeId) -> WireEnvelope? {
        profiles.withLock { $0[nodeId]?.frame }
    }

    public func deleteProfileFrames(longerThan maxSignedBytes: Int) -> Int {
        profiles.withLock { profiles in
            let before = profiles.count
            profiles = profiles.filter { $0.value.frame.signed.count <= maxSignedBytes }
            return before - profiles.count
        }
    }
}

extension MemoryPeerStore: Checkpointing {
    /// Every pin and every kept proof of key, together.
    public func checkpoint() -> StoreCheckpoint {
        let pinned = peers.withLock { $0 }
        let proofs = profiles.withLock { $0 }
        return StoreCheckpoint { [self] in
            peers.withLock { $0 = pinned }
            profiles.withLock { $0 = proofs }
        }
    }
}
