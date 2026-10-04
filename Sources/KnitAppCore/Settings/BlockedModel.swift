import Foundation
public import KnitWire
public import Observation

/// One person the user blocked, as Settings' list shows them.
public struct BlockedRow: Sendable, Equatable, Identifiable {
    /// The person.
    public var id: NodeId
    /// Their label: their name, or their alias while their profile has not pinned.
    public var title: String
    /// Their face.
    public var face: Face
}

/// The blocked people's view model (`BlockedUsersViewModel` in knit-next, ADR 2026-10.5wgg): everyone blocked, by name,
/// each with Unblock.
@preconcurrency
@MainActor
@Observable
public final class BlockedModel {
    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private var cache = Cached<Int, [BlockedRow]>()

    /// The blocked people over `session`.
    public init(session: AppSession) {
        self.session = session
    }

    /// Everyone blocked, by name, a tie going by node id.
    public var rows: [BlockedRow] {
        cache.value(for: session.revision) {
            let directory = session.directory
            let found = directory.blocked.map { peer in
                BlockedRow(id: peer, title: directory.label(for: peer).text, face: directory.face(for: peer))
            }
            return found.sorted { first, second in
                let byName = first.title.localizedCaseInsensitiveCompare(second.title)
                return byName == .orderedSame ? first.id < second.id : byName == .orderedAscending
            }
        }
    }

    /// Unblocks `peer`: they leave the list, and what they wrote before the block shows again.
    public func unblock(_ peer: NodeId) async {
        await session.unblock(peer)
    }
}
