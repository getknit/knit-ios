public import KnitWire

/// The digest answers under way, one per peer (the `custody-carry-policy` contract, §2): what each peer's latest digest
/// listed of what we hold, what the answer released and when, the keys it sent, and what arrived from the peer since that
/// digest. Pure and clock-injected on the engine's monotonic clock; the engine cuts the rounds
/// (``CustodySync/round(_:memo:in:now:at:addressedOnly:crossed:key:)``) and owns the looks (ADR 2026-09.gq84).
///
/// No clock paces an answer (the contract, §2, revision 13). It goes out in rounds of ``CustodySync/roundBytes``: the first
/// when the digest arrives, each next one as soon as the link holds less than one round unwritten for the peer, which the
/// engine looks for every ``roundCheckMilliseconds`` while an answer is open. So two linked phones sync as fast as their
/// link writes, a link that does not drain gets nothing more, and a cut loses under two rounds plus a first pick past the
/// budget. A newer digest replaces the one the rounds are cut from and restarts the answer's age, and cuts no round of its
/// own, so a peer cannot draw rounds by sending digests. An answer ends when a round finds nothing to release, when its link
/// goes, or ``maxAgeMilliseconds`` after its latest digest; what is left waits for the peer's next digest. Bounded by the
/// links: the engine ends a peer's answer at its link-down.
///
/// A release is remembered only until a digest can speak to it (the contract, §2, revision 7): a digest forgets every id
/// the answer released at least `JUDGE_AFTER_MS` before it (``CarryLedger/digestSpeaks(to:at:)``). From then the digest
/// and the memo decide: an id it lists is not owed; a frame addressed to the peer, or any frame on an unproven link, is
/// owed again; any other frame waits out its not-kept mark. So an answer that digests keep open never withholds a lost
/// frame past the lapse §6 and §9 promise.
///
/// It replaces the one slot per neighbour that held a digest while its link was full: an answer keeps the latest digest
/// anyway, and its next round waits for the link to drain.
public struct CustodyAnswers: Sendable {
    /// How long an answer lasts after its peer's latest digest (`ANSWER_MAX_AGE_MS`).
    public static let maxAgeMilliseconds: Int64 = 120_000
    /// How often the engine looks whether a link took a round while an answer is open or a hand-off waits for its credit
    /// (`ROUND_CHECK_MS`): the radio signals no drain, so the look is a deadline.
    public static let roundCheckMilliseconds: Int64 = 100

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
        /// Whether a round waited on its link to drain, logged once per answer.
        public var waitedOnDrain = false
        /// Whether its last round behind a moving file found no mail for the peer, so its cuts wait.
        public var idleBehindFile = false
        /// Whether its last round stopped at the budget with more to serve. One that did not served all there was, so the
        /// answer may have ended while that round is still unwritten.
        public var lastCapped = true

