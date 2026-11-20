import KnitCrypto
public import KnitWire

/// The rules a custody store applies to every frame it is handed (`ForwardRepository.store` and `insertAndTrim`
/// in knit-next). They are pure, so every store implementation applies the same ones.
///
/// Every rule reads live frames only. A row past its expiry that has not been swept yet is per-node state (each
/// node sweeps on its own schedule), so letting one count toward a quota would evict different live frames on
/// different nodes (knit-next's work item #8).
public enum CustodyRules {
    /// What the quotas read of a carried frame.
    public struct Entry: Sendable, Equatable {
        /// The frame id.
        public var id: String
        /// The originator.
        public var senderId: String
        /// The group, for a group frame.
        public var groupId: String?
        /// Whether it is a room post (chat, no recipient, no group), the one class the room quota counts.
        public var isRoomChat: Bool
        /// The originator's clock: the eviction key, identical on every node.
        public var sentAt: Int64
        /// When custody ends, also identical on every node.
        public var expiresAt: Int64

        /// Makes an entry.
        public init(id: String, senderId: String, groupId: String?, isRoomChat: Bool, sentAt: Int64, expiresAt: Int64) {
            self.id = id
            self.senderId = senderId
            self.groupId = groupId
            self.isRoomChat = isRoomChat
            self.sentAt = sentAt
            self.expiresAt = expiresAt
        }

        /// The entry for an envelope that expires at `expiresAt`.
        public init(_ envelope: RelayEnvelope, expiresAt: Int64) {
            self.init(
                id: envelope.id,
                senderId: envelope.senderId,
                groupId: envelope.group?.id,
                isRoomChat: envelope.isRoomPost,
                sentAt: envelope.sentAt,
                expiresAt: expiresAt
            )
        }
    }

    /// When custody of a frame would end: its `sentAt` plus its TTL, the room's for a room post and the full one for
    /// everything else (`ForwardRepository.store`, `expiresAt = env.sentAt + ttl`). Every node computes the same instant,
    /// originator and carriers alike. It is computed for a frame custody then refuses too, as the shared vector's
    /// `expiresAt` is (`vectors/custody-v1.json`).
    ///
    /// Kotlin's Long addition wraps, so a hostile `sentAt` near the top of the range lands in the past and is refused.
    /// Wrapping here refuses it the same way instead of trapping.
    public static func expiresAt(of envelope: RelayEnvelope, limits: CustodyLimits) -> Int64 {
        envelope.sentAt &+ (envelope.isRoomPost ? limits.roomChatTTLMilliseconds : limits.ttlMilliseconds)
    }

    /// When custody of a frame ends (``expiresAt(of:limits:)``), or `nil` when its time alone refuses it: already past
    /// that instant (a skewed peer re-serving what everyone has swept, or a `sentAt` of 0), or dated more than five
    /// minutes ahead of `now`, which would make it unsweepable and the newest frame in every bucket. A store admits a
    /// frame through ``admission(of:now:limits:)``, which also applies the byte cap and the group gate.
    public static func expiry(of envelope: RelayEnvelope, now: Int64, limits: CustodyLimits) -> Int64? {
        guard case .admitted(let expiresAt) = timing(of: envelope, now: now, limits: limits) else {
            return nil
        }
        return expiresAt
    }

