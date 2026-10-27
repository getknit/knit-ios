import KnitWire

/// A spliced file that failed its hash starts over from byte 0 (`reaskFromZero`, `BlobExchange.kt:2041-2059`, knit-ios #2).
extension BlobExchange {
    /// Opens a forced cycle for `hash` at `now`, passing over `failing`, the holder whose tail made the bad splice: its serve
    /// memo still stands, and the others answer at once. The want that stood goes on; one swept or evicted while its prefix
    /// was kept is made afresh, our own, with no budget, so this site mints no root (`BlobExchange.kt:2358-2361`): the next re-arm
    /// from the stores makes it one again within a round if a row names the hash. Never ``recordWant(_:now:wall:author:via:asker:reach:)``
    /// with ``Reach/own(until:rederived:)``, which would hand it the whole pull budget. Kotlin's fresh want is fast-only
    /// until that re-arm; this port has no fast plane.
    mutating func restartFromZero(_ hash: BlobHash, failing: NodeId?, now: Int64, wall: Int64) {
        // Ours: a kept prefix sets this off (``MeshEngine/restartFailedSplice(_:)``), and only a want of ours keeps one
        // (knit-ios #20), so a fresh one evicts an echo before any want of ours, and never itself.
        let fresh = wants[hash] == nil
        var want = wants[hash] ?? Want(hash: hash, at: now, author: nil, via: nil, puller: nil)
        if fresh {
            admit(want)
        }
        want.wantedAt = now
        want.openCycle(at: now, wall: wall, natural: false)
        if let failing {
            want.failed.insert(failing)
        }
        wants[hash] = want
    }
}
