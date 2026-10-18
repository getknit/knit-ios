import KnitTestSupport
import Testing

@testable import KnitMesh

/// knit-next's seven group transcripts (`ratchet-v1.json`'s `group`, companion change A9's stage 4) replayed whole through
/// both session layers over both store kinds (``GroupTranscriptReplay``): every party in every role the file gives it,
/// Alice, Bob and Carol sending, receiving, asking and answering; every seal byte for byte from its listed draws, the seed
/// DMs, acks, requests and resets included; every open's outcome, plaintext, verdicts and acks; and after every step the
/// actor's DM state and group state as the file digests them. `RatchetGroupTranscriptTests` in KnitCrypto replays the
/// group steps at the engine alone.
@Suite struct RatchetGroupVectorTests {
    static let file = RatchetVectors.file
    static let names = file.group.map(\.name)

    @Test(arguments: names, GroupSessionKind.allCases)
    func groupTranscriptReplaysThroughBothSessionLayers(_ name: String, kind: GroupSessionKind) throws {
        var replay = try GroupTranscriptReplay(try #require(Self.file.group.first { $0.name == name }), kind: kind)
        try replay.run()
    }
}
