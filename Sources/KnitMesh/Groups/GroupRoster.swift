import KnitCrypto
import KnitStore
import KnitWire

/// The rules every group frame meets (`InboundPipeline.reconcileGroup`, `vetRoster`, `rejoinBy` and
/// `GroupRepository.recordDeparture` in knit-next), as pure functions of the group we hold and what a frame says
/// (ADR 2026-09.n393).
///
/// The roster is pinned, never overwritten. A frame can only establish a group whose id is the hash of its founding
/// roster, and after that the effective roster only shrinks, by a member's own signed `groupleave`. The one growth is
/// its mirror: a member who left comes back by a frame of their own, newer than the leave. Nobody can add anyone
/// else, and the founding set never changes.
internal struct GroupRoster {
    /// What a frame carrying a roster does to the group we hold.
    enum Verdict: Equatable {
        /// Not a group we take frames for: one we left, or one we are not in. We only carry and relay it.
        case ignored
        /// A roster that names us but fails the pin, the derivation or the sender rules: counted, and ignored.
        case refused
        /// The group as it now stands, and the status lines the frame earns, in the order they were earned.
        case accepted(GroupRecord, notices: [MessageRecord])
    }

    /// This node.
    let me: NodeId
    /// Five minutes past our clock: no sender's clock counts for later (`clampFuture`).
    let maxClock: Int64

    /// Brings `existing` in line with `info`, carried by a frame from `sender` stamped `sentAt`
    /// (`InboundPipeline.kt:2015-2084`). `sentAt` is already bounded by ``maxClock``, and the photo's clock is bounded
    /// here the same way.
    func reconcile(_ info: GroupInfo, from sender: NodeId, at sentAt: Int64, existing: GroupRecord?) -> Verdict {
        // A group we left is never upserted again, so no frame can bring it back (`groupFrameRefused`, :2220).
        if existing?.hasLeft == true {
            return .ignored
        }
        let rejoining = existing.map { Self.rejoins(sender, in: info, at: sentAt, existing: $0) } ?? false
        let vetted = vet(info, from: sender, existing: existing, rejoining: rejoining)
        guard case .accept(let members, let departed) = vetted else {
            return vetted == .notOurs ? .ignored : .refused
        }
        // The name is shared only when one is set, so an unnamed frame never clears it, and the newer frame wins, a
        // tie going to the incoming one (:2042-2045).
        let keepName = existing?.name ?? ""
        let keepClock = existing?.nameUpdatedAt ?? 0
        let takenName = sentAt >= keepClock ? TextLimits.incomingGroupName(info.name) : nil
        let createdAt = existing?.createdAt ?? sentAt
        var record = GroupRecord(
            id: info.id,
            name: takenName ?? keepName,
            createdBy: info.createdBy,
            createdAt: createdAt,
            nameUpdatedAt: takenName == nil ? keepClock : sentAt,
            photoHash: existing?.photoHash,
            photoUpdatedAt: existing?.photoUpdatedAt,
            roster: Self.roster(members: members, departed: departed, existing: existing)
        )
        // The photo has its own clock (`groupPhotoDecision`, `InboundPipeline.kt:2343-2373`). The decided hash is taken at
        // once and goes out on every frame we send, as on Android since knit-next ADR 2026-09.nxcq, where the photo
        // shown waits for its bytes.
        let photoClock = min(info.photoUpdatedAt ?? 0, maxClock)
        if Self.photoWins(info.photoHash, at: photoClock, over: existing?.photoHash, at: existing?.photoUpdatedAt ?? 0) {
            record.photoHash = info.photoHash
            record.photoUpdatedAt = photoClock
        }
        var notices: [MessageRecord] = []
        if existing == nil {
            notices.append(StatusNotices.groupCreated(info.id, by: creator(of: info, sender: sender), at: createdAt))
        } else if let takenName, ExactKey(takenName) != ExactKey(keepName) {
            notices.append(StatusNotices.groupRenamed(info.id, by: sender, to: takenName, at: sentAt))
        }
        if rejoining {
            Self.rejoin(sender.string, at: sentAt, in: &record)
            notices.append(StatusNotices.memberRejoined(info.id, member: sender, at: sentAt))
        }
        return .accepted(record, notices: notices)
    }

