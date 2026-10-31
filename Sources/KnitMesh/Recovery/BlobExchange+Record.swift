import KnitWire

/// Recording a want (`recordWant`, `BlobExchange.kt`), apart from ``BlobExchange``'s body for its length.
extension BlobExchange {
    /// Wants `hash`, or refreshes the want and fills in the hints it lacked (`recordWant`). `author` and `via` rank the
    /// neighbours that cannot be queried; `asker` is a neighbour we are pulling it for, which this cycle neither queries
    /// nor asks, and `reach` the budget and deadline the want is recorded with (knit-next ADR 2026-10.2drc). Answers the
    /// log lines it owes.
    ///
    /// A new want with no `asker` is our own, and one with an `asker` an echo made for it (``Origin``, knit-ios #20). A full
    /// set drops an echo of the asker holding the most (``admit(_:)``), so no echo ever costs a want of ours; a new echo
    /// that would is not recorded (``echoRefusal(_:)``), and the caller counts and logs it. Android drops the oldest want
    /// whoever made it (`BlobExchange.kt`'s `MAX_FETCHING`).
    ///
    /// A new want takes `reach` as it is. A want of our own (no `asker`) is a root, re-derived every time: it is refreshed,
    /// takes the whole budget back, and takes the deadline when its caller read every row naming the hash
    /// (``Reach/rederived``) or names one, so a caller that read nothing keeps the one the re-arm set. A neighbour's ask
    /// refreshes it only as ``noteAsker(_:_:_:now:wall:)`` allows. `wall` is the wall clock, which the deadline is read
    /// against when the ask opens the next cycle. It takes eight parameters, as Kotlin's does: this port has no fast-only
    /// flags, and has the wall clock and the want's `kind` instead.
    ///
    /// A photo want of ours (``WantKind/photo``) of a hash refused as a photo this session records nothing, a want standing
    /// on the hash left as it was (`want`, `BlobExchange.kt:289` at knit-next `a0b52f865`). Otherwise a new want of our own
    /// of ``WantKind/photo`` is photo-only, its bytes kept to the photo's ceiling (``overPhotoCeiling(_:from:)``). On a want
    /// that stands, only a want of ours moves the ceiling (`recordWant`, `BlobExchange.kt:2211`): our first on a want only
    /// neighbours' asks made sets its own, so a photo want of ours makes an echo photo-only, and any later want of ours that
    /// is not a photo's clears it for the want's life, the larger limit winning (`mergeCeiling`, `:2233-2253`). A
    /// neighbour's ask moves no ceiling (`:116`), or a holder passed over could lift it by asking us for the hash.
    mutating func recordWant( // swiftlint:disable:this function_parameter_count
        _ hash: BlobHash, now: Int64, wall: Int64, author: NodeId?, via: NodeId?, asker: NodeId?, reach: Reach,
        // A want of any kind but a profile photo's, as every site but a profile's records.
        kind: WantKind = .attachment // swiftlint:disable:this discouraged_default_parameter
    ) -> [String] {
        let photo = asker == nil && kind == .photo
        if photo, photoRefusals.isRefused(hash) {
            return []
        }
        guard var want = wants[hash] else {
            if asker != nil, echoRefusal(hash) != nil {
                return []
            }
            var made = Want(hash: hash, at: now, author: author, via: via, puller: asker)
            made.budget = reach.budget
            made.until = reach.until
            made.photoOnly = photo
            admit(made)
            return []
        }
        if asker == nil {
            // `mergeCeiling`: one photo ceiling here, so two photo wants keep it, and `max` is the identity.
            if !want.ownRecorded {
                want.photoOnly = photo
            } else if !photo {
                want.photoOnly = false
            }
            want.ownRecorded = true
            // Refreshed in place: the order is when it was first wanted, as in Android's insertion-ordered map. No longer
            // on every recorded want (knit-next ADR 2026-10.2drc): an ask refreshing it is what let echoes keep it alive.
            // An echo a want of ours names is ours from now on (knit-ios #20).
            want.origin = .own
            want.wantedAt = now
            want.budget = Self.pullBudget
            if reach.rederived || reach.until != nil {
                want.until = reach.until
            }
        }
        want.author = want.author ?? author
        want.via = want.via ?? via
        var notes: [String] = []
        if let asker {
            notes = noteAsker(&want, asker, reach, now: now, wall: wall)
        }
        wants[hash] = want
        return notes
    }
}
