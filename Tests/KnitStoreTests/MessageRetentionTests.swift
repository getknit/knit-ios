import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// The local retention rule (``MessageRetention``, knit-ios #21), each of Kotlin's steps and their order
/// (`MessageRepository.sweepRetention`, `MessageRepository.kt:354-414` at knit-next `e63f15f4`), and the group rows a
/// replayed leave reads, which this port keeps.
@Suite struct MessageRetentionTests {
    private let now: Int64 = 1_756_200_000_000
    private let day: Int64 = 86_400_000
    private let known = fixtureNodeId(1)
    private let stranger = fixtureNodeId(2)
    private let other = fixtureNodeId(3)

    private func row(
        _ id: String, in conversation: String = Conversations.nearby, from sender: NodeId, at sentAt: Int64, kind: MessageKind = .message
    ) -> RetentionRow {
        RetentionRow(id: id, conversationId: conversation, senderId: sender, sentAt: sentAt, kind: kind)
    }

    /// The ids `MessageRetention` trims from `room` and `pending`, as a set.
    private func trimmed(room: [RetentionRow] = [], pending: [RetentionRow] = []) -> Set<String> {
        Set(MessageRetention.trims(room: room, pending: pending, now: now) { $0 == known }.map(\.id))
    }

    /// `count` posts in the room from `sender`, the newest at `newest` and one millisecond apart, ids `<tag>-<index>`.
    private func posts(_ count: Int, from sender: NodeId, tag: String, newest: Int64) -> [RetentionRow] {
        (0..<count).map { row("\(tag)-\($0)", from: sender, at: newest - Int64(count - 1 - $0)) }
    }

    // MARK: The room

    @Test func aRoomPostOlderThanThirtyDaysGoesWhateverTheCountAndWhoeverWroteIt() {
        let cutoff = now - MessageRetention.roomMaxAgeMilliseconds
        let room = [row("old", from: known, at: cutoff - 1), row("edge", from: stranger, at: cutoff), row("new", from: stranger, at: now)]
        #expect(trimmed(room: room) == ["old"], "Kotlin's `sentAt < cutoff`, a known sender's included")
    }

    @Test func aStrangerKeepsTheirNewestTwoHundredAndAKnownSenderIsExempt() {
        let room = posts(201, from: stranger, tag: "s", newest: now) + posts(201, from: known, tag: "k", newest: now)
        #expect(trimmed(room: room) == ["s-0"], "the stranger's oldest, never the known sender's")
    }

    @Test func overTwoThousandStrangersOldestGoFirstThenTheOldestOfAnyone() {
        // 1,900 posts of the user's contacts, older than every stranger's, and 150 strangers' posts.
        let contacts = posts(1900, from: known, tag: "k", newest: now - 1000)
        let strangers = posts(150, from: stranger, tag: "s", newest: now)
        #expect(trimmed(room: contacts + strangers) == Set((0..<50).map { "s-\($0)" }), "strangers' oldest, not the older contacts'")

        // Over the cap on known senders alone, the oldest of anyone goes.
        let crowded = posts(2010, from: known, tag: "k", newest: now - 1000) + posts(5, from: stranger, tag: "s", newest: now)
        #expect(trimmed(room: crowded) == Set((0..<5).map { "s-\($0)" } + (0..<10).map { "k-\($0)" }))
    }

    @Test func theRoomsStepsRunInKotlinsOrder() {
        // The age cut first, so the per-stranger count never weighs a post the age cut took; then each stranger's newest
        // 200, so the count over 2,000 sees what is left.
        let aged = row("aged", from: stranger, at: now - MessageRetention.roomMaxAgeMilliseconds - 1)
        let room = [aged] + posts(200, from: stranger, tag: "s", newest: now) + posts(1850, from: known, tag: "k", newest: now - 500)
        #expect(trimmed(room: room) == Set(["aged"] + (0..<50).map { "s-\($0)" }))
    }

    @Test func tiesInTheRoomGoByTheIdsBytes() {
        let room =
            posts(1999, from: known, tag: "k", newest: now - 1000) + [
                row("\u{212A}", from: stranger, at: now), row("K", from: stranger, at: now),
            ]
        #expect(trimmed(room: room) == ["K"], "\"K\" sorts before the Kelvin sign's bytes, so it is the older")
    }

    // MARK: Message requests

    @Test func aRequestAWeekQuietGoesWhole() {
        let quiet = now - MessageRetention.pendingThreadMaxAgeMilliseconds - 1
        let pending = [
            row("a", in: stranger.string, from: stranger, at: quiet - day),
            row("b", in: stranger.string, from: stranger, at: quiet),
            row("c", in: other.string, from: other, at: quiet + 1),
        ]
        #expect(trimmed(pending: pending) == ["a", "b"])
    }

    @Test func aRequestKeepsItsNewestFiftyStatusLinesCounted() {
        let thread = stranger.string
        var pending = (0..<50).map { row("m-\($0)", in: thread, from: stranger, at: now - 100 + Int64($0)) }
        pending.append(row("notice", in: thread, from: stranger, at: now - 200, kind: .memberLeft))
        pending.append(row("oldest", in: thread, from: stranger, at: now - 300))
        #expect(trimmed(pending: pending) == ["notice", "oldest"])
    }