    /// Whether `incoming` at `clock` replaces the decided photo `held` at `heldClock` (`photoWins`,
    /// `InboundPipeline.kt:2378-2387`): a different photo on a later clock, or on an equal clock only while nothing is
    /// held. A tie never moves a held photo, so a member who still shows the old photo, re-asserting it at the new
    /// clock, cannot switch the group back (knit-next #108).
    static func photoWins(_ incoming: String?, at clock: Int64, over held: String?, at heldClock: Int64) -> Bool {
        guard let incoming, held.map({ ExactKey($0) != ExactKey(incoming) }) ?? true else {
            return false
        }
        return clock > heldClock || (held == nil && clock >= heldClock)
    }

    /// The group after `leaver`'s signed `groupleave` stamped `leftAt`, and its status line, or `nil` when it
    /// changes nothing (`GroupRepository.recordDeparture`, `GroupRepository.kt:86-118`): a group we left, someone
    /// who is not a current member, or a leave no newer than their rejoin, which a re-served old leave would be.
    static func depart(_ leaver: NodeId, at leftAt: Int64, from group: GroupRecord) -> (group: GroupRecord, notice: MessageRecord)? {
        let key = ExactKey(leaver.string)
        guard !group.hasLeft, let index = group.roster.firstIndex(where: { ExactKey($0.nodeId) == key && !$0.departed }),
            leftAt > group.roster[index].rejoinedAt ?? 0
        else {
            return nil
        }
        var updated = group
        var member = updated.roster.remove(at: index)
        member.departed = true
        member.leftAt = leftAt
        updated.roster.append(member)
        return (updated, StatusNotices.memberLeft(group.id, member: leaver, at: leftAt))
    }

    // MARK: The roster

    /// `vetRoster`'s verdict (`InboundPipeline.kt:2272-2308`).
    enum Vetted: Equatable {
        /// We are not in the founding set we know of: we only carry the frame. Silent.
        case notOurs
        /// A roster claiming us that fails the pin, the derivation or the sender rules.
        case refused
        /// The effective members to store, in order, and our tombstones beside them.
        case accept(members: [String], departed: [String])
    }

    /// Vets a frame's self-describing roster against the one we hold. The founding set we store only ever comes from
    /// a roster whose id is its hash, so nobody can smuggle a member in, and none can hide one: a shrunk roster is
    /// accepted as a frame but never changes the pin. The frame's `departed` list is arithmetic only, completing the
    /// founding set for the hash, and is never merged into our tombstones, or anyone could evict anyone.
    func vet(_ info: GroupInfo, from sender: NodeId, existing: GroupRecord?, rejoining: Bool) -> Vetted {
        let incoming = Self.distinct(info.members + (info.departed ?? []))
        var storedMembers = existing?.members ?? []
        var storedDeparted = existing?.departed ?? []
        if rejoining {
            storedMembers.append(sender.string)
            storedDeparted.removeAll { ExactKey($0) == ExactKey(sender.string) }
        }
        let storedFounding = Set((storedMembers + storedDeparted).map(ExactKey.init))
        let incomingFounding = Set(incoming.map(ExactKey.init))
        // Checked against the pin when we hold one, else the frame.
        let claimed = existing == nil ? incomingFounding : storedFounding
        guard claimed.contains(ExactKey(me.string)) else {
            return .notOurs
        }
        let founding: Set<ExactKey>
        let members: [String]
        if existing != nil, storedFounding.isSuperset(of: incomingFounding) {
            founding = storedFounding
            members = storedMembers
        } else {
            // First sight, or a strict superset of our pin, which repairs a pin first made from a truncated frame: only
            // the true founding roster passes, since the id is its hash.
            guard incomingFounding.isSuperset(of: storedFounding), incoming.count <= GroupInfo.maxMembers,
                GroupId.derive(incoming) == info.id
            else {
                return .refused
            }
            let gone = Set(storedDeparted.map(ExactKey.init))
            founding = incomingFounding
            members = incoming.filter { !gone.contains(ExactKey($0)) }
        }
        // Us and the sender must both be founding members: a frame leaving us out cannot starve us out, and a departed
        // member's frames from before the leave still deliver.
        guard founding.contains(ExactKey(me.string)), founding.contains(ExactKey(sender.string)) else {
            return .refused
        }
        return .accept(members: members, departed: storedDeparted)
    }

