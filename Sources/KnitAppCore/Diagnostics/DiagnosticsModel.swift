public import KnitCrypto
import KnitMesh
public import KnitStore
public import KnitWire
public import Observation

/// How far a peer's clock sits from ours, estimated from what it sent (interop rule: Diagnostics shows each peer's
/// skew, since custody refuses a frame more than five minutes ahead without a word).
///
/// A message's `arrivedAt - sentAt` is the skew plus however long it took to arrive, so the smallest over a peer's
/// messages is the best estimate, and an upper bound on how far behind its clock runs. A negative one is certain:
/// the peer's clock is ahead by at least that much. Stored `sentAt` is clamped to five minutes past our clock, so an
/// estimate reads no further ahead than that.
public enum ClockSkew {
    /// Within this, the clocks agree.
    public static let inStepMilliseconds: Int64 = 2000

    static let millisecondsPerSecond: Int64 = 1000

    /// Our clock minus theirs plus the fastest arrival, over `messages` from them: `nil` with nothing to go on.
    public static func estimate(_ messages: [MessageRecord]) -> Int64? {
        messages.compactMap { message in message.arrivedAt.map { $0 - message.sentAt } }.min()
    }

    /// The estimate in words.
    public static func label(_ skew: Int64) -> String {
        if abs(skew) <= inStepMilliseconds {
            return Copy.Diagnostics.clockInStep
        }
        let seconds = Int(abs(skew) / millisecondsPerSecond)
        return skew < 0 ? Copy.Diagnostics.clockAhead(seconds: seconds) : Copy.Diagnostics.clockBehind(seconds: seconds)
    }
}

/// Stores a minted test identity where the next launch loads it: the app's Keychain, in a debug build.
public typealias IdentityReplacer = @Sendable (IdentityKeys) throws -> Void

/// A peer as Diagnostics lists it.
public struct DiagnosticsPeer: Sendable, Equatable, Identifiable {
    /// The node id.
    public var id: NodeId
    /// Its label.
    public var title: String
    /// What else is known: the link's version and capabilities, or a sighting's signal and age.
    public var detail: String
    /// Its clock against ours, when anything it sent says.
    public var clock: String?
}

/// Diagnostics, as one value.
public struct DiagnosticsState: Sendable, Equatable {
    /// The most out-of-range pinned peers listed.
    public static let knownShown = 5

    /// The radio's state in a word.
    public var radio: String
    /// Whether the mesh runs.
    public var isRunning: Bool
    /// The linked peers.
    public var linked: [DiagnosticsPeer]
    /// The peers sighted but not linked.
    public var sighted: [DiagnosticsPeer]
    /// The pinned peers neither linked nor sighted, newest profile first, at most ``knownShown`` of them: testing
    /// pins dozens, and a long list buries the counters below it.
    public var known: [DiagnosticsPeer]
    /// How many pinned peers are neither linked nor sighted, listed or not.
    public var knownCount: Int
    /// The counters worth a row: file records discarded, then each drop reason seen.
    public var counters: [Counter]

    /// One counter.
    public struct Counter: Sendable, Equatable, Identifiable {
        /// What it counts.
        public var id: String
        /// How many.
        public var count: Int
    }
}

/// Diagnostics' view model: what the mesh is doing, read when asked, and the debug build's test identities.
@preconcurrency
@MainActor
@Observable
public final class DiagnosticsModel {
    /// The last reading, or `nil` before the first.
    public private(set) var state: DiagnosticsState?
    /// What the last mint said, success or not.
    public private(set) var mintOutcome: String?
    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private let replaceIdentity: IdentityReplacer?

    /// Diagnostics over `session`. `replaceIdentity` stores a minted identity where the next launch loads it; it is
    /// `nil` in a release build, which then offers no test identities.
    @preconcurrency
    public init(session: AppSession, replaceIdentity: IdentityReplacer? = nil) {
        self.session = session
        self.replaceIdentity = replaceIdentity
    }

    /// Whether this build can mint test identities.
    public var mintsIdentities: Bool {
        replaceIdentity != nil
    }

    /// This device's node id.
    public var nodeId: String {
        session.identity.nodeId.string
    }

    /// This device's alias.
    public var alias: String {
        session.identity.alias
    }