    @Test func pastAHundredRequestsTheLeastRecentlyActiveGoWhole() {
        // 101 threads of two rows, thread 0 the least recently active; threads 99 and 100 tie, and the one whose id's
        // bytes come first stays.
        var pending: [RetentionRow] = []
        for index in 0..<101 {
            let thread = "t-" + String(repeating: "0", count: 3 - String(index).count) + String(index)
            let last = now - 1000 + Int64(min(index, 99))
            pending.append(row("\(thread)-old", in: thread, from: stranger, at: last - 1))
            pending.append(row("\(thread)-new", in: thread, from: stranger, at: last))
        }
        #expect(trimmed(pending: pending) == ["t-000-old", "t-000-new"])
        let tied = pending.filter { $0.conversationId != "t-000" }
        #expect(trimmed(pending: tied + [row("t-101", in: "t-101", from: stranger, at: now - 999)]) == ["t-101"], "t-001 ties it and stays")
    }

    @Test func theCapOnRequestsCountsWhatTheFiftyLeft() {
        // The busiest thread is trimmed to 50 and still counts as one; the 101st goes whole.
        var pending = (0..<60).map { row("busy-\($0)", in: "t-busy", from: stranger, at: now - 60 + Int64($0)) }
        for index in 0..<100 {
            pending.append(row("one-\(index)", in: "t-\(index)", from: other, at: now - 10_000 + Int64(index)))
        }
        #expect(trimmed(pending: pending) == Set((0..<10).map { "busy-\($0)" } + ["one-0"]))
    }

    // MARK: A group request's anchors

    @Test func aGroupRequestKeepsEachSendersNewestActOutsideItsNewestFifty() {
        let group = "g-1"
        var pending = [
            row("other-message", in: group, from: other, at: now - 900),
            row("other-older", in: group, from: other, at: now - 950),
            row("renamed", in: group, from: known, at: now - 800, kind: .groupRenamed),
            row("left", in: group, from: fixtureNodeId(4), at: now - 700, kind: .memberLeft),
        ]
        pending += (0..<50).map { row("s-\($0)", in: group, from: stranger, at: now - 100 + Int64($0)) }
        #expect(trimmed(pending: pending) == ["other-older", "left"], "a leave's own line is no act after it")

        // The cap on requests keeps them too; a DM keeps nothing past its count.
        var many = pending
        for index in 0..<100 {
            many.append(row("dm-\(index)", in: "t-\(index)", from: stranger, at: now - 10 + Int64(index % 5)))
        }
        let capped = trimmed(pending: many)
        #expect(capped.isSuperset(of: (0..<49).map { "s-\($0)" }) && !capped.contains("s-49"), "the stranger's newest stays")
        #expect(!capped.contains("other-message") && !capped.contains("renamed"))
    }

    @Test func aGroupRequestAWeekQuietGoesWholeItsAnchorsIncluded() {
        let quiet = now - MessageRetention.pendingThreadMaxAgeMilliseconds - 1
        let pending = [row("a", in: "g-1", from: stranger, at: quiet), row("b", in: "g-1", from: other, at: quiet - 1)]
        #expect(trimmed(pending: pending) == ["a", "b"])
    }

    @Test func nothingIsTrimmedFromThreadsInsideEveryBound() {
        let room = posts(10, from: stranger, tag: "s", newest: now)
        let pending = (0..<3).map { row("p-\($0)", in: stranger.string, from: stranger, at: now - Int64($0)) }
        #expect(trimmed(room: room, pending: pending).isEmpty)
        #expect(trimmed().isEmpty)
    }

    // MARK: The tombstone

    @Test func aTrimmedRowIsRememberedWhileACarrierALifetimeBehindCouldStillHoldItsFrame() {
        let limits = CustodyLimits()
        let skew = WireProtocol.maxFutureSkewMilliseconds
        func expiry(_ sentAt: Int64, _ kind: MessageKind = .message, in conversation: String = "g-1") -> Int64? {
            DeletedMessages.trimmedExpiry(sentAt: sentAt, kind: kind, conversationId: conversation, at: now)
        }
        let ttl = limits.ttlMilliseconds
        let dmEdge = now - 2 * ttl - skew
        #expect(expiry(dmEdge + 1) == now + ttl + skew, "a day from the trim, past every carrier a day behind")
        #expect(expiry(dmEdge) == nil, "no carrier a day behind holds it any more")
        #expect(expiry(now) == now + 2 * ttl + skew, "an early trim outlives a carrier a day behind, which holds it two days")
        #expect(expiry(now + 60_000) == now + 60_000 + 2 * ttl + skew, "from a sentAt ahead of our clock")
        let room = limits.roomChatTTLMilliseconds
        let roomEdge = now - 2 * room - skew
        #expect(expiry(roomEdge + 1, in: Conversations.nearby) == now + room + skew, "a late trim's lasts six hours past it")
        #expect(expiry(now, in: Conversations.nearby) == now + 2 * room + skew, "an early one twelve past its sentAt")
        #expect(expiry(roomEdge, in: Conversations.nearby) == nil)
        #expect(expiry(roomEdge, in: "nearby\u{0}") != nil, "only the room's own id, by its bytes")
        #expect(expiry(now, .groupCreated) == nil, "a status line's id is our own")
        #expect(expiry(.max) == now + ttl + skew, "a hostile sentAt wraps rather than traps, and lasts one TTL past the trim")
    }
}
