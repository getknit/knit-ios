import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// knit-next's custody contract (`vectors/custody-v1.json`, knit-next ADR 2026-10.7mqm and 2026-10.mqzv), replayed as
/// `CustodyVectorTest` replays it through Android's store: every step in order through one store of each kind. A step
/// this port answers differently is a frame an iPhone and a Pixel hold differently, so their digests never agree. A step's
/// `carry` feeds the rig's holders, which the global cap's spread key reads (the `custody-carry-policy` contract, §5); a
/// file without any replays with every spread 0, the order before it.
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
            maxRoomChat: stated.maxBroadcast,
            maxSignedBytes: stated.maxSignedBytes,
            maxProfileSignedBytes: stated.maxProfileSignedBytes,
            spreadMax: stated.spreadMax ?? CustodyLimits().spreadMax
        )
    }

    /// The rig's carry (the `custody-carry-policy` contract, "Vectors"): each id's holders as the steps set them, its spread
    /// their distinct count, which the rule caps at `spreadMax`.
    private final class RigCarry: CustodyCarry {
        var holders: [ExactKey: Set<ExactKey>] = [:]

        func holders(of id: String) -> Int {
            holders[ExactKey(id)]?.count ?? 0
        }

        /// Applies a step's `carry`, before its frame is stored.
        func apply(_ carry: CustodyVectors.Carry?) {
            for (id, peers) in carry?.holders ?? [:] {
                holders[ExactKey(id)] = peers.isEmpty ? nil : Set(peers.map(ExactKey.init))
            }
        }

        /// Forgets the holders of `ids`, which the step evicted or refused: they die with their row.
        func forget(_ ids: [String]) {
            for id in ids {
                holders[ExactKey(id)] = nil
            }
        }
    }

    /// The step's frame as `CustodyVectorTest.frameOf` builds it: of its type, a chat payload whose body is `bodyLength` "x"s
    /// (empty when absent), a profile's too, since custody never decodes one, unsigned, its group's founder the first member.
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
            payload: ChatContent(body: String(repeating: "x", count: frame.bodyLength ?? 0)).encoded
        )
        return CarriedFrame(envelope: envelope, sig: [], signed: envelope.encoded)
    }

    @Test func theFileStatesTheSameFutureWindow() {
        #expect(Self.file.limits.maxFutureSkewMs == WireProtocol.maxFutureSkewMilliseconds)
        #expect(Self.file.steps.count == 46)
    }

    @Test(arguments: CustodyStoreKind.allCases)
    func everyStepIsReproduced(kind: CustodyStoreKind) throws {
        let store = try kind.make(Self.limits)
        let carry = RigCarry()
        for (index, step) in Self.file.steps.enumerated() {
            let label = Comment(rawValue: "step \(index + 1) (\(step.note))")
            let frame = Self.carried(step.frame)
            // First, so a builder that encodes differently fails as that and not as a custody disagreement.
            try #require(frame.signed.count == step.signedBytes, label)
            #expect(frame.envelope.isRoomPost == step.isRoomChat, label)
            #expect(CustodyRules.expiresAt(of: frame.envelope, limits: Self.limits) == step.expiresAt, label)
            let before = store.liveIds(now: step.now)
            carry.apply(step.carry)
            let answer = store.store(frame, origin: .relayed, now: step.now, carry: carry)
            let after = store.liveIds(now: step.now)
            let afterKeys = Set(after.map(ExactKey.init))
            #expect(answer.held == step.kept, label)
            let evicted = before.filter { !afterKeys.contains(ExactKey($0)) }
            #expect(Self.sorted(evicted) == step.evicted, label)
            #expect(Self.sorted(after) == step.held, label)
            carry.forget(evicted + (answer.held ? [] : [step.frame.id]))
        }
    }

    /// Sorted by the ids' bytes, as the file's lists are (Kotlin's `sorted()` on ASCII ids).
    private static func sorted(_ ids: [String]) -> [String] {
        ids.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
}
