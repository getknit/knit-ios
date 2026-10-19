import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// The ratchet's receive rules above the engine, on their own (`InboundPipeline.decryptAndDeliverV2`, `admitsUnsigned`,
/// `nonceShapeValid`, `decodePlaintext` and `onRatchetFailure`), and the replay's ids.
@Suite struct RatchetInboundTests {
    private let header = RatchetHeader(se: 1, ek: [UInt8](repeating: 9, count: 32), pe: 1, n: 0)

    private func envelope(_ version: Int, nonce: [UInt8], ratchet: Bool = true, group: Bool = false) -> EncEnvelope {
        EncEnvelope(
            version: version,
            nonce: nonce,
            ct: [1, 2, 3],
            keys: [],
            ratchet: ratchet ? header : nil,
            groupRatchet: group ? GroupRatchetHeader(se: 1, n: 0) : nil
        )
    }

    @Test func onlyV2AndV3AreTheDirectForm() {
        #expect(RatchetInbound.isDirectRatchet(envelope(2, nonce: [])))
        #expect(RatchetInbound.isDirectRatchet(envelope(3, nonce: [])))
        #expect(!RatchetInbound.isDirectRatchet(envelope(1, nonce: [])))
        #expect(!RatchetInbound.isDirectRatchet(envelope(4, nonce: [])))
    }

    @Test func theUnsignedDoorAdmitsV3InTheDirectFormAlone() {
        #expect(RatchetInbound.admitsUnsigned(envelope(3, nonce: [])))
        #expect(!RatchetInbound.admitsUnsigned(nil), "a DM in the clear")
        #expect(!RatchetInbound.admitsUnsigned(envelope(2, nonce: [UInt8](repeating: 0, count: 12))))
        #expect(!RatchetInbound.admitsUnsigned(envelope(3, nonce: [], ratchet: false)))
        #expect(!RatchetInbound.admitsUnsigned(envelope(3, nonce: [], group: true)))
    }

    @Test func theNonceMustFitTheVersionBeforeTheEngine() throws {
        let aad = Array("aad".utf8)
        let v2 = try #require(RatchetInbound.frame(envelope(2, nonce: [UInt8](repeating: 7, count: 12)), aad: aad))
        #expect(v2.nonce == [UInt8](repeating: 7, count: 12) && v2.header == header && v2.ct == [1, 2, 3] && v2.aad == aad)
        let v3 = try #require(RatchetInbound.frame(envelope(3, nonce: []), aad: aad))
        #expect(v3.nonce == nil, "v3 is signalled to the engine by no nonce")
        #expect(RatchetInbound.frame(envelope(2, nonce: []), aad: aad) == nil, "never read as v3")
        #expect(RatchetInbound.frame(envelope(2, nonce: [1, 2, 3]), aad: aad) == nil)
        #expect(RatchetInbound.frame(envelope(3, nonce: [UInt8](repeating: 0, count: 12)), aad: aad) == nil)
        #expect(RatchetInbound.frame(envelope(2, nonce: [UInt8](repeating: 7, count: 12), ratchet: false), aad: aad) == nil)
    }

    @Test func thePlaintextIsReadByItsVersion() throws {
        let content = MessageContent(body: "hi")
        #expect(RatchetInbound.content(of: content.encoded, v3: false) == content)
        let compact = try #require(MessageContentV2.encode(content))
        #expect(RatchetInbound.content(of: compact, v3: true) == content)
        #expect(RatchetInbound.content(of: compact, v3: false) == nil, "the compact layout is no named one")
        #expect(RatchetInbound.content(of: [0xFF], v3: false) == nil)
        #expect(RatchetInbound.content(of: MessageContent(version: 2, body: "later").encoded, v3: false) == nil, "a newer version")
    }