    /// Reads the mesh again.
    public func refresh() async {
        let mesh = await session.diagnostics()
        state = Self.state(
            mesh, directory: session.directory, stores: session.stores, radio: session.radioState, running: session.isRunning)
    }

    /// Mints an identity whose node id sorts inside the bounds, either of which may be blank, and stores it for the
    /// next launch (MVP item 2, the app's `knit-peer keygen --above/--below`).
    public func mint(above: String, below: String) async {
        guard let replaceIdentity else {
            return
        }
        guard let window = Self.window(above: above, below: below) else {
            mintOutcome = Copy.TestIdentity.invalidNodeId
            return
        }
        let minted = await Task.detached { try? KeyGen.identity(in: window) }.value
        guard let minted else {
            mintOutcome = Copy.TestIdentity.noRoom
            return
        }
        do {
            try replaceIdentity(minted)
            mintOutcome = Copy.TestIdentity.minted(minted.nodeId.string)
        } catch {
            mintOutcome = "\(error)"
        }
    }

    /// The window between two typed bounds, or `nil` when one is neither blank nor a node id.
    static func window(above: String, below: String) -> KeyGen.Window? {
        func bound(_ text: String) -> NodeId?? {
            let trimmed = Composer.trimmed(text)
            return trimmed.isEmpty ? .some(nil) : NodeId(trimmed).map { .some($0) }
        }
        guard let lower = bound(above), let upper = bound(below) else {
            return nil
        }
        return KeyGen.Window(above: lower, below: upper)
    }

    static func state(
        _ mesh: MeshDiagnostics,
        directory: Directory,
        stores: MeshStores,
        radio: RadioState?,
        running: Bool
    ) -> DiagnosticsState {
        let linkedIds = Set(mesh.neighbors.map(\.nodeId))
        let sightedIds = Set(mesh.sightings.map(\.nodeId))
        let room = stores.messages.messages(in: Conversations.nearby)
        func clock(_ peer: NodeId) -> String? {
            let theirs = room.filter { $0.senderId == peer } + stores.messages.messages(in: peer.string).filter { $0.senderId == peer }
            return ClockSkew.estimate(theirs).map(ClockSkew.label)
        }
        let linked = mesh.neighbors.map { neighbor in
            DiagnosticsPeer(
                id: neighbor.nodeId,
                title: directory.label(for: neighbor.nodeId).text,
                detail: Copy.Diagnostics.link(version: neighbor.protocolVersion, capabilities: neighbor.capabilities.hex),
                clock: clock(neighbor.nodeId)
            )
        }
        let sighted = mesh.sightings.filter { !linkedIds.contains($0.nodeId) }.map { sighting in
            DiagnosticsPeer(
                id: sighting.nodeId,
                title: directory.label(for: sighting.nodeId).text,
                detail: Copy.Diagnostics.sighting(
                    rssi: Int(sighting.smoothedRssi.rounded()),
                    secondsAgo: Int(sighting.lastSeenAgoMilliseconds / ClockSkew.millisecondsPerSecond)
                ),
                clock: clock(sighting.nodeId)
            )
        }
        let outOfRange = directory.peers.values
            .filter { !linkedIds.contains($0.nodeId) && !sightedIds.contains($0.nodeId) }
            .sorted { ($0.updatedAt, $1.nodeId) > ($1.updatedAt, $0.nodeId) }
        let known = outOfRange.prefix(DiagnosticsState.knownShown)
            .map { peer in
                DiagnosticsPeer(
                    id: peer.nodeId, title: directory.label(for: peer.nodeId).text, detail: peer.nodeId.string, clock: clock(peer.nodeId))
            }
        let drops = DropReason.allCases.compactMap { reason in
            mesh.dropped[reason].map { DiagnosticsState.Counter(id: Copy.Drops.reason(reason), count: $0) }
        }
        return DiagnosticsState(
            radio: Copy.Diagnostics.radio(radio),
            isRunning: running,
            linked: linked,
            sighted: sighted,
            known: known,
            knownCount: outOfRange.count,
            counters: [
                DiagnosticsState.Counter(id: Copy.Diagnostics.filesReceived, count: mesh.files.received),
                DiagnosticsState.Counter(id: Copy.Diagnostics.filesRefused, count: mesh.files.refused),
                DiagnosticsState.Counter(id: Copy.Diagnostics.filesSent, count: mesh.files.sent),
            ] + drops
        )
    }
}