    /// Whether custody takes a frame, and when it ends if so (`ForwardRepository.store`, `ForwardRepository.kt:79-132`
    /// at knit-next `ce56fec6e`, knit-next ADR 2026-10.mqzv). The refusals come in Kotlin's order: a `signed` longer
    /// than ``CustodyLimits/maxSignedBytes``, then a profile whose `signed` is longer than
    /// ``CustodyLimits/maxProfileSignedBytes`` (``isOversizeProfile(type:signedCount:limits:)``), then dead on arrival,
    /// then past the future window, then a group frame whose roster is not its own (``carriesGroup(_:from:)``, knit-next
    /// ADR 2026-10.7mqm). Each is a function of the frame and `now` alone, so every node refuses alike, and it binds every
    /// origin, our own frames included. The order decides only which reason is counted: an oversize frame naming a foreign
    /// roster is ``CustodyRefusal/oversize``, and the roster counter does not move; a profile over both caps is
    /// ``CustodyRefusal/oversize`` too. Both stores call it before they write, so neither can skip the gate, and a refusal
    /// writes and evicts nothing.
    ///
    /// Both caps count ``CarriedFrame/signed`` alone, never `sig`, and keep a frame of exactly the cap.
    public static func admission(of frame: CarriedFrame, now: Int64, limits: CustodyLimits) -> Admission {
        guard frame.signed.count <= limits.maxSignedBytes else {
            return .refused(.oversize)
        }
        guard !isOversizeProfile(type: frame.envelope.type, signedCount: frame.signed.count, limits: limits) else {
            return .refused(.profileOversize)
        }
        let envelope = frame.envelope
        let timed = timing(of: envelope, now: now, limits: limits)
        guard case .admitted = timed else {
            return timed
        }
        if let group = envelope.group, !carriesGroup(group, from: envelope.senderId) {
            return .refused(.foreignRoster)
        }
        return timed
    }

    /// Whether a frame of `type` with `signedCount` bytes of `signed` is a profile longer than
    /// ``CustodyLimits/maxProfileSignedBytes``: what admission refuses and the sweep deletes, so both read one rule. A
    /// function of the frame's own bytes, so every node that runs it keeps the same profiles, and none can grow past the
    /// cap in any store, however many senders mint one.
    public static func isOversizeProfile(type: FrameType, signedCount: Int, limits: CustodyLimits) -> Bool {
        type == .profile && signedCount > limits.maxProfileSignedBytes
    }

    /// What ``admission(of:now:limits:)`` decides.
    public enum Admission: Sendable, Equatable {
        /// Taken, until the instant given.
        case admitted(expiresAt: Int64)
        /// Refused, for the reason given: never ``CustodyRefusal/writeFailed``, which only a store's write answers.
        case refused(CustodyRefusal)
    }

    /// Whether custody carries a frame naming `group` from `senderId` (`ForwardRepository.carriesGroup`, knit-next ADR
    /// 2026-10.7mqm): its members and departed together derive to the group's id, which is the hash of the founding
    /// roster, and the sender is one of the members. Without it anyone who knew a group's id, which rides every group
    /// frame in the clear, filled that group's quota on every carrier.
    ///
    /// Both compare by the UTF-8 bytes, as Kotlin's `in` and `==` compare code units; Swift's `==` would let a sender
    /// canonically equal to a member pass (ADR 2026-09.jc2x). Nothing else of ``GroupInfo`` is read: no member cap and
    /// none of the roster vetting delivery does, which Android's gate leaves out too. Every group frame a current build of
    /// either platform sends passes. A pre-2.3.0 frame after a departure lists no `departed` and is refused here, though
    /// delivery and relay still take it.
    public static func carriesGroup(_ group: GroupInfo, from senderId: String) -> Bool {
        let sender = ExactKey(senderId)
        return group.members.contains { ExactKey($0) == sender }
            && ExactKey(GroupId.derive(group.members + (group.departed ?? []))) == ExactKey(group.id)
    }

    /// The two refusals a frame's time alone decides, in Kotlin's order.
    private static func timing(of envelope: RelayEnvelope, now: Int64, limits: CustodyLimits) -> Admission {
        let expiresAt = expiresAt(of: envelope, limits: limits)
        guard expiresAt >= now else {
            return .refused(.deadOnArrival)
        }
        guard envelope.sentAt <= now + WireProtocol.maxFutureSkewMilliseconds else {
            return .refused(.aheadOfWindow)
        }
        return .admitted(expiresAt: expiresAt)
    }