    @Test func eachFailureHasItsDropAndOnlySignedEvidenceAtItsFirstVerdictCounts() {
        let expected: [RatchetEngine.OpenOutcome.Failed: DropReason] = [
            .noSession: .ratchetNoSession, .epochGone: .ratchetEpochGone, .duplicate: .ratchetDuplicate,
            .badHeader: .ratchetBadHeader, .aeadFail: .ratchetAeadFail,
        ]
        let live = RatchetInbound.Route(hop: nil, signed: true, origin: .firstVerdict)
        let unsigned = RatchetInbound.Route(hop: nil, signed: false, origin: .firstVerdict)
        let replayed = RatchetInbound.Route(hop: nil, signed: true, origin: .startReplay)
        for (failure, reason) in expected {
            #expect(RatchetInbound.dropReason(for: failure) == reason)
            let counts = [RatchetEngine.OpenOutcome.Failed.noSession, .epochGone, .aeadFail].contains(failure)
            #expect(RatchetInbound.countsTowardReset(failure, route: live) == counts, "\(failure)")
            #expect(!RatchetInbound.countsTowardReset(failure, route: unsigned), "an unsigned frame never counts")
            #expect(!RatchetInbound.countsTowardReset(failure, route: replayed), "nor does the start's replay")
        }
    }

    @Test func aReceiptAcknowledgesEachIdOnceByItsBytesAtMostItsBound() {
        #expect(RatchetInbound.acknowledged(ack: "a", acks: ["b", "a", "c"]) == ["a", "b", "c"])
        #expect(RatchetInbound.acknowledged(ack: nil, acks: nil).isEmpty)
        #expect(RatchetInbound.acknowledged(ack: "K", acks: ["\u{212A}"]) == ["K", "\u{212A}"], "the Kelvin sign is another id")
        let many = (0..<300).map { "id-\($0)" }
        #expect(RatchetInbound.acknowledged(ack: nil, acks: many) == Array(many.prefix(128)))
    }

    /// A frame as the replay keeps it, with `payload` for its bytes.
    private func relay(_ id: String, payload: [UInt8] = []) -> RelayEnvelope {
        RelayEnvelope(type: .chat, id: id, senderId: "sender", sentAt: 1, recipientId: "us", payload: payload)
    }

    @Test func theReplayKeepsTheLaterCopyOfAnIdOldestFirstWithinItsBoundsAndForgetsWhatItHandsBack() {
        var replay = RatchetReplay()
        let live = RatchetInbound.Route(hop: nil, signed: true, origin: .firstVerdict)
        let replayed = RatchetInbound.Route(hop: nil, signed: true, origin: .startReplay)
        replay.keep(relay("b", payload: [1]), route: replayed)
        replay.keep(relay("a"), route: live)
        replay.keep(relay("b", payload: [2]), route: live)
        replay.keep(relay("\u{212A}"), route: live)
        replay.keep(relay("K"), route: live)
        #expect(replay.kept.count == 4)
        let taken = replay.take()
        #expect(taken.map(\.envelope.id) == ["a", "b", "\u{212A}", "K"], "the later copy goes to the back of the line")
        #expect(taken[1] == RatchetReplay.Kept(envelope: relay("b", payload: [2]), route: live), "an id kept twice keeps the later copy")
        #expect(replay.take().isEmpty)

        for index in 0...RatchetReplay.capacity {
            replay.keep(relay("id-\(index)"), route: live)
        }
        let kept = replay.take()
        #expect(kept.count == RatchetReplay.capacity && kept.first?.envelope.id == "id-1", "past the count, the oldest goes first")

        let third = [UInt8](repeating: 0, count: RatchetReplay.maxBytes / 3)
        for index in 0..<4 {
            replay.keep(relay("big-\(index)", payload: third), route: live)
        }
        #expect(replay.take().map(\.envelope.id) == ["big-1", "big-2", "big-3"], "past the bytes, the oldest goes first")
    }

    @Test func theReplayKeepsASignedCopyAgainstAnUnsignedOneAndLetsACommittedIdGo() {
        var replay = RatchetReplay()
        let signed = RatchetInbound.Route(hop: nil, signed: true, origin: .firstVerdict)
        let unsigned = RatchetInbound.Route(hop: nil, signed: false, origin: .firstVerdict)
        replay.keep(relay("d", payload: [1]), route: signed)
        replay.keep(relay("d", payload: [2]), route: unsigned)
        replay.keep(relay("t", payload: [3]), route: unsigned)
        replay.keep(relay("t", payload: [4]), route: signed)
        replay.keep(relay("gone"), route: signed)
        replay.forget("gone")
        replay.forget("never kept")
        let taken = replay.take()
        #expect(taken.map(\.envelope.payload) == [[1], [4]], "a stripped copy never displaces the signed one; a signed one does")
        #expect(taken.map(\.route.signed) == [true, true])
    }
}
