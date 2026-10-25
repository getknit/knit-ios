import KnitMesh
import KnitStore
import KnitWire

/// How far the photos streaming in have got, sampled while a thread waits on one (knit-next ADR 2026-10.y9qh).
extension AppSession {
    /// How long to wait before the next sample while a file streams in, and while none does (`ARRIVAL_ACTIVE_MS` and
    /// `ARRIVAL_IDLE_MS` in `ArrivalTicker.kt`). A link raises no event per chunk, so the thread samples rather than
    /// listens.
    static let arrivalActiveMilliseconds: Int64 = 500
    static let arrivalIdleMilliseconds: Int64 = 2000
    static let arrivalActivePause = Duration.milliseconds(arrivalActiveMilliseconds)
    static let arrivalIdlePause = Duration.milliseconds(arrivalIdleMilliseconds)

    /// Reads once how far each kept file streaming in has got, into ``arrivals``, and answers how long to wait before the
    /// next read. A thread runs it in a loop while one of its photos is on its way, so a settled thread never samples.
    /// While Knit is not in front it reads nothing: no bubble is on screen.
    ///
    /// The mesh stores a photo in the same turn its last chunk lands, so a read can find it gone before its
    /// ``MeshEvent/attachmentArrived(_:)`` has redrawn the row. A photo that leaves with its bytes held therefore stays
    /// whole for one more sample, by when its event has redrawn the row, and the bubble never steps back to its waiting
    /// line in between (the gap knit-next closed with `LandingFiles`, #138). One sample only: an event that lands while a
    /// read is on its way, or a profile photo, which raises none, would otherwise be held for good. One that leaves with
    /// its bytes missing was cut off, and drops at once.
    @discardableResult
    public func sampleArrivals() async -> Duration {
        guard isActive else {
            return Self.arrivalIdlePause
        }
        let streaming = await mesh.arrivingFiles
        var next = streaming.mapValues(PhotoArrival.init)
        let left = Set(arrivals.byHash.keys).subtracting(next.keys).subtracting(arrivals.heldOver)
        let held = left.isEmpty ? [] : stores.blobs.held(among: left)
        for hash in held {
            next[hash] = arrivals.byHash[hash]?.whole
        }
        arrivals.heldOver = held
        if next != arrivals.byHash {
            arrivals.byHash = next
        }
        return streaming.isEmpty ? Self.arrivalIdlePause : Self.arrivalActivePause
    }
}