    /// Whether `lhs` is evicted before `rhs`: the older `sentAt` first, then the id's bytes, which is how SQLite's
    /// BINARY collation orders `ORDER BY sentAt ASC, id ASC` (`ForwardDao.evictOldestBy*`, and `evictFairest` within a
    /// sender's count).
    public static func evictsBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        guard lhs.sentAt == rhs.sentAt else {
            return lhs.sentAt < rhs.sentAt
        }
        return lhs.id.utf8.lexicographicallyPrecedes(rhs.id.utf8)
    }

    /// The ids to evict once `inserted` has joined `live`, the live entries including it (`insertAndTrim`,
    /// `ForwardRepository.kt` at knit-next `e0cbb842a`), with no holder known for any of them: the old global key.
    public static func evictions(after inserted: Entry, among live: [Entry], limits: CustodyLimits) -> [String] {
        evictions(after: inserted, among: live, limits: limits, carry: NoCustodyCarry())
    }

    /// The ids to evict once `inserted` has joined `live`, the live entries including it (`insertAndTrim`,
    /// `ForwardRepository.kt` at knit-next `e0cbb842a`, and the `custody-carry-policy` contract, §5).
    ///
    /// Each over-quota sender, group and room bucket keeps its newest N by `(sentAt, id)`, in that fixed order, and each
    /// count sees the evictions before it. A frame older than its bucket's newest N is evicted the moment it arrives. The
    /// three trims never read `carry`: they are functions of the live entries alone, so every node converges on the same
    /// newest N whatever order frames arrive in, and a fair or carry-aware room trim would split an old node from a new one
    /// for good at a busy room's quota.
    ///
    /// Then, while the entries left exceed the cap, the global trim evicts one at a time, recounting after each, as
    /// `ForwardDao.evictFairest` run `count - maxRows` times does (knit-next ADR 2026-10.7mqm): the frame of the sender
    /// holding the most first, then the one `carry` believes most widely held (its holders capped at
    /// ``CustodyLimits/spreadMax``), then the oldest by `(sentAt, id)` (`fairlyEvictsBefore`). The old global
    /// trim took the globally oldest frame, so five free identities stamping a thousand frames just inside the future window
    /// evicted every honest frame on every node at once; key 1 still comes first, so a flood displaces only the largest
    /// buckets, which are its own, and whichever row the later keys pick, one of the largest buckets loses exactly one row.
    ///
    /// Below the cap this is the same function of the live entries on every node. At the cap only the global trim's choice
    /// of row reads this node's carry, which is read once per entry when the cap first binds in this write, a snapshot the
    /// later evictions of the same write reuse. The newcomer is a candidate like any row, so a frame can still be evicted by
    /// its own write. No tie depends on arrival order: the keys end on the id's bytes, which are unique.
    public static func evictions(after inserted: Entry, among live: [Entry], limits: CustodyLimits, carry: some CustodyCarry) -> [String] {
        var remaining = live
        var evicted: [String] = []
        func trim(to quota: Int, _ inBucket: (Entry) -> Bool) {
            let bucket = remaining.filter(inBucket).sorted(by: evictsBefore)
            guard bucket.count > quota else {
                return
            }
            let doomed = bucket.prefix(bucket.count - quota).map(\.id)
            evicted += doomed
            // Keyed by bytes: a `Set<String>` would also drop every id Swift calls equal to a doomed one.
            let doomedSet = Set(doomed.map(ExactKey.init))
            remaining.removeAll { doomedSet.contains(ExactKey($0.id)) }
        }
        // Buckets match by bytes too, as Android's `senderId = ?` and `groupId = ?` do (ADR 2026-09.jc2x).
        trim(to: limits.maxPerSender) { $0.senderId.utf8.elementsEqual(inserted.senderId.utf8) }
        if let group = inserted.groupId {
            trim(to: limits.maxPerGroup) { $0.groupId?.utf8.elementsEqual(group.utf8) == true }
        }
        if inserted.isRoomChat {
            trim(to: limits.maxRoomChat, \.isRoomChat)
        }
        // `!remaining.isEmpty` holds whenever `maxFrames` is not negative; it is here so the first entry below always
        // exists, and a negative cap still evicts everything, as it did.
        guard !remaining.isEmpty, remaining.count > limits.maxFrames else {
            return evicted
        }
        // Read once per entry per write, beside the senders' counts, and removed with its entry.
        var spreads = remaining.map { min(max(carry.holders(of: $0.id), 0), max(limits.spreadMax, 0)) }
        while !remaining.isEmpty, remaining.count > limits.maxFrames {
            // Counted by bytes, as SQLite's `GROUP BY senderId` groups BINARY text: two senders Swift calls equal are two
            // buckets on Android. Each entry's count sits beside it, so no lookup can miss.
            let held = senderCounts(of: remaining)
            var victim = remaining.startIndex
            for index in remaining.indices.dropFirst()
            where fairlyEvictsBefore(
                Ranked(entry: remaining[index], count: held[index], spread: spreads[index]),
                Ranked(entry: remaining[victim], count: held[victim], spread: spreads[victim])
            ) {
                // Strictly before, so a tie keeps the earlier entry; the id's bytes leave no tie between two entries.
                victim = index
            }
            spreads.remove(at: victim)
            evicted.append(remaining.remove(at: victim).id)
        }
        return evicted
    }

    /// How many of `entries` share each entry's sender, by index, the senders compared by their bytes (ADR 2026-09.jc2x).
    private static func senderCounts(of entries: [Entry]) -> [Int] {
        let bySender = Dictionary(grouping: entries.indices) { ExactKey(entries[$0].senderId) }
        var counts = [Int](repeating: 0, count: entries.count)
        for indices in bySender.values {
            for index in indices {
                counts[index] = indices.count
            }
        }
        return counts
    }

    /// An entry as the global trim ranks it: its sender's live count and its spread, both read for this write.
    private struct Ranked {
        var entry: Entry
        var count: Int
        var spread: Int
    }

    /// Whether the global trim takes `lhs` before `rhs`: the frame of the sender holding more first, then the frame held by
    /// more peers, then ``evictsBefore(_:_:)``. That is `ORDER BY b.n DESC, spread DESC, f.sentAt ASC, f.id ASC`
    /// (`ForwardDao.evictFairest` with the `custody-carry-policy` contract's key 2), so on a tie for most and for spread
    /// the sender whose oldest frame is oldest loses it.
    private static func fairlyEvictsBefore(_ lhs: Ranked, _ rhs: Ranked) -> Bool {
        guard lhs.count == rhs.count else {
            return lhs.count > rhs.count
        }
        guard lhs.spread == rhs.spread else {
            return lhs.spread > rhs.spread
        }
        return evictsBefore(lhs.entry, rhs.entry)
    }
}

