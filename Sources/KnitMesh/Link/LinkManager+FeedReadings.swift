public import KnitWire

/// A link's feeds as a holder reads them (`BluetoothMeshTransport.fileFeed`, `expectedFileRate` and `fileFeedsChanged`,
/// knit-next ADR 2026-10.nsr7): what `MeshEngine` weighs before it parks a second ask for a blob behind a copy it feeds.
extension LinkManager {
    /// The copy of `hash` the link to `peer` is feeding (`BluetoothMeshTransport.fileFeed`, `FramedLink.feed`, knit-next
    /// ADR 2026-10.nsr7): streaming it now, read by its meter. `nil` when it is not on that link, or is queued behind
    /// another file, so not fed yet. Android also reads a copy queued with nothing streaming, which its writer is about
    /// to take; here a link starts the next file the moment the last one ends, so no copy ever waits that way. Every
    /// link here shares one radio, so every feed counts.
    public func fileFeed(of hash: BlobHash, to peer: NodeId) -> FeedReading? {
        guard let id = liveChannel(to: peer), var feed = feeds[id], let streaming = feed.streaming, streaming.file.hash == hash else {
            return nil
        }
        let now = clock.monotonicMilliseconds()
        let settled = streaming.notedChunks >= Self.settleChunks
        let left = Int64(streaming.file.size - streaming.offset)
        let reading = feed.meter.reading(left: left, wroteAt: streaming.wroteAt, pace: streaming.notedPace, settled: settled, now: now)
        feeds[id] = feed
        return reading
    }

    /// How fast a file to `peer` would most likely go now, in bytes a second (`BluetoothMeshTransport.expectedFileRate`,
    /// `BleFeedPolicy.expectedRate`): a windowed link's last measured drain, shared with the other windowed feeds going
    /// now, else the share its pace would give it beside the paced feeds already going, times the share of its pace the
    /// link's last measured stream drained. 0 with no link. There is no Coded pace and no boost here.
    public func expectedFileRate(to peer: NodeId) -> Int64 {
        guard let link = liveLinks.first(where: { $0.neighbor.nodeId == peer }) else {
            return 0
        }
        let id = link.channel
        let feed = feeds[id]
        let drained = feed?.meter.lastRate ?? 0
        if drained > 0, configuration.feedWindow, link.neighbor.capabilities.contains(.blobHave) {
            let others = feeds.count { $0.key != id && $0.value.streaming?.windowedNow == true }
            return drained / Int64(others + 1)
        }
        let paced = feeds.count { $0.value.streaming.map { !$0.windowedNow } ?? false }
        let feeding = paced + (feed?.streaming == nil ? 1 : 0)
        let share = FilePace(
            budget: configuration.filePaceBudgetBytesPerSecond, feeding: feeding, maxChunkBytes: configuration.fileChunkBytes)
        return Int64(Double(share.bytesPerSecond) * (feed?.meter.drainRatio ?? 1))
    }

    /// Notes that a feed's reading moved (`FramedLink.onFeedChanged`): a stream ended or died with its link, its pace
    /// settled or moved, or its first report measured it.
    func noteFeedsChanged() {
        feedsChanged = true
    }

    /// Whether a feed's reading moved since the last call (`MeshTransport.fileFeedsChanged`, knit-next ADR 2026-10.nsr7):
    /// a bare poke, read after each batch of events, so the holder re-reads its parked asks on the edge rather than at
    /// its next poll. One pending poke says everything a second would.
    public func takeFeedsChanged() -> Bool {
        defer { feedsChanged = false }
        return feedsChanged
    }
}
