public import KnitWire

/// The digest answers under way, one per peer (the `custody-carry-policy` contract, §2): what each peer's latest digest
/// listed of what we hold, what the answer released and when, the keys it sent, what arrived from the peer since that
/// digest, and when its next round is due. Pure and clock-injected on the engine's monotonic clock; the engine cuts the rounds
/// (``CustodySync/round(_:memo:in:now:at:crossed:key:)``) and owns the deadlines (ADR 2026-09.gq84).
///
/// An answer goes out in rounds of ``CustodySync/roundBytes``, the next due
/// `max(interval, released bytes × interval / round)` after the last, so a held Bluetooth link serves custody at 8 KiB/s at
/// most and a cut loses about one round. A newer digest replaces the one the rounds are cut from and restarts the answer's
/// age, but never brings the next round forward, so a peer cannot raise the pace by sending digests. An answer ends when a
/// round finds nothing to release, when its link goes, or ``maxAgeMilliseconds`` after its latest digest; what is left waits
/// for the peer's next digest. Bounded by the links: the engine ends a peer's answer at its link-down.
///
/// A release is remembered only until a digest can speak to it (the contract, §2, revision 7): a digest forgets every id
/// the answer released at least `JUDGE_AFTER_MS` before it (``CarryLedger/digestSpeaks(to:at:)``). From then the digest
/// and the memo decide: an id it lists is not owed; a frame addressed to the peer, or any frame on an unproven link, is
/// owed again; any other frame waits out its not-kept mark. So an answer that digests keep open never withholds a lost
/// frame past the lapse §6 and §9 promise.
///
/// It replaces ``HeldDigests``' one slot per neighbour: an answer keeps the latest digest anyway, and a round due while its
/// link still holds ``HeldDigests/lineBytes`` unwritten waits ``HeldDigests/recheckMilliseconds`` and is cut then, never
/// larger.
public struct CustodyAnswers: Sendable {
    /// How long an answer lasts after its peer's latest digest (`ANSWER_MAX_AGE_MS`).
    public static let maxAgeMilliseconds: Int64 = 120_000

    /// One peer's answer.
    public struct Answer: Sendable, Equatable {
        /// The peer.
        public var peer: NodeId
        /// The ids its latest digest listed that we hold: at most what custody holds, whatever the digest listed.
        public var listed: Set<ExactKey>
        /// When that digest arrived.
        public var arrivedAt: Int64
        /// The ids this answer released, each with when, until a digest that can speak to it arrives (``CustodyAnswers/receive(_:from:now:)``).
        public var released: [ExactKey: Int64] = [:]
        /// The senders whose key this answer sent ahead: a key goes to a peer at most once per answer, since the peer's
        /// digest never shows one.
        public var keysSent: Set<ExactKey> = []
        /// The ids custody took from the peer since its latest digest, which it holds and so is not served back.
        public var arrivedSince: Set<ExactKey> = []
        /// When the next round is due.
        public var due: Int64
        /// Whether the round due waits on the link's line, logged once per answer.
        public var waitedOnLine = false

        /// Whether `id` is out of this answer's rounds for what the answer knows: listed, released, or arrived since.
        public func skips(_ id: ExactKey) -> Bool {
            listed.contains(id) || released[id] != nil || arrivedSince.contains(id)
        }
    }

    /// The answers, in the order they opened, so rounds due together are cut in a fixed order.
    private var answers: [Answer] = []

    /// No answer under way.
    public init() {
        // Nothing open.
    }

    /// Every answer under way.
    public var all: [Answer] { answers }

    /// When one answer's latest digest arrived and its next round is due.
    public struct Timing: Sendable, Equatable {
        /// The answer's peer.
        public var peer: NodeId
        /// When its latest digest arrived.
        public var arrivedAt: Int64
        /// When its next round is due.
        public var due: Int64
    }

    /// Each answer's timing, in the order the answers opened, read without copying their sets.
    public var timings: [Timing] {
        answers.map { Timing(peer: $0.peer, arrivedAt: $0.arrivedAt, due: $0.due) }
    }

    /// `peer`'s answer, if one is under way.
    public func answer(for peer: NodeId) -> Answer? {
        answers.first { $0.peer == peer }
    }

