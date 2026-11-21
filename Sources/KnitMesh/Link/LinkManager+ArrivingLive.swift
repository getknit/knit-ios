public import KnitWire

/// Whether a file streaming in is moving, which custody reads to let a stalled stream stop coming first (the
/// `custody-carry-policy` contract, revision 16, §2). The clock it reads is the link's ``ArrivalClock``, stamped in
/// `LinkManager+Files.swift` at each header and chunk.
extension LinkManager {
    // MARK: MeshTransport

    /// Whether a file from `peer` is streaming in now and moved within the blob plane's stall span
    /// (``FeedMeter/stallMilliseconds``, 15 s): its header, or a chunk since, kept or skipped. Only a file that is moving
    /// comes first (the `custody-carry-policy` contract, revision 16, §2), so a stream that stopped lets custody's other
    /// tiers go, and holds them again once its next chunk comes. The clock is the link's (``ArrivalClock``), replaced at
    /// each header and forgotten with the link. False when nothing streams in from `peer` or it is unlinked.
    public func isFileArrivingLive(from peer: NodeId) -> Bool {
        guard let id = liveChannel(to: peer), intakes[id]?.isStreaming == true, let clock = arrivalClocks[id] else {
            return false
        }
        return self.clock.monotonicMilliseconds() - clock.movedAt < FeedMeter.stallMilliseconds
    }
}
