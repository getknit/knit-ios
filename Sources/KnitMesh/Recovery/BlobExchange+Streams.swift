import KnitWire

/// A fetch waiting on a holder that streams us another file (`stuckOn`, `streamWait`, `askedLacking`, `idleHolderPast` and
/// `lackedWhileStuck`, `BlobExchange.kt:371-528`, knit-next `79f38d3d` and `09f70b3e`).
extension BlobExchange {
    /// The holder `fetch` waits on while what it streams us has more than ``streamSwitchMilliseconds`` left, or `nil`
    /// (`stuckOn`, `BlobExchange.kt:371-383`): the one wait in which another neighbour's fresh HAVE moves the fetch
    /// (``idleHolderPast(_:_:_:)``).
    static func stuckOn(_ fetch: Fetch, _ linked: [Candidate]) -> NodeId? {
        linked.first { $0.id == fetch.peer }
            .flatMap { $0.streaming && ($0.streamLeftMilliseconds ?? 0) > streamSwitchMilliseconds ? $0.id : nil }
    }

    /// Whether `id` is rechecked as one that lacked the blob while the fetch waits on `stuckOn` (`lackedWhileStuck`,
    /// `BlobExchange.kt:443-449`). A NONE is otherwise final for the fetch, but a neighbour that lacked the blob when we
    /// asked often holds it a minute later: two members fetch a new post at once, and the one queued behind a long
    /// stream never learns the other's copy landed (knit-next's iPhone smoke of 2026-10-07: a Pixel 8 sat 8 min behind
    /// a DM file while a Pixel 9 held the photo idle). Only while stuck, since only then would its HAVE move the fetch.
    static func lackedWhileStuck(_ want: Want, _ id: NodeId, stuckOn: NodeId?) -> Bool {
        guard let stuckOn else {
            return false
        }
        return id != stuckOn && !want.failed.contains(id) && want.answers[id]?.state == .notHeld
    }

    /// ``fetchWait(_:_:_:_:_:)`` while `holder` streams another file to us (`streamWait`, `BlobExchange.kt:481-497`,
    /// knit-next `79f38d3d`): wait it out, since our copy may be queued behind it, except in two cases. Knit-next's
    /// cell (d) device run of 2026-10-07 had an asker sit 12 min on a neighbour feeding it an older carrier copy at
    /// about 2 KB/s, while another held the blob and fed nothing.
    ///
    /// - **Our ask found it lacking** (``askedLacking(_:_:)``): the ask is dropped, not failed, since it may hold the
    ///   blob soon, and its HAVE asks it again, this time for real.
    /// - **An idle holder is past it** (``idleHolderPast(_:_:_:)``): it is left, failed for the cycle.
    mutating func streamWait(
        _ want: inout Want, _ fetch: Fetch, _ holder: Candidate, _ linked: [Candidate], _ plan: inout Plan
    ) -> Int64? {
        var fetch = fetch
        if Self.askedLacking(want, holder) {
            want.fetch = nil
            plan.notes.append("blob drop \(want.hash8)… ask on \(holder.id): it lacked the blob, nothing of ours is queued")
            return nil
        }
        if let why = Self.idleHolderPast(want, holder, linked) {
            let ended = over(&want, fetch, why, &plan, withdrawing: true)
            want.failed.insert(holder.id)
            return ended
        }
        fetch.quietSince = nil
        want.fetch = fetch
        return min(Self.streamPollMilliseconds, fetch.graceMilliseconds)
    }

    /// Whether our ask found `holder` lacking the blob (`askedLacking`, `BlobExchange.kt:504-511`): an answer saying so
    /// came in at or after the ask. A neighbour that lacks a blob remembers no asker, so nothing of ours is queued behind
    /// what it streams.
    static func askedLacking(_ want: Want, _ holder: Candidate) -> Bool {
        guard let answer = want.answers[holder.id], let asked = want.askedAt[holder.id] else {
            return false
        }
        return !answer.state.isHeld && answer.receivedAt >= asked
    }

    /// Why `want`'s fetch leaves `holder`, or `nil` to wait (`idleHolderPast`, `BlobExchange.kt:518-528`): what it
    /// streams us has more than ``streamSwitchMilliseconds`` left, and another linked neighbour said HAVE with load 0
    /// and streams us nothing. Our copy, queued or not, waits that long here and none there; one queued here may still
    /// come, and a second copy is worth a wait that long.
    static func idleHolderPast(_ want: Want, _ holder: Candidate, _ linked: [Candidate]) -> String? {
        guard let left = holder.streamLeftMilliseconds, left > streamSwitchMilliseconds else {
            return nil
        }
        let idle = linked.first { other in
            let answer = want.answers[other.id]
            return other.id != holder.id && !other.streaming && !want.failed.contains(other.id) && answer?.state == .have
                && answer?.load == 0
        }
        return idle.map { "streaming another file ~\(left) ms, \($0.id) idle" }
    }
}
