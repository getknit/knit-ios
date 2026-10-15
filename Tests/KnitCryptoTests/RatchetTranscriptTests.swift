import KnitTestSupport
import Testing

@testable import KnitCrypto

/// knit-next's DM transcripts (`ratchet-v1.json`, companion change A9: stage 3a's `dm` and `negative`, 3b's races and
/// control plane, and stage 5's `carol`), replayed at the engine (``TranscriptReplay``). Each party gets its listed
/// identity, prekeys and pin, and an engine fed its listed draws in order, each used exactly once. A seal must give the
/// listed header, nonce, ciphertext and envelope byte for byte; an open the listed outcome and plaintext; and after every
/// step the actor's state must digest to the listed one. The steps model `RatchetSessions` (peek, then commit) over a
/// store with `RatchetRepository`'s rules, which ``RatchetRows`` plays. Signatures are not compared, and the signed
/// `wire` is not read: the engine seals no frame of its own.
///
/// What needs more than the engine is left to the layer that has it, by name (``deferred`` and ``aboveTheEngine``): a
/// reset's plan is `RatchetSessions`', which ``RatchetTranscriptSessionTests`` replays, and the exists-gate and the
/// pipeline's own refusals are `InboundPipeline`'s (P5).
@Suite struct RatchetTranscriptTests {
    static let file = RatchetVectors.file

    /// The transcripts left to another layer, with the step that needs it.
    static let deferred: [String: String] = [
        "reRootReset": "a reset step: RatchetSessions.sealResetDm's re-root, which RatchetTranscriptSessionTests replays",
        "confirmEra": "a reset step: RatchetSessions.sealResetDm's re-root, which RatchetTranscriptSessionTests replays",
        "resetPlans": "reset steps: RatchetSessions.sealResetDm's Mark and Decline, which RatchetTranscriptSessionTests replays",
        "resealNewFirst": "a reset step, and a skip at InboundPipeline's exists-gate (P5)",
        "resealOldFirst": "a reset step, and a skip at InboundPipeline's exists-gate (P5)",
    ]

    /// What this phase does with a frame `InboundPipeline` refuses before or around the engine.
    enum AboveTheEngine: Sendable {
        /// The pipeline refuses it first, and this phase calls nothing: P5's.
        case notCalled(String)
        /// Kotlin's engine throws, and the pipeline drops it as `DECRYPT_FAILED`; ours must throw too.
        case throwsOut(String)
        /// The engine refuses it with this typed failure, as the pipeline would before it.
        case refuses(RatchetEngine.OpenOutcome.Failed, String)
    }

    /// The pipeline-layer opens in the replayed transcripts, by transcript and step. None commits anything, which the
    /// replay checks against the listed state.
    static let aboveTheEngine: [String: [Int: AboveTheEngine]] = [
        "ctlPlane": [19: .notCalled("an unsigned plain DM: the pipeline's unsigned door refuses it before commit (P5)")],
        "initEphLowOrder": [2: .throwsOut("a low-order init.eph: X25519 refuses it inside the X3DH respond")],
        "v3NonEmptyNonce": [2: .notCalled("a v3 envelope's nonce is empty: InboundPipeline.nonceShapeValid (P5)")],
        "v2EmptyNonce": [2: .refuses(.badHeader, "a v2 nonce is 12 bytes: the engine refuses it as nonceShapeValid does")],
        "v3ToGroup": [2: .notCalled("a DM form addressed to a group: InboundPipeline.decryptAndDeliverV2 (P5)")],
    ]

    static let dmNames = file.dm.map(\.name).filter { deferred[$0] == nil }
    static let negativeNames = file.negative.map(\.name)
    static let carolNames = file.carol.map(\.name)

    @Test(arguments: dmNames) func dmTranscriptReplaysAtTheEngine(_ name: String) throws {
        try replay(#require(Self.file.dm.first { $0.name == name }))
    }

    @Test(arguments: negativeNames) func negativeTranscriptRefusesAtTheEngine(_ name: String) throws {
        try replay(#require(Self.file.negative.first { $0.name == name }))
    }

    /// Carol is the iPhone. Every opener here is v3, as Android seals the init-bearing opener to a v3 reader, so the
    /// responder's X3DH, the race and the #83 remnant all run on v3 frames, and her seals come out byte for byte.
    @Test(arguments: carolNames) func carolTranscriptReplaysAtTheEngine(_ name: String) throws {
        try replay(#require(Self.file.carol.first { $0.name == name }))
    }

    /// Every transcript is replayed or left to a named phase, and every pipeline-layer open a replayed one holds is
    /// listed, so a transcript a later sync adds fails here until someone decides which.
    @Test func everyTranscriptIsReplayedOrLeftToANamedPhase() {
        let dm = Set(Self.file.dm.map(\.name))
        #expect(Set(Self.deferred.keys).isSubset(of: dm))
        #expect(dm.count == 15)
        #expect(Self.negativeNames.count == 18)
        #expect(Self.carolNames.count == 8)
        let replayed = Self.file.dm.filter { Self.deferred[$0.name] == nil } + Self.file.negative + Self.file.carol
        for transcript in replayed {
            let steps = Set(transcript.steps.filter { $0.op == "open" && $0.layer == "pipeline" }.map(\.step))
            #expect(steps == Set((Self.aboveTheEngine[transcript.name] ?? [:]).keys), "\(transcript.name)")
            #expect(transcript.steps.allSatisfy { ["seal", "open", "advance"].contains($0.op) }, "\(transcript.name)")
        }
    }

    private func replay(_ transcript: RatchetVectors.Transcript) throws {
        var replay = try TranscriptReplay(transcript, file: Self.file, aboveTheEngine: Self.aboveTheEngine[transcript.name] ?? [:])
        try replay.run()
    }
}
