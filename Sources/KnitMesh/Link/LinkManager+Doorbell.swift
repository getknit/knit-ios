import KnitWire

/// Ringing a peer's doorbell after writing frames to it. iOS does not wake a suspended app for data on an open L2CAP
/// link, and does for a write to its GATT doorbell, so a frame an iPhone's link carries waits for Knit to run
/// unless it rings. Which peers have a doorbell is the radio's to know; this decides when (ADR router:
/// `.agents/memory/decisions.md`).
extension LinkManager {
    /// The frame types that never ring: the link's upkeep, which waits for the next wake as a digest does. A typing
    /// cue is worthless to a locked phone, and the 60 s tick re-sends `blobreq`, `blobhave` and `keyreq` for as long as
    /// a blob or a key is missing, which would wake the iPhone every minute; a `blobhas` only answers one. Android skips
    /// the same five (`DoorbellPolicy.UPKEEP`, `DoorbellPolicy.kt:68-75`, knit-next ADRs 2026-09.dqvb and 2026-10.6e5t),
    /// so both platforms wake an iPhone equally often.
    static let upkeepTypes: Set<FrameType> = [.typing, .blobRequest, .blobHave, .blobHas, .keyRequest]

    /// Whether writing `wire` rings: every frame but upkeep's. One whose type cannot be read rings, as on Android.
    static func rings(_ wire: WireEnvelope) -> Bool {
        guard let envelope = try? RelayEnvelope(decoding: wire.signed) else {
            return true
        }
        return !upkeepTypes.contains(envelope.type)
    }

    /// A frame that rings (``rings(_:)``) went out on `id`. The doorbell rings now, or once the interval since its
    /// last ring has passed, so a burst costs one ring at its start and one after its end. Digests and HELLOs do not
    /// ring either: they are the link's own upkeep, read at the next wake.
    func ringAfterFrame(on id: ChannelID, now: Int64) {
        let interval = configuration.ringIntervalMilliseconds
        guard interval > 0 else {
            return
        }
        if let rang = doorbells[id]?.rang, now - rang < interval {
            doorbells[id]?.due = rang + interval
        } else {
            ring(id, now: now)
        }
    }

    /// Rings every doorbell whose next ring has come due.
    func ringDue(now: Int64) {
        let due = doorbells.filter { $0.value.due.map { now >= $0 } ?? false }.map(\.key).sorted(by: Self.inOrder)
        for id in due {
            ring(id, now: now)
        }
    }

    private func ring(_ id: ChannelID, now: Int64) {
        doorbells[id] = Doorbell(rang: now, due: nil)
        rings += 1
        radio.ring(id)
    }
}