        /// Whether `id` is out of this answer's rounds for what the answer knows: listed, released, or arrived since.
        public func skips(_ id: ExactKey) -> Bool {
            listed.contains(id) || released[id] != nil || arrivedSince.contains(id)
        }
    }

    /// The answers, in the order they opened, so rounds due together are cut in a fixed order.
    private var answers: [Answer] = []

    /// When the engine last looked whether a link drained, on the monotonic clock: the next look is
    /// ``roundCheckMilliseconds`` after it.
    public var lookedAt: Int64 = 0

    /// The files this node handed its link to each peer, kept only while the link still has them queued or streaming
    /// (``fileMoving(to:inFlight:reading:)``): the link says so for one hash, never for any, so this names the hashes to ask
    /// about.
    private var filesOut: [NodeId: Set<BlobHash>] = [:]

    /// No answer under way.
    public init() {
        // Nothing open.
    }

    /// Every answer under way.
    public var all: [Answer] { answers }

    /// When one answer's latest digest arrived.
    public struct Timing: Sendable, Equatable {
        /// The answer's peer.
        public var peer: NodeId
        /// When its latest digest arrived.
        public var arrivedAt: Int64
    }

    /// Each answer's timing, in the order the answers opened, read without copying their sets.
    public var timings: [Timing] {
        answers.map { Timing(peer: $0.peer, arrivedAt: $0.arrivedAt) }
    }

    /// `peer`'s answer, if one is under way.
    public func answer(for peer: NodeId) -> Answer? {
        answers.first { $0.peer == peer }
    }

    /// A digest from `peer` arrived at `now`, listing `listed` of what we hold. Opens an answer, whose first round the engine
    /// cuts now, and answers `true`; or replaces the open answer's digest and restarts its age, cutting no round of its own,
    /// and answers `false`. The open answer forgets every release this digest can speak to (``CarryLedger/digestSpeaks(to:at:)``): from
    /// here the digest and the memo say whether it is owed again. One made since stays, as the digest may have crossed it.
    @discardableResult
    public mutating func receive(_ listed: Set<ExactKey>, from peer: NodeId, now: Int64) -> Bool {
        guard let index = answers.firstIndex(where: { $0.peer == peer }) else {
            answers.append(Answer(peer: peer, listed: listed, arrivedAt: now))
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

    /// `round` went to `peer` at `now`: what it released joins the answer's, stamped `now`, and so do the keys it sent. The
    /// next round goes once the link drains.
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
        answers[index].lastCapped = round.isCapped
    }

    /// `peer`'s next round waits for its link to drain. Answers whether it was the answer's first wait.
    @discardableResult
    public mutating func waitsOnDrain(_ peer: NodeId) -> Bool {
        guard let index = answers.firstIndex(where: { $0.peer == peer }) else {
            return false
        }
        defer { answers[index].waitedOnDrain = true }
        return !answers[index].waitedOnDrain
    }

    /// The link took `hash` to stream to `peer`.
    public mutating func noteFileOut(_ hash: BlobHash, to peer: NodeId) {
        filesOut[peer, default: []].insert(hash)
    }

    /// Whether the link still carries a file this node handed it for `peer`, queued or streaming, as `inFlight` says per
    /// hash, and the file is moving: no copy's feed, as `reading` reads it, counts as stalled (``FeedReading/live`` false,
    /// the blob plane's own 15 s with no progress). A copy queued with no reading yet counts as moving, unless the one
    /// streaming ahead of it stalled, since nothing behind a stalled stream moves either (the contract, §2, "Only a file
    /// that is moving comes first"). One the link no longer carries is forgotten.
    public mutating func fileMoving(
        to peer: NodeId, inFlight: (BlobHash) -> Bool, reading: (BlobHash) -> FeedReading?
    ) -> Bool {
        let carried = (filesOut[peer] ?? []).filter(inFlight)
        filesOut[peer] = carried.isEmpty ? nil : carried
        return !carried.isEmpty && !carried.contains { reading($0)?.live == false }
    }

    /// `peer`'s file-first round came up empty: its next cuts wait until the file stops moving or mail for the peer
    /// arrives, so a look does not read the index again for nothing.
    public mutating func idlesBehindFile(_ peer: NodeId, _ idle: Bool) {
        guard let index = answers.firstIndex(where: { $0.peer == peer }) else {
            return
        }
        answers[index].idleBehindFile = idle
    }

    /// Whether `peer`'s answer idles behind a file (``idlesBehindFile(_:_:)``).
    public func isIdleBehindFile(_ peer: NodeId) -> Bool {
        answers.first { $0.peer == peer }?.idleBehindFile == true
    }

    /// Custody took a frame addressed to `peer`: an answer idle behind a file has mail to cut again.
    public mutating func noteMail(for peer: String) {
        guard let index = answers.firstIndex(where: { ExactKey($0.peer.string) == ExactKey(peer) }) else {
            return
        }
        answers[index].idleBehindFile = false
    }

    /// `peer`'s link went: what it carried for it went too.
    public mutating func linkDown(_ peer: NodeId) {
        filesOut[peer] = nil
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

    /// Whether any answer is under way.
    public var isEmpty: Bool {
        answers.isEmpty
    }
}