/// Why custody did not take a frame. Only ``oversize`` (`custodyOversizeRefused`), ``profileOversize``
/// (`profileOversizeRefused`) and ``foreignRoster`` (`groupCustodyRefused`) are counted; none is a drop, since the frame is
/// still delivered and relayed.
public enum CustodyRefusal: Sendable, Equatable {
    /// Its `signed` bytes are longer than ``CustodyLimits/maxSignedBytes`` (knit-next #227). Checked first, so it is the
    /// reason given whatever else the frame fails, a profile over both caps included.
    case oversize
    /// A profile whose `signed` bytes are longer than ``CustodyLimits/maxProfileSignedBytes``. Checked second, so it is
    /// the reason given whatever else a profile under the byte cap fails.
    case profileOversize
    /// Past its frame-global expiry already: a skewed peer re-serving what every node has swept, or a `sentAt` of 0.
    case deadOnArrival
    /// Dated more than ``WireProtocol/maxFutureSkewMilliseconds`` ahead of the store's clock.
    case aheadOfWindow
    /// A group frame whose roster does not derive to its id, or does not name its sender (knit-next ADR 2026-10.7mqm).
    case foreignRoster
    /// The store's write failed, and it holds nothing new. Never the rules' answer, and never counted as a refusal.
    case writeFailed
}
