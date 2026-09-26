public import KnitStore
public import KnitWire

/// Something the mesh did that the app should know about.
public enum MeshEvent: Sendable, Equatable {
    /// A message reached us for the first time. `isRequest` when it came in a DM the user has not accepted: it is
    /// stored, and not notified.
    case received(MessageRecord, isRequest: Bool)
    /// A receipt came back for one of our messages: ✓✓.
    case delivered(messageId: String)
    /// One of our DMs that waited for its recipient's key was sealed and sent: ✓.
    case sent(messageId: String)
    /// A peer's profile pinned or changed.
    case peerUpdated(NodeId)
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
    /// A profile trying to change a pinned key.
    case pinChangeRefused
}
