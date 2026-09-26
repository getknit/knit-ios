import KnitCrypto
import KnitMesh
import KnitStore
public import KnitWire
public import Observation

/// Another person's profile, as one value (MVP item 3).
public struct PeerProfileState: Sendable, Equatable {
    /// The person.
    public var nodeId: NodeId
    /// Their label: their name, discriminated when someone else shares it.
    public var title: String
    /// Their alias, grown as far as their label needed.
    public var alias: String
    /// Their status line, possibly empty.
    public var status: String
    /// Whether they invite DMs from people they have not met.
    public var openToChat: Bool
    /// Whether their phone is linked now.
    public var isLinked: Bool
    /// The safety number both phones should read, in two lines of four groups, or `nil` before their key pins.
    public var safetyNumber: [String]?
    /// Whether the user compared safety numbers and marked them verified.
    public var isVerified: Bool

    /// The DM thread with them.
    public var conversationId: String { nodeId.string }
}

/// Another person's profile's view model: who they are, whether their key is verified, and the way to message
/// them.
@preconcurrency
@MainActor
@Observable
public final class PeerProfileModel {
    /// The person.
    public let nodeId: NodeId
    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private var cache = Cached<Int, PeerProfileState>()

    /// `nodeId`'s profile over `session`.
    public init(nodeId: NodeId, session: AppSession) {
        self.nodeId = nodeId
        self.session = session
    }

    /// The profile, rebuilt only when something changed.
    public var state: PeerProfileState {
        let linked = session.neighbors.contains { $0.nodeId == nodeId }
        var reading = cache.value(for: session.revision) { build() }
        reading.isLinked = linked
        return reading
    }

    /// Whether this is our own id, which has no DM thread and nothing to verify.
    public var isSelf: Bool {
        nodeId == session.identity.nodeId
    }

    /// Marks the person verified, or clears it.
    public func setVerified(_ verified: Bool) async {
        await session.setVerified(nodeId, verified)
    }

    private func build() -> PeerProfileState {
        let directory = session.directory
        let peer = directory.peers[nodeId]
        let label = directory.label(for: nodeId)
        let theirs = peer.flatMap { PublicKeyBundle(encoded: $0.publicKey) }
        return PeerProfileState(
            nodeId: nodeId,
            title: label.text,
            alias: label.alias,
            status: peer?.status ?? "",
            openToChat: peer?.openToChat ?? false,
            isLinked: false,
            safetyNumber: theirs.map { Self.lines(SafetyNumber.compute(mine: session.identity.bundle, theirs: $0)) },
            isVerified: peer?.verified ?? false
        )
    }

    /// A safety number shows on two lines.
    static let lineCount = 2
    /// The groups on each line of a safety number.
    static let groupsPerLine = SafetyNumber.groupCount / lineCount

    /// Eight groups of five digits as two lines of four, the way both phones lay them out.
    static func lines(_ number: String) -> [String] {
        let groups = number.split(separator: " ")
        return stride(from: 0, to: groups.count, by: groupsPerLine).map { start in
            groups[start..<min(start + groupsPerLine, groups.count)].joined(separator: " ")
        }
    }
}
