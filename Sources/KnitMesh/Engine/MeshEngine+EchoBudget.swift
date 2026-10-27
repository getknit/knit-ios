import KnitStore
import KnitWire

/// What a want made for an asker may cost (knit-ios #20, ``BlobExchange``'s echoes and ``EchoBudget``): the engine's half,
/// which reads the store and the links. The rules are local and on no wire; Android applies none of them to an echo
/// (`echoFor`, `BlobExchange.kt:1698-1720` at knit-next `4408e0fca`).
extension MeshEngine {
    /// Why an ask for `hash`, which we lack, that `reached` so far makes no echo here, or `nil` when it may
    /// (`echoRefused`): it allowed no budget or is past its deadline (``BlobExchange/echoRefusal(pull:until:wall:)``, as
    /// Android refuses it), or, this port's alone, the want set is full of ours (``BlobExchange/echoRefusal(_:)``), or it
    /// would be a new want and the echo budget is spent, or a file of it was refused for the budget since the last sweep.
    /// An ask for a hash already wanted only joins that want, and costs nothing new.
    func echoDecline(_ hash: BlobHash, reached: BlobExchange.Reached) -> String? {
        if let refused = BlobExchange.echoRefusal(pull: reached.pull, until: reached.deadline, wall: clock.wallMilliseconds()) {
            return refused
        }
        if let refused = blobExchange.echoRefusal(hash) {
            return refused
        }
        guard !blobExchange.isWanted(hash), !transport.arrivingFileKeys.contains(hash) else {
            return nil
        }
        return blobExchange.echoBudget.hasRefused(hash) || echoBudgetSpent() ? "over budget" : nil
    }

    /// Whether no new echo may be made: what we hold that no row names, and what the echoes fetching now may bring, reach
    /// ``BlobExchange/echoBudgetBytes``. The held bytes are an upper bound between sweeps, so a reading that is spent is
    /// measured again first, at most every ``BlobExchange/echoRemeasureMilliseconds``.
    func echoBudgetSpent() -> Bool {
        let reserved = blobExchange.echoReservedBytes(arriving: transport.arrivingFileKeys, excluding: nil)
        guard blobExchange.echoBudget.isSpent(reserved: reserved) else {
            return false
        }
        remeasureEchoBudget()
        return blobExchange.echoBudget.isSpent(reserved: reserved)
    }

    /// Whether `bytes` more for an echo fit the budget beside what the other echoes fetching now may bring, `hash`'s own
    /// reservation set aside, measured again first as ``echoBudgetSpent()`` is when it reads full.
    func echoBudgetFits(_ bytes: Int64, excluding hash: BlobHash) -> Bool {
        let reserved = blobExchange.echoReservedBytes(arriving: transport.arrivingFileKeys, excluding: hash)
        guard !blobExchange.echoBudget.fits(bytes, reserved: reserved) else {
            return true
        }
        remeasureEchoBudget()
        return blobExchange.echoBudget.fits(bytes, reserved: reserved)
    }

    /// ``measureEchoBudget()``, unless one was tried within ``BlobExchange/echoRemeasureMilliseconds``.
    private func remeasureEchoBudget() {
        if blobExchange.echoBudget.mayRemeasure(now: clock.monotonicMilliseconds()) {
            measureEchoBudget()
        }
    }

    /// Weighs the blobs we hold that no row names (``blobsTheRowsName()``), custody's carried photos among them, in one
    /// store unit: a read that fails fails the unit and leaves the last measure standing, since outside one a failed read
    /// answers 0 bytes and every row unread, which would open the budget or close it for nothing. At start and at each
    /// sweep, and when the budget reads spent.
    func measureEchoBudget() {
        let now = clock.monotonicMilliseconds()
        blobExchange.echoBudget.tried(at: now)
        let blobs = stores.blobs
        let unit = stores.transactor.atomically { () -> Int? in
            let unnamed = Set(blobs.allHashes()).subtracting(blobsTheRowsName())
            return unnamed.isEmpty ? 0 : blobs.totalBytes(among: unnamed)
        }
        guard case .committed(let bytes) = unit else {
            log.log(.info, "mesh blob echo budget unread; \(blobExchange.echoBudget.heldForOthers) bytes kept")
            return
        }
        blobExchange.echoBudget.measured(Int64(bytes), at: now)
    }

    /// A want of ours for `hash`, whose bytes are on their way in or held: an echo still standing for it is ours from now
    /// on, so the links keep a prefix of its stream if the link is cut (knit-ios #20). Nothing is asked: the stream is
    /// what brings it, and the next re-arm once it is not arriving refreshes the want as any of ours.
    func promoteArriving(_ hash: BlobHash) {
        if blobExchange.promote(hash) {
            syncAcceptedFiles()
        }
    }

    /// Makes room in a full set for `hash`, about to be wanted for `asker`, or for us with `nil`, by the fair rule, reading
    /// the blobs arriving (``BlobExchange/makeRoom(for:asker:arriving:)``), and withdraws the asks of the want dropped.
    func makeRoom(for hash: BlobHash, asker: NodeId?) {
        blobExchange.makeRoom(for: hash, asker: asker, arriving: transport.arrivingFileKeys)
        withdrawEvicted()
    }

    /// The wants a full set dropped (``BlobExchange/admit(_:)``): each ask of ours still standing on one is withdrawn
    /// (knit-next ADR 2026-10.nsr7), so a copy a holder queued for it is not sent for nothing.
    func withdrawEvicted() {
        for dropped in blobExchange.takeEvicted() {
            withdrawAsks(dropped.hash, from: dropped.asks)
        }
    }

    /// A file fetched for an asker alone that the echo budget has no room for: dropped, and its want with it, our asks
    /// still standing on other holders withdrawn, and the hash remembered until the next sweep, so the asker's next ask
    /// makes no echo that fetches the same bytes again. A peer that streams a file for an echo it was never asked for lands
    /// here too, since the links keep any file wanted.
    func refuseEchoFile(_ file: InboundFile) {
        blobExchange.counts.echoFilesRefused += 1
        blobExchange.echoBudget.refuse(file.hash)
        withdrawAsks(file.hash, from: blobExchange.obtained(file.hash, from: file.from))
        syncAcceptedFiles()
        reject(file, "is past the echo budget")
    }
}
