import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// knit-next's custody contract (`vectors/custody-v1.json`, knit-next ADR 2026-10.7mqm), replayed as `CustodyVectorTest`
/// replays it through Android's store: every step in order through one store of each kind. A step this port answers
/// differently is a frame an iPhone and a Pixel hold differently, so their digests never agree.
@Suite struct CustodyVectorTests {
    private static let file = CustodyVectors.file

    /// The file's limits in this port's names.
    private static var limits: CustodyLimits {
        let stated = file.limits
        return CustodyLimits(
            ttlMilliseconds: stated.ttlMs,
            roomChatTTLMilliseconds: stated.broadcastTtlMs,
            maxFrames: stated.maxRows,
            maxPerSender: stated.maxPerSender,
            maxPerGroup: stated.maxPerGroup,
            maxRoomChat: stated.maxBroadcast
        )
    }

    /// The step's frame as `CustodyVectorTest.frameOf` builds it: an empty chat, unsigned, its group's founder the first
    /// member.
    private static func carried(_ frame: CustodyVectors.Frame) -> CarriedFrame {
        let group = frame.group.map { roster in
            GroupInfo(id: roster.id, members: roster.members, createdBy: roster.members.first ?? "", departed: roster.departed)
        }
        let envelope = RelayEnvelope(
            type: FrameType(rawValue: frame.type),
            id: frame.id,
            senderId: frame.senderId,
            sentAt: frame.sentAt,
            recipientId: frame.recipientId,
            group: group,
            payload: ChatContent(body: "").encoded
        )
        return CarriedFrame(envelope: envelope, sig: [], signed: envelope.encoded)
    }

    @Test func theFileStatesTheSameFutureWindow() {
        #expect(Self.file.limits.maxFutureSkewMs == WireProtocol.maxFutureSkewMilliseconds)
        #expect(Self.file.steps.count == 27)
    }

    @Test(arguments: CustodyStoreKind.allCases)
    func everyStepIsReproduced(kind: CustodyStoreKind) throws {
        let store = try kind.make(Self.limits)
        for (index, step) in Self.file.steps.enumerated() {
            let label = Comment(rawValue: "step \(index + 1) (\(step.note))")
            let frame = Self.carried(step.frame)
            #expect(frame.envelope.isRoomPost == step.isRoomChat, label)
            #expect(CustodyRules.expiresAt(of: frame.envelope, limits: Self.limits) == step.expiresAt, label)
            let before = store.liveIds(now: step.now)
            let answer = store.store(frame, origin: .relayed, now: step.now)
            let after = store.liveIds(now: step.now)
            let afterKeys = Set(after.map(ExactKey.init))
            #expect(answer.held == step.kept, label)
            let evicted = before.filter { !afterKeys.contains(ExactKey($0)) }
            #expect(Self.sorted(evicted) == step.evicted, label)
            #expect(Self.sorted(after) == step.held, label)
        }
    }

    /// Sorted by the ids' bytes, as the file's lists are (Kotlin's `sorted()` on ASCII ids).
    private static func sorted(_ ids: [String]) -> [String] {
        ids.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
}