    /// A digest from `peer` arrived at `now`, listing `listed` of what we hold. Opens an answer, its first round due now, and
    /// answers `true`; or replaces the open answer's digest and restarts its age, its next round where it was, and answers
    /// `false`. The open answer forgets every release this digest can speak to (``CarryLedger/digestSpeaks(to:at:)``): from
    /// here the digest and the memo say whether it is owed again. One made since stays, as the digest may have crossed it.
    @discardableResult
    public mutating func receive(_ listed: Set<ExactKey>, from peer: NodeId, now: Int64) -> Bool {
        guard let index = answers.firstIndex(where: { $0.peer == peer }) else {
            answers.append(Answer(peer: peer, listed: listed, arrivedAt: now, due: now))
            return true
        }
        answers[index].listed = listed
        answers[index].arrivedAt = now
        answers[index].arrivedSince = []
        answers[index].released = answers[index].released.filter { !CarryLedger.digestSpeaks(to: $0.value, at: now) }
        return false
    }

    /// Custody took `id` from `peer`: its answer, if one is under way, does not serve it back.
    public mutating func noteArrived(_ id: String, from peer: NodeId) {
        guard let index = answers.firstIndex(where: { $0.peer == peer }) else {
            return
        }
        answers[index].arrivedSince.insert(ExactKey(id))
    }

    /// `round` went to `peer` at `now`: what it released joins the answer's, stamped `now`, and the keys it sent, and the
    /// next round is due one interval later, or in proportion to the bytes when they passed the budget.
    ///
    /// The answer's sets are trimmed to what custody held as the round read it (``CustodySync/DigestReply/live`` and
    /// ``CustodySync/DigestReply/senders``), which keeps each within custody's row cap however long digests keep the answer
    /// open. A pick and a key only ever come from a live row, so within a round the trim changes nothing. Across rounds it
    /// forgets a released frame that custody evicted: if that frame comes back while the answer is still open, the link's
    /// crossings keep it from going to the peer a second time for 10 minutes, and the digest and the memo decide after.
    public mutating func released(_ round: CustodySync.DigestReply, to peer: NodeId, now: Int64) {
        guard let index = answers.firstIndex(where: { $0.peer == peer }) else {
            return
        }
        for release in round.released {
            answers[index].released[ExactKey(release.id)] = now
        }
        answers[index].released = answers[index].released.filter { round.live.contains($0.key) }
        answers[index].arrivedSince.formIntersection(round.live)
        answers[index].keysSent.formUnion(round.keysAhead.map { ExactKey($0.string) })
        answers[index].keysSent.formIntersection(round.senders)
        answers[index].due = now + Self.wait(after: round.bytes)
    }

    /// The wait after a round of `bytes`: `max(interval, bytes × interval / round)`.
    public static func wait(after bytes: Int) -> Int64 {
        max(CustodySync.roundMilliseconds, Int64(bytes) * CustodySync.roundMilliseconds / Int64(CustodySync.roundBytes))
    }

    /// `peer`'s round waits on its link's line until `until`. Answers whether it was the answer's first wait.
    @discardableResult
    public mutating func wait(_ peer: NodeId, until: Int64) -> Bool {
        guard let index = answers.firstIndex(where: { $0.peer == peer }) else {
            return false
        }
        answers[index].due = until
        defer { answers[index].waitedOnLine = true }
        return !answers[index].waitedOnLine
    }

    /// Ends `peer`'s answer. What is left waits for its next digest.
    public mutating func end(_ peer: NodeId) {
        answers.removeAll { $0.peer == peer }
    }

    /// Whether `answer` has outlived its latest digest at `now`.
    public static func isAged(_ answer: Answer, now: Int64) -> Bool {
        isAged(arrivedAt: answer.arrivedAt, now: now)
    }

    /// Whether an answer whose latest digest arrived at `arrivedAt` has outlived it at `now`.
    public static func isAged(arrivedAt: Int64, now: Int64) -> Bool {
        now - arrivedAt >= maxAgeMilliseconds
    }

    /// When the next round is due or an answer ages out, or `nil` when none is under way: an engine deadline.
    public var nextDeadline: Int64? {
        answers.map { min($0.due, $0.arrivedAt + Self.maxAgeMilliseconds) }.min()
    }
}
