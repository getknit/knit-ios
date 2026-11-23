public import KnitWire

/// Who may link at all: knit-peer's `deny-link` and `allow-link` (``LinkManager/refuse(_:)``, ``LinkManager/permit(_:)``)
/// and its `--only-link` allow list (``LinkManager/Configuration/onlyLinks``), read through one predicate,
/// ``LinkManager/refuses(_:)``, by every admission, dial and registration (knit-ios #58).
extension LinkManager {
    /// Refuses every link with `peer`, both ways, until ``permit(_:)``: closes its live link and any dial to it, never
    /// dials it, and closes its HELLO when it dials us. An unresolved tag names no id, so it is dialed until a dial to it
    /// proves `peer`; that dial closes before our PROOF, and the tag at that address is not dialed again while `peer` stays
    /// refused (``refusedTagDial(_:_:_:now:)``): one dial per rotation, address and start, and one more after 90 s
    /// unheard. A rig's tool for forcing a line of nodes that could all hear each other (knit-peer's `deny-link`). It
    /// edits this list alone, so inside an allow list (``Configuration/onlyLinks``) it refuses a named id, and outside it
    /// changes nothing. Answers the link that went down.
    public func refuse(_ peer: NodeId) -> [Event] {
        refused.insert(peer)
        let now = clock.monotonicMilliseconds()
        let theirs = channels.filter { entry in
            entry.value.stage == .live(peer) || Self.dials(peer, entry.value) || Self.awaitsProof(of: peer, entry.value)
        }
        return theirs.keys.sorted(by: Self.inOrder).flatMap { retire($0, backingOff: false, now: now) } + reconsiderSeeking(now: now)
    }

    /// Lets `peer` link again, and dials it now if the promotion rules say so. Outside an allow list
    /// (``Configuration/onlyLinks``) it lets nothing in, so the tags a dial proved `peer` behind stay marked.
    public func permit(_ peer: NodeId) -> [Event] {
        refused.remove(peer)
        refusedDials = refusedDials.filter { refuses($0.value) }
        let now = clock.monotonicMilliseconds()
        return promote(now: now) + reconsiderSeeking(now: now)
    }

    /// Whether no link with `peer` may stand: ``refuse(_:)`` named it (knit-peer's `deny-link`), or an allow list is set and
    /// lacks it (``Configuration/onlyLinks``, knit-peer's `--only-link`). Every admission, dial and registration reads this,
    /// never ``refused`` alone.
    func refuses(_ peer: NodeId) -> Bool {
        refused.contains(peer) || configuration.onlyLinks.map { !$0.contains(peer) } == true
    }

    /// Whether promotion passes a sighting kept under `key` over for whom it names: an id this node refuses (``refuses(_:)``),
    /// or, under an allow list (``Configuration/onlyLinks``), a blinded form held under a handle, which names no id to check
    /// (knit-ios #58). Whichever rule would dial it, the order under our own blinding, the head start, seeking or the relink
    /// window, it is never dialed. A form a key, claim or hint resolves is kept under its id and judged as a clear sighting
    /// is; a claim or hint is unproven, so a tag dial whose proof names another id still closes (``refusedTagDial(_:_:_:now:)``).
    func refusesSighting(_ key: SightingKey) -> Bool {
        guard let id = key.nodeId else {
            return configuration.onlyLinks != nil
        }
        return refuses(id)
    }

    /// Whether a dialer whose HELLO names `dialer` is refused (``refuses(_:)``), closed with no reply and never registered.
    /// An allow list's refusal says so, since nothing else in the log tells a trial why an unnamed phone never linked;
    /// `deny-link`'s close stays silent, as it always was. No harness reads the line.
    func refusesDialer(_ dialer: NodeId) -> Bool {
        guard refuses(dialer) else {
            return false
        }
        if !refused.contains(dialer) {
            log.log(.info, "link refused \(dialer): not on the allow list")
        }
        return true
    }

    /// Whether `channel` is a clear dial to `peer`.
    static func dials(_ peer: NodeId, _ channel: Channel) -> Bool {
        if case .dialer(let target) = channel.role {
            return target.expected == peer
        }
        return false
    }
}
