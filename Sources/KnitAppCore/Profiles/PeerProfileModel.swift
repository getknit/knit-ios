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
    /// Our own verify code, for them to scan (`VerifyPayload`).
    public var ownCode: String
    /// Their face: their photo, or their initial on their tint.
    public var face: Face
    /// Whether the user blocked them (ADR 2026-10.5wgg).
    public var isBlocked: Bool

    /// The DM thread with them.
    public var conversationId: String { nodeId.string }
}

/// What scanning a code on someone's profile found (ADR 2026-10.65xx). Android answers MATCH or MISMATCH
/// (`ProfileDetailsViewModel.onScanned`); iOS also names our own code and a QR code that is not a Knit code, which
/// changes only what the user reads.
public enum VerifyScanOutcome: Sendable, Equatable, CaseIterable {
    /// Their code carries the key pinned for them, so they are now verified.
    case match
    /// A valid code, but someone else's, or a key other than the one pinned.
    case mismatch
    /// Our own code.
    case ownCode
    /// Not a Knit code, or one no key could have made.
    case notACode
}

/// Another person's profile's view model: who they are, whether their key is verified, the way to message them, Block
/// and Report.
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

    /// Blocks the person, or unblocks them (`ProfileDetailsViewModel.block` and `unblock`).
    public func setBlocked(_ blocked: Bool) async {
        if blocked {
            await session.block(nodeId)
        } else {
            await session.unblock(nodeId)
        }
    }

    /// A report of the person, with their status line (ADR 2026-10.f6kf), or `nil` on our own profile.
    public var reporting: AbuseReport? {
        guard !isSelf else {
            return nil
        }
        let profile = state
        return AbuseReport(person: nodeId, name: profile.title, place: .profile, status: profile.status)
    }

    /// Files `report` on this iPhone: the person is blocked.
    public func report(_ report: AbuseReport) async {
        await session.report(report)
    }

    /// Compares a scanned code with the key pinned for this person, and marks them verified on an exact match
    /// (`ProfileDetailsViewModel.kt:397-411`). It never pins a key, and a mismatch never clears an earlier
    /// verification.
    public func scanned(_ text: String) async -> VerifyScanOutcome {
        guard let code = VerifyPayload.parse(text), let scanned = code.certifiedNodeId else {
            return .notACode
        }
        if scanned == session.identity.nodeId {
            return .ownCode
        }
        // The pinned text, compared by its bytes, as Kotlin compares it (ADR 2026-09.jc2x).
        guard scanned == nodeId, let pinned = session.directory.peers[nodeId]?.publicKey, code.bundle.utf8.elementsEqual(pinned.utf8)
        else {
            return .mismatch
        }
        await session.setVerified(nodeId, true)
        return .match
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
            isVerified: peer?.verified ?? false,
            ownCode: VerifyPayload.encode(session.identity.bundle),
            face: directory.face(for: nodeId),
            isBlocked: directory.blocked.contains(nodeId)
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
