public import KnitStore
public import KnitWire

/// Something the mesh did that the app should know about.
public enum MeshEvent: Sendable, Equatable {
    /// A message reached us for the first time. `isRequest` when it came in a DM or group the user has not accepted:
    /// it is stored, and not notified.
    case received(MessageRecord, isRequest: Bool)
    /// A receipt came back for one of our messages: ✓✓.
    case delivered(messageId: String)
    /// One of our messages that waited for a key was sealed and sent: ✓.
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
    /// Unsigned, and not one of the two unsigned shapes, or one this build cannot open.
    case unsigned
    /// The payload does not decode.
    case undecodable
    /// A sealed DM this build could not open: not addressed to us, a bad tag, or v2 and v3, which need the ratchet.
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
}
