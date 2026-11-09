/// The manager's timer: what ``LinkManager/nextDeadline`` wakes for.
extension LinkManager {
    /// Times out dials, HELLOs and PROOFs, re-advertises a settled cue, rings doorbells that are due, feeds files, sends the
    /// trailing reports that are due, and dials peers whose backoff has run out or whose dwell has just ended.
    public func advance() -> [Event] {
        let now = clock.monotonicMilliseconds()
        var events = takeDeferredDowns()
        let expired = channels.filter { $0.value.deadline.map { now >= $0 } ?? false }.map(\.key).sorted(by: Self.inOrder)
        for id in expired {
            if putOffLateDeadline(of: id, now: now) {
                continue
            }
            let dialed = channels[id]?.role != .responder
            sayTimedOut(id)
            events += retire(id, backingOff: dialed, now: now)
        }
        if let due = advertDue, now >= due {
            advertDue = nil
            advertiseNow()
        }
        ringDue(now: now)
        advanceBlind(now: now)
        events += checkWriteStalls(now: now)
        events += reportTrailing(now: now)
        events += feedDueFiles(now: now)
        return events + promote(now: now) + reconsiderSeeking(now: now)
    }

    /// Says why `id`'s deadline closes it, in the line its stage's harness reads, before it is retired.
    private func sayTimedOut(_ id: ChannelID) {
        if case .awaitingProof(let pending)? = channels[id]?.stage {
            // Never `timed out`, which the harness reads as a missed HELLO.
            proofFailed(on: id, for: pending.peer, why: "timeout")
        } else if channels[id]?.stage == .awaitingKeyShare, case .dialer(let target)? = channels[id]?.role {
            // Never `timed out` either, and never a failed seal: the no-reply refusal a missed HELLO is on a plain dial.
            log.log(.info, "link \(id) got no key share from \(target.shown)")
        } else {
            noteNoReply(on: id)
            log.log(.info, "link \(id) timed out")
        }
    }
}
