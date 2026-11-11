public import KnitCrypto
public import KnitStore
public import KnitWire

/// Our current presence key as the presence key pass published it (`OwnPresenceKey`, `mesh/OwnPresenceKey.kt` at knit-next
/// `cad69c77b`; ADR 2026-11.prsp): the one key the radio may derive our advert's tags from. Two are equal exactly when they
/// name the same generation with the same bytes, so a pass that publishes an unchanged key is no change; nothing else about
/// the row (its mark, its audience) takes part.
///
/// Never logged: its description shows the generation alone.
public struct OwnPresenceKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Our generation for it.
    public let generation: Int64
    /// The key.
    public let key: PresenceKey

    /// The key at `generation`.
    public init(generation: Int64, key: PresenceKey) {
        self.generation = generation
        self.key = key
    }

    /// The generation only (`OwnPresenceKey.toString`).
    public var description: String { "OwnPresenceKey(g=\(generation))" }

    /// As ``description``.
    public var debugDescription: String { description }

    /// The generation only, so reflection shows no key.
    public var customMirror: Mirror { Mirror(self, children: ["generation": generation], displayStyle: .struct) }
}

/// What the radio reads of our presence keys, handed to it once (``MeshTransport/attachPresenceKeys(_:)``; ADR 2026-11.prsp):
/// the seams the advert's writer stands on (Phase 2). Each reads or asks the engine on the `Mesh` actor, synchronously, the
/// way the link manager runs: no value here is a copy that could lag the engine's.
public struct PresenceKeySource {
    /// Our current key now, or `nil`: before each session's first committed pass, after a pass that could not settle, and
    /// from a block until the next pass mints the fresh pair (`MeshTransport.onOwnPresenceKeySource`). Read it where a tag
    /// is about to air.
    public let ownKey: () -> OwnPresenceKey?
    /// Whether a linked peer may be sent our next tag (`MeshManager.hearsTagNext`): neither blocked nor departed, and `false`
    /// until this session's pass has read both.
    public let hearsTagNext: (NodeId) -> Bool
    /// Asks for one pass of our keys, at most once per generation, as the advertiser does when its mark moves past the
    /// contact window's lead (`reconcile("mark")`).
    public let askMarkPass: (_ generation: Int64) -> Void
    /// The advertiser's mark under our key `generation`, or `nil` with none; throws when the store cannot answer, never
    /// "none" (``KnitStore/PresenceMarkReadFailure``).
    public let readMark: (_ generation: Int64) throws(PresenceMarkReadFailure) -> PresenceMark?
    /// Writes the advertiser's mark under our key `generation`, durably and only while it is the current key: only
    /// ``KnitStore/PresenceMarkWrite/durable`` lets a tag air.
    public let writeMark: (_ mark: PresenceMark, _ generation: Int64) -> PresenceMarkWrite

    /// The source over these readers.
    public init(
        ownKey: @escaping () -> OwnPresenceKey?,
        hearsTagNext: @escaping (NodeId) -> Bool,
        askMarkPass: @escaping (Int64) -> Void,
        readMark: @escaping (Int64) throws(PresenceMarkReadFailure) -> PresenceMark?,
        writeMark: @escaping (PresenceMark, Int64) -> PresenceMarkWrite
    ) {
        self.ownKey = ownKey
        self.hearsTagNext = hearsTagNext
        self.askMarkPass = askMarkPass
        self.readMark = readMark
        self.writeMark = writeMark
    }
}
