public import KnitStore

/// How far one of our messages got (`DeliveryStatus.kt` in knit-next): a message we received has none.
public enum DeliveryStatus: Sendable, Equatable {
    /// A DM waiting for its recipient's key: stored, not yet sealed or sent.
    case waitingForKey
    /// Sent, with no receipt back yet.
    case sent
    /// A receipt came back: for a DM its recipient has it, for a room post someone does (✓✓).
    case delivered

    /// The status a stored message of ours implies. A waiting key outranks the tick, which cannot be set yet.
    public init(_ message: MessageRecord) {
        if message.pendingKey {
            self = .waitingForKey
        } else if message.delivered {
            self = .delivered
        } else {
            self = .sent
        }
    }

    /// The words for the status, which the tick glyph never carries alone.
    public var label: String {
        switch self {
        case .waitingForKey:
            Copy.Delivery.waitingForKey
        case .sent:
            Copy.Delivery.sent
        case .delivered:
            Copy.Delivery.delivered
        }
    }
}
