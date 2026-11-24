import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// ``HeardFrom`` alone: which frames are evidence, the stamp a frame gives, and the buffer and bank's memory (knit-next
/// `HeardFromTest` and the fade cases of `PeerRepositoryTest`, ADR 2026-10.k8ge).
@Suite struct HeardFromTests {
    private static let now: Int64 = 1_756_200_000_000
    private static let gate = HeardFrom.gateMilliseconds
    private let alice = fixtureNodeId(1)
    private let bob = fixtureNodeId(2)

    private static func envelope(_ type: FrameType, sentAt: Int64 = now) -> RelayEnvelope {
        RelayEnvelope(type: type, id: "x", senderId: fixtureNodeId(1).string, sentAt: sentAt, payload: [])
    }

    private static let signed = WireEnvelope(sig: [1, 2, 3], signed: [4])
    private static let unsigned = WireEnvelope(relay: false, sig: [], signed: [4])

    @Test func aSignedChatAndAProfileAreEvidence() {
        #expect(HeardFrom.isEvidence(Self.signed, Self.envelope(.chat)))
        #expect(HeardFrom.isEvidence(Self.signed, Self.envelope(.profile)))
        #expect(HeardFrom.isEvidence(Self.signed, Self.envelope(.receipt)))
    }

    @Test func theBlobTrafficAndTheUnsignedTickAreNot() {
        for type in [FrameType.blobRequest, .blobHave, .blobHas, .blobProgress, .blobCancel] {
            #expect(!HeardFrom.isEvidence(Self.signed, Self.envelope(type)), "\(type.rawValue), even with a signature")
            #expect(!HeardFrom.isEvidence(Self.unsigned, Self.envelope(type)), "\(type.rawValue)")
        }
        #expect(!HeardFrom.isEvidence(Self.unsigned, Self.envelope(.chat)), "the v3 tick is unsigned")
    }

    @Test func aReplayKeepsItsStampAndAFutureOneIsCappedAtTheWallClock() {
        let old = Self.now - 3 * 24 * 3_600_000
        #expect(HeardFrom.heardAt(Self.envelope(.chat, sentAt: old), now: Self.now) == old)
        #expect(HeardFrom.heardAt(Self.envelope(.chat, sentAt: Self.now + 60_000), now: Self.now) == Self.now)
    }

    @Test func aStampAtEitherEndOfTheRangeIsClampedWithoutATrap() {
        #expect(HeardFrom.heardAt(Self.envelope(.chat, sentAt: .min), now: Self.now) == 0)
        #expect(HeardFrom.heardAt(Self.envelope(.chat, sentAt: -1), now: Self.now) == 0)
        #expect(HeardFrom.heardAt(Self.envelope(.chat, sentAt: .max), now: Self.now) == Self.now)
    }

    @Test func theBufferKeepsTheNewestStampPerSender() {
        var heard = HeardFrom()
        heard.note(alice, at: 50)
        heard.note(alice, at: 90)
        heard.note(alice, at: 70)
        #expect(heard.heard == [alice: 90])
    }

    @Test func theBufferDropsANewSenderPastItsCapAndStillMergesAHeldOne() {
        var heard = HeardFrom()
        // Distinct ids by their two low bytes: `fixtureNodeId`'s seeds repeat past 256.
        let ids = (0..<HeardFrom.bufferCap).compactMap { index in
            NodeId(bytes: [UInt8(truncatingIfNeeded: index >> 8), UInt8(truncatingIfNeeded: index)] + [UInt8](repeating: 0xEE, count: 14))
        }
        #expect(Set(ids).count == HeardFrom.bufferCap)
        for id in ids {
            heard.note(id, at: 10)
        }
        let first = ids[0]
        heard.note(alice, at: 10)
        heard.note(first, at: 20)
        #expect(heard.heard.count == HeardFrom.bufferCap)
        #expect(heard.heard[alice] == nil, "a new sender past the cap is dropped")
        #expect(heard.heard[first] == 20, "a held one still merges")
    }

    @Test func theFirstBankPrimesOnceAndTakesOnlyWhatIsPastTheGate() {
        var heard = HeardFrom()
        var primed = 0
        let table: [NodeId: Int64] = [alice: 1000, bob: 1000]
        #expect(
            heard.takeDue {
                primed += 1
                return table
            }.isEmpty, "nothing heard: no priming")
        #expect(primed == 0)
        heard.note(alice, at: 1000 + Self.gate)
        heard.note(bob, at: 999 + Self.gate)
        heard.note(fixtureNodeId(3), at: 5)
        let due = heard.takeDue {
            primed += 1
            return table
        }
        #expect(primed == 1)
        #expect(due == [alice: 1000 + Self.gate, fixtureNodeId(3): 5], "at the gate counts; inside it does not; no memory is due")
        #expect(heard.heard.isEmpty, "the bank drained the buffer")
        heard.settle(due, written: true)
        heard.note(alice, at: 1001 + Self.gate)
        #expect(
            heard.takeDue {
                primed += 1
                return table
            }.isEmpty, "the gate counts from what was banked")
        #expect(primed == 1, "primed once")
    }

    @Test func aFailedBankPutsItsStampsBackAndKeepsItsMemory() {
        var heard = HeardFrom()
        heard.note(alice, at: 10 * Self.gate)
        let due = heard.takeDue { [alice: 0] }
        heard.settle(due, written: false)
        #expect(heard.heard == [alice: 10 * Self.gate])
        #expect(heard.banked == [alice: 0])
        #expect(heard.takeDue { [:] } == [alice: 10 * Self.gate], "due again at the next bank")
    }

    @Test func theGateNeverTrapsOnHeldStampsAtEitherEnd() {
        var heard = HeardFrom()
        heard.note(alice, at: .max)
        heard.note(bob, at: 0)
        // A held stamp a database could hold whatever this build wrote: the subtraction overflows both ways.
        let due = heard.takeDue { [alice: .min, bob: .max] }
        #expect(due == [alice: .max], "far newer is due; far older is not")
    }
}
