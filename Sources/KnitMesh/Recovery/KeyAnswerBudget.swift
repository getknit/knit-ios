import KnitWire

/// A byte bucket per link peer for the profiles ``KeyExchange`` serves (ADR 2026-10.f5zs, rule 5), shared by a `keyreq`'s
/// answers and by the wanters served when a pin lands. Android serves every held id a request names, unbounded
/// (`KeyExchange.kt:126-141` at knit-next `e63f15f4`), and a profile has no byte cap yet (knit-ios #22), so one signed
/// request of 128 ids could queue about 64 MB on a link, as often as its asker mints request ids. This bound is this
/// port's own.
///
/// It runs on debt: a peer is served while its balance is above zero, each profile charged its encoded bytes, and the
/// balance may go negative. So a profile larger than the burst still goes out once, and nothing more until the debt is
/// repaid. The key is the link peer's HELLO id, as the digest meter's is, never a request's signer: a fork replaying
/// requests it captured from many signers must not earn a bucket for each. Shaped as ``AnswerBudget``: refilled
/// continuously, at most ``maxPeers`` remembered, the least recently charged dropped first, and one dropped comes back
/// full. Times are on the monotonic clock.
internal struct KeyAnswerBudget: Sendable {
    /// The bytes a peer may be served in a burst: a 128-id request of 2 KiB profiles fits.
    static let burstBytes = 262_144.0
    /// The bytes a second its balance refills by.
    static let refillBytesPerSecond = 8192.0
    /// The most peers whose balances are remembered.
    static let maxPeers = AnswerBudget.maxPeers
    private static let millisecondsPerSecond = 1000.0

    /// One peer's balance, which may be negative, and when it was last counted.
    private struct Bucket {
        var peer: NodeId
        var balance: Double
        var at: Int64
    }

    private var buckets: [Bucket] = []

    /// Whether `peer` may be served `bytes` at `now`, charging them if so: it may while its refilled balance is above zero,
    /// however far the charge takes it below. The bucket moves to the back either way.
    mutating func charge(_ bytes: Int, to peer: NodeId, now: Int64) -> Bool {
        var balance = Self.burstBytes
        if let index = buckets.firstIndex(where: { $0.peer == peer }) {
            let bucket = buckets.remove(at: index)
            balance = min(
                Self.burstBytes, bucket.balance + Double(max(0, now - bucket.at)) * Self.refillBytesPerSecond / Self.millisecondsPerSecond)
        }
        let admitted = balance > 0
        buckets.append(Bucket(peer: peer, balance: admitted ? balance - Double(bytes) : balance, at: now))
        if buckets.count > Self.maxPeers {
            buckets.removeFirst(buckets.count - Self.maxPeers)
        }
        return admitted
    }
}
