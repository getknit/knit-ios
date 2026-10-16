import KnitTestSupport
import Testing

@testable import KnitCrypto

/// knit-next's group transcripts (`ratchet-v1.json`'s `group`, companion change A9's stage 4), replayed at the group
/// engine alone (``GroupTranscriptEngineReplay``): every party's group seals byte for byte from its listed draws, every
/// group open's outcome and plaintext, every seed a group-key DM carried adopted with the stated verdict, and after every
/// step the party's send chains, receive chains and skipped keys as the file digests them. `RatchetGroupVectorTests` in
/// KnitMesh replays the same six whole, through both session layers and both store kinds.
@Suite struct RatchetGroupTranscriptTests {
    static let file = RatchetVectors.file
    static let names = file.group.map(\.name)

    @Test(arguments: names) func groupTranscriptReplaysAtTheGroupEngine(_ name: String) throws {
        var replay = try GroupTranscriptEngineReplay(try #require(Self.file.group.first { $0.name == name }))
        try replay.run()
    }

    /// The six A9 holds, each a step kind this replay knows, so a transcript a later sync adds fails here until someone
    /// decides how it replays.
    @Test func everyGroupTranscriptIsOneThisReplayKnows() {
        #expect(Self.names == ["groupSeed", "groupFrames", "groupKeyRequest", "groupRoot", "groupRestoreRemint", "groupRetiredChain"])
        let known: Set = ["seal", "open", "reset", "groupSeal", "groupOpen", "depart", "restore"]
        for transcript in Self.file.group {
            #expect(transcript.steps.allSatisfy { known.contains($0.op) }, "\(transcript.name)")
        }
    }
}
