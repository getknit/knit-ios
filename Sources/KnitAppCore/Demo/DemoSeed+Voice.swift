import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire

// A line's voice note, apart from `DemoSeed.swift` only to keep that enum under the lint's length.
extension DemoSeed {
    /// What a line carrying `voice` carries: the demo's clip, kept in the blob store, or a note whose bytes nobody keeps,
    /// on its way or owed (knit-next ADR 034). Without the clip, as on Linux, a held note carries nothing.
    static func note(
        _ voice: DemoCast.Voice, of line: DemoCast.Line, clip: [UInt8]?, in stores: MeshStores, at now: Int64
    ) -> MessageAttachment? {
        switch voice {
        case .held:
            clip.map { clip in
                let hash = BlobHash(of: clip)
                stores.blobs.insert(clip, hash: hash, mime: VoiceAudio.mime, storedAt: now)
                return MessageAttachment(hash: hash, mime: VoiceAudio.mime)
            }
        case .owed:
            MessageAttachment(hash: arrivingHash(of: line.id), mime: VoiceAudio.mime)
        }
    }
}
