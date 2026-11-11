import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// The persisted marks a test's schedules share, as the store is shared across restarts: answers what a test sets, and moves
/// a mark only forward, as both stores do.
final class FakeMarks: TagMarks {
    var marks: [Int64: PresenceMark] = [:]
    var reads = 0
    /// What every write answers; only ``KnitStore/PresenceMarkWrite/durable`` writes.
    var answer = PresenceMarkWrite.durable
    /// Whether a read fails.
    var failingReads = false

    func read(_ generation: Int64) throws(PresenceMarkReadFailure) -> PresenceMark? {
        reads += 1
        guard !failingReads else {
            throw PresenceMarkReadFailure()
        }
        return marks[generation]
    }

    func write(_ mark: PresenceMark, _ generation: Int64) -> PresenceMarkWrite {
        guard answer == .durable else {
            return answer
        }
        guard PresenceMark.moves(marks[generation], to: mark) else {
            return .refused
        }
        marks[generation] = mark
        return .durable
    }
}

/// The engine's readers of our presence keys (``PresenceKeySource``), as a test sets them: our key, the marks, who may not
/// hear our tag, and the passes asked.
final class FakeKeys {
    var key: OwnPresenceKey?
    let marks = FakeMarks()
    /// Peers blocked or departed: ``PresenceKeySource/hearsTagNext`` answers no for them.
    var deaf: Set<NodeId> = []
    var markPasses: [Int64] = []
    /// Marks written, durable or not.
    var writes = 0

    init(_ key: OwnPresenceKey? = FakeKeys.key(1)) {
        self.key = key
    }

    static func key(_ generation: Int64, byte: UInt8 = 0x11) -> OwnPresenceKey {
        OwnPresenceKey(generation: generation, key: required(PresenceKey(bytes: [UInt8](repeating: byte, count: PresenceKey.byteCount))))
    }

    var source: PresenceKeySource {
        PresenceKeySource(
            ownKey: { self.key },
            hearsTagNext: { !self.deaf.contains($0) },
            askMarkPass: { self.markPasses.append($0) },
            readMark: { generation throws(PresenceMarkReadFailure) in try self.marks.read(generation) },
            writeMark: { mark, generation in
                self.writes += 1
                return self.marks.write(mark, generation)
            }
        )
    }
}
