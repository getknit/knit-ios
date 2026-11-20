/// The line a digest answer's round waits at (ADR 2026-10.f5zs, the `custody-carry-policy` contract, §2): the round waits
/// on the link, never on the peer.
///
/// While a link still holds ``lineBytes`` unwritten (`MeshTransport.queuedBytes(to:)`), a round due on it waits
/// ``recheckMilliseconds`` and is cut fresh then, never larger, so a peer that reads slowly, or not at all, is never handed
/// round on round. The pace (``CustodyAnswers``) keeps an honest link far below it: a round is 16 KiB every 2 s at most. A
/// file feed keeps at most its window queued, 64 KiB (`FeedWindow.maxWindowBytes`), below the line, so a photo streaming
/// never holds a round off. The answer keeps the peer's latest digest, which is what the one slot per neighbour this type
/// once held did.
///
/// Android has no line: its writer takes every round as it is cut. The line changes only when we answer, never what, so it
/// is this port's alone.
public enum HeldDigests {
    /// The unwritten bytes at which a link's round waits: 128 KiB, a local guard and no longer derived from the round.
    public static let lineBytes = 131_072
    /// How long a round that waits on the line waits before it is looked at again, on the monotonic clock.
    public static let recheckMilliseconds: Int64 = 5000
}