    /// Whether this frame brings its sender back (`rejoinBy`, `InboundPipeline.kt:2184-2194`): they are in our
    /// tombstones, the frame lists them as a member, and it is newer than their leave. The leaver is the signer, so
    /// nobody can bring back anyone else, and a re-served frame from before the leave cannot undo it.
    static func rejoins(_ sender: NodeId, in info: GroupInfo, at sentAt: Int64, existing: GroupRecord) -> Bool {
        let key = ExactKey(sender.string)
        guard let member = existing.member(sender.string), member.departed, info.members.contains(where: { ExactKey($0) == key }) else {
            return false
        }
        return sentAt > member.leftAt ?? 0
    }

    /// Whether `group`, the row a reconciled frame from `sender` leaves, brought the sender back from `existing`: held as
    /// departed before, and present now. Only the sender's own frame does that (``rejoins(_:in:at:existing:)``), and the
    /// caller then rekeys, floored (`recordRejoin`'s `rekey`, `InboundPipeline.kt:2166`).
    static func rejoined(_ sender: NodeId, from existing: GroupRecord?, to group: GroupRecord) -> Bool {
        existing?.member(sender.string)?.departed == true && group.member(sender.string)?.departed == false
    }

    /// The roster to store: the effective `members` in order, then our tombstones, each keeping its clocks.
    private static func roster(members: [String], departed: [String], existing: GroupRecord?) -> [GroupMember] {
        let present = members.map { id in
            var member = existing?.member(id) ?? GroupMember(nodeId: id)
            member.departed = false
            return member
        }
        // Our tombstones all come from the row we hold, so each keeps its clocks as it is.
        return present + departed.compactMap { existing?.member($0) }
    }

    /// Who the `created` line names. Android names the frame's `createdBy`, unchecked, and a stranger who wrote our
    /// id there made the line, and so the group, count as ours (`MessageDao.kt:294`). This port names `createdBy`
    /// only when it is a founding member and not us, unless the frame is ours, and otherwise the verified sender
    /// (ADR 2026-09.n393).
    private func creator(of info: GroupInfo, sender: NodeId) -> NodeId {
        guard let creator = NodeId(info.createdBy), creator != me || sender == me else {
            return sender
        }
        let founding = Set((info.members + (info.departed ?? [])).map(ExactKey.init))
        return founding.contains(ExactKey(creator.string)) ? creator : sender
    }

    /// `ids` without repeats, in first-seen order, compared by bytes (Kotlin's `distinct()`).
    private static func distinct(_ ids: [String]) -> [String] {
        var seen = Set<ExactKey>()
        return ids.filter { seen.insert(ExactKey($0)).inserted }
    }

    /// Stamps `nodeId`'s return in `group`: the roster already holds them among the members, at its end.
    private static func rejoin(_ nodeId: String, at rejoinedAt: Int64, in group: inout GroupRecord) {
        let key = ExactKey(nodeId)
        if let index = group.roster.firstIndex(where: { ExactKey($0.nodeId) == key }) {
            group.roster[index].departed = false
            group.roster[index].rejoinedAt = rejoinedAt
        }
    }
}
