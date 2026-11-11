/// What a build that has link previews hands the session (ADR 2026-11.hcvg): a debug build's alone until the maintainer
/// approves them for the store, as voice notes are (``VoiceNotes``). With it, a thread draws the card Android's sender
/// fetched beside the link it describes, and the mesh's signed profile carries `CAP_LINK_PREVIEW`, so an Android phone
/// attaches one to a DM or a group toward this phone. A release build hands none, and behaves as it did before: no
/// card drawn, and `0xC015F` sent.
///
/// It holds nothing yet: being handed one is the switch. The sender's fetch adds its seams here.
public struct LinkPreviews: Sendable {
    /// Link previews, as a debug build has them.
    public init() {
        // Nothing to hold until the sender's fetch lands.
    }
}
