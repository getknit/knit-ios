import KnitMesh
import KnitTestSupport
import Testing

@testable import KnitCrypto

/// knit-next's DM transcripts that need the session layer (`ratchet-v1.json`, companion change A9's stage 3b), replayed
/// through ``RatchetSessions`` (``SessionReplay``): the races, whose loser starts its replacement floor and whose winner
/// confirms on the loser's answer; the late loser's opening read and never anchored (#83); the reset that re-roots, drains
/// the old era under `prevRoot` and keys two eras' epoch 2 apart (#135); the era gate on a drained frame (#87); and the
/// reset plans, Mark, the two declines and the re-root at exactly a minute (knit-next ADR 2026-09.qerd). Each step's
/// outcome, its floors held in memory, the rule that decided a plan, and the state after it must be the file's.
///
/// What needs more than the session layer is left to P5, by name: the control plane's pipeline replay and the re-seals,
/// whose second copy is skipped at the pipeline's exists-gate. The rest of `dm` is the engine's alone, which
/// ``RatchetTranscriptTests`` replays.
@Suite struct RatchetTranscriptSessionTests {
    static let file = RatchetVectors.file

    /// The transcripts replayed here.
    static let replayed = [
        "raceWinnerArrivesFirst", "raceLoserArrivesFirst", "lateLoserOpening", "reRootReset", "confirmEra", "resetPlans",
    ]

    /// The session-layer transcripts left to P5, with the step that needs it.
    static let pipelineLayer: [String: String] = [
        "ctlPlane": "InboundPipeline's control plane, inline acks and unsigned door, replayed through the pipeline (P5)",
        "resealNewFirst": "the re-seal's second copy is skipped at InboundPipeline's exists-gate (P5)",
        "resealOldFirst": "the re-seal's second copy is skipped at InboundPipeline's exists-gate (P5)",
    ]

    @Test(arguments: replayed) func transcriptReplaysThroughTheSessionLayer(_ name: String) throws {
        var replay = try SessionReplay(try #require(Self.file.dm.first { $0.name == name }), file: Self.file)
        try replay.run()
    }

    /// Every transcript that states the session layer's floors is replayed here or left to P5 by name, and every rule a
    /// reset step names is one the session layer knows, so a transcript a later sync adds fails here until someone
    /// decides which.
    @Test func everySessionLayerTranscriptIsReplayedOrLeftToANamedPhase() {
        let sessionLayer = Set(Self.file.dm.filter { $0.steps.contains { $0.floorsBefore != nil } }.map(\.name))
        #expect(sessionLayer == Set(Self.replayed).union(Self.pipelineLayer.keys))
        for transcript in Self.file.dm where Self.replayed.contains(transcript.name) {
            #expect(transcript.steps.allSatisfy { ["seal", "open", "reset"].contains($0.op) }, "\(transcript.name)")
        }
        let named = Self.file.dm.flatMap(\.steps).compactMap(\.decidedBy)
        #expect(!named.isEmpty)
        for rule in named {
            #expect(SessionReplay.decidedBy[rule] != nil, "a rule the session layer knows: \(rule)")
        }
    }
}
