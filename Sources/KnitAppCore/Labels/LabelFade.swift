public import KnitStore
public import KnitWire

/// When a stranger's name clash fades (`LabelFade` in knit-next, ADR 2026-10.k8ge there): two people named "Alice"
/// both wear their alias while both are around, and once the stranger has gone a week without a signed frame reaching
/// this phone, the contact reads plain again. The stranger stays labelled apart (``PeerLabelIndex``'s `stale`).
///
/// When a peer was last heard is what the peer's frames say: sender-asserted, and carried by replays. It decides how a
/// label reads and nothing else: never presence, a route, custody, or what is evicted first.
public enum LabelFade {
    /// A week: a stranger met at an event keeps a same-named contact suffixed while they come and go over its days, so
    /// the contact's label does not flicker, and an event's crowd has stopped suffixing anyone by the next week.
    public static let windowMilliseconds: Int64 = 604_800_000

    /// How often an open session judges the window again, so a stranger crosses the line on the calendar with nothing
    /// written. Against a week, an hour late is nothing.
    public static let tickMilliseconds: Int64 = 3_600_000

    /// Whether `nodeId`'s clash has faded at `now`: neither verified nor among `anchors`, and last heard before the
    /// window. Strict, so a stranger silent for exactly a week still clashes.
    public static func fades(nodeId: NodeId, verified: Bool, lastSeenAt: Int64, anchors: Set<NodeId>, now: Int64) -> Bool {
        !verified && !anchors.contains(nodeId) && quiet(lastSeenAt: lastSeenAt, now: now)
    }

    /// The members of `peers` whose clash has faded at `now`. `anchors` is read only when an unverified peer has gone
    /// quiet, since it costs a look through the messages, and answers `nil` when it could not be read: then nothing fades,
    /// which keeps every clash as it was. An empty set in its place would turn every quiet contact into a stranger.
    public static func stale(among peers: [PeerRecord], now: Int64, anchors: () -> Set<NodeId>?) -> Set<NodeId> {
        let quiet = peers.filter { !$0.verified && quiet(lastSeenAt: $0.lastSeenAt, now: now) }
        guard !quiet.isEmpty, let anchored = anchors() else {
            return []
        }
        return Set(quiet.lazy.map(\.nodeId).filter { !anchored.contains($0) })
    }

    private static func quiet(lastSeenAt: Int64, now: Int64) -> Bool {
        lastSeenAt < now - windowMilliseconds
    }
}
