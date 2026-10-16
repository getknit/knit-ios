public import KnitStore
public import KnitWire

/// Something the mesh did that the app should know about.
public enum MeshEvent: Sendable, Equatable {
    /// A message reached us for the first time. `isRequest` when it came in a DM or group the user has not accepted:
    /// it is stored, and not notified.
    case received(MessageRecord, isRequest: Bool)
    /// A receipt came back for one of our messages: ✓✓.
    case delivered(messageId: String)
    /// One of our messages that waited was sealed and sent: ✓. It waited for a key, or, with the ratchet's switch on, for
    /// the store unit its ratchet seal commits in (phase P5b).
    case sent(messageId: String)
    /// Someone's reaction to a message we hold was added, replaced or taken back (ADR 2026-10.ehe6). Our own reactions
    /// are not announced: whoever made one already has the answer.
    case reacted(ReactionRecord)
    /// A group changed: we made, renamed or left it, or a frame changed its roster, its name or its status lines.
    case groupChanged(String)
    /// A peer's profile pinned or changed.
    case peerUpdated(NodeId)
    /// The bytes of a photo a message carries landed, so the message can show it.
    case attachmentArrived(BlobHash)
    /// The live links changed.
    case neighborsChanged([Neighbor])
    /// Who is typing where changed: each thread someone is typing in, with their node ids in order. The whole picture
    /// each time; an empty one when nobody is (``MeshEngine/handleTyping(_:)``).
    case typing([String: [NodeId]])
    /// The radio's state changed: Bluetooth switched on or off, allowed or refused.
    case radioChanged(RadioState)
}

/// Why the engine dropped a frame locally (`DropReason` in knit-next's `MeshMetrics.kt`). A dropped frame is
/// still relayed: a relay that drops what it cannot read is a black hole.
public enum DropReason: Sendable, Hashable, CaseIterable {
    /// No key to verify it: the sender's profile has not pinned. Its key is requested and the frame parked.
    case noSenderKey
    /// The verifying key does not derive to the claimed sender.
    case keyMismatch
    /// The signature does not verify.
    case badSignature
    /// Unsigned, and not one of the two unsigned shapes, or a v3 live-link tick that opened as anything but a receipt
    /// (`UNSIGNED_REFUSED`, `InboundPipeline.kt:664-667`, `:938-941`, `:1761-1768`). With the ratchet's switch off, the
    /// tick is refused here too.
    case unsigned
    /// The payload does not decode.
    case undecodable
    /// A sealed DM this build could not open: not addressed to us or a bad tag, v2 and v3 while the ratchet's switch is
    /// off, a ratchet frame whose init X25519 refused, or a plaintext that opened and will not decode or is newer than
    /// this build reads (`DECRYPT_FAILED` and `UNKNOWN_CONTENT_VERSION`). None of it counts toward a session reset.
    case cannotOpen
    /// A DM with no encryption. Android never sends one, so it is not shown as one.
    case cleartextDirect
    /// A group message with no encryption. Android never sends one either.
    case cleartextGroup
    /// A group frame naming us whose roster fails the pin, the id's hash or the sender rules
    /// (`GROUP_ROSTER_REFUSED`).
    case rosterRefused
    /// A profile trying to change a pinned key.
    case pinChangeRefused
    /// A message, a roster change or a departure from someone the user blocked (ADR 2026-10.5wgg). It is still carried
    /// and relayed; only its delivery stops here.
    case blocked
    /// A reaction that is not one emoji of at most 32 UTF-16 units (`REACTION_REFUSED`, ADR 2026-10.ehe6). Android
    /// refuses only the length; this port refuses words too.
    case reactionRefused
    /// A DM ratchet frame we hold no session for, with no init to start one (`RATCHET_NO_SESSION`): the peer holds
    /// state we lost. From a signed frame, at its first verdict, it counts toward a session reset (ADR 2026-10.5sk9).
    case ratchetNoSession
    /// A DM ratchet frame naming one of our epochs or prekeys we no longer hold, or never did (`RATCHET_EPOCH_GONE`).
    /// From a signed frame, at its first verdict, it counts toward a session reset.
    case ratchetEpochGone
    /// A DM ratchet frame whose key is already spent: our own delivered history coming back (`RATCHET_DUPLICATE`). It
    /// never counts toward a reset (knit-next ADR 024).
    case ratchetDuplicate
    /// A DM ratchet frame malformed before or inside the engine (`RATCHET_BAD_HEADER`): no header, the DM form addressed
    /// to a group, a nonce of the wrong shape for its version, or a header out of bounds. It never counts toward a reset.
    case ratchetBadHeader
    /// A DM ratchet frame whose keys resolved and whose tag refused (`RATCHET_AEAD_FAIL`): the pair's roots disagree.
    /// From a signed frame, at its first verdict, it counts toward a session reset.
    case ratchetAeadFail
    /// A store failed inside the unit a ratchet frame's open commits in: nothing was delivered or acknowledged, and the
    /// copy that failed is opened again at the next sweep (ADR 2026-10.5sk9).
    case storeRefused
}
