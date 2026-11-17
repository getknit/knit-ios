public import KnitWire

/// One relay's WebSocket as ``Mesh`` drives it (ADR 2026-11.adrq, P4b1): a test adapter over a fake spool now, and a later
/// phase's `URLSessionWebSocketTask` adapter.
///
/// **Reads are pulled.** The mesh's reader calls ``receive()`` only once its previous post into ``Mesh`` returned, so at
/// most one inbound record is in flight per connection and no unbounded stream sits between the socket and the plane. A
/// conformer refuses a message past ``SpoolRecordLayer/maxInboundRecord`` before buffering it, and answers a close with
/// ``SpoolSocketMessage/closed(_:)``; every later call answers the same.
///
/// **Sends** come one at a time: ``send(_:)`` is never called again before the last one returned. It answers whether the
/// write went; `false` ends the session as a close.
///
/// **Failures** are words of this port's own and a clamped close code: never `any Error`, never Foundation's or a relay's
/// text. A close frame's reason is dropped. A conformer's description names no URL, and its mirror has no children.
public protocol SpoolSocket: AnyObject, Sendable {
    /// The next message, or the close once the socket is gone.
    func receive() async -> SpoolSocketMessage

    /// Writes one record as one binary message. Answers whether it went.
    func send(_ bytes: [UInt8]) async -> Bool

    /// Closes the socket with `code`. A later ``receive()`` answers the close.
    func close(code: Int)
}

/// What opens a relay's socket: the one reader of ``AcceptedSpoolURL/socketURLText`` in the plane.
public protocol SpoolSocketFactory: Sendable {
    /// Opens a socket to `url`, or says why not.
    func open(_ url: AcceptedSpoolURL) async -> SpoolDial
}

/// A dial's outcome.
public enum SpoolDial: Sendable {
    /// The upgrade finished.
    case opened(any SpoolSocket)
    /// It did not.
    case failed(SpoolDialFailure)
}

/// One message off a socket.
public enum SpoolSocketMessage: Sendable, Equatable, CustomStringConvertible {
    /// A binary message: one record.
    case binary([UInt8])
    /// A text message, which a spool never sends: dropped and counted, by its size alone.
    case text(byteCount: Int)
    /// The socket is gone.
    case closed(SpoolSocketEnd)

    public var description: String {
        switch self {
        case .binary(let bytes):
            "binary(\(bytes.count) bytes)"
        case .text(let count):
            "text(\(count) bytes)"
        case .closed(let end):
            "closed(\(end))"
        }
    }
}

/// Why a socket or a dial ended, in this port's words.
public enum SpoolSocketFault: String, Sendable {
    /// The spool closed the socket.
    case closed = "closed"
    /// The route failed: no answer, a refused connection, a reset.
    case unreachable = "unreachable"
    /// The TLS handshake or the certificate failed.
    case tls = "tls"
    /// The upgrade was answered with another HTTP status.
    case http = "http"
    /// A message past the record cap, or a frame the socket could not read.
    case protocolError = "protocol"
    /// The socket was cancelled from this side.
    case cancelled = "cancelled"
}

/// How a socket ended: a fault word and the close code, if one came, held to 1000…4999.
public struct SpoolSocketEnd: Sendable, Equatable, CustomStringConvertible {
    /// The fault word.
    public let fault: SpoolSocketFault
    /// The close code, clamped.
    public let code: Int?

    /// An end for `fault`, carrying `code` held to the close codes' range.
    public init(_ fault: SpoolSocketFault, code: Int? = nil) {
        self.fault = fault
        self.code = code.map { min(max($0, SpoolCloseCode.normal), Self.maxCode) }
    }

    /// The highest close code an application may send.
    public static let maxCode = 4999

    public var description: String { code.map { "\(fault.rawValue) \($0)" } ?? fault.rawValue }
}

/// Why a dial did not open: a fault word, the HTTP status held to 100…599 when one came, and `Retry-After` as the
/// raw bytes the server sent, cut to ``SpoolRetryAfter/keptBytes``.
public struct SpoolDialFailure: Sendable, Equatable, CustomStringConvertible {
    public let fault: SpoolSocketFault
    public let status: Int?
    public let retryAfter: SpoolRetryAfter?

    /// A failure for `fault`, with the status clamped.
    public init(_ fault: SpoolSocketFault, status: Int? = nil, retryAfter: SpoolRetryAfter? = nil) {
        self.fault = fault
        self.status = status.map { min(max($0, Self.statusRange.lowerBound), Self.statusRange.upperBound) }
        self.retryAfter = retryAfter
    }

    private static let statusRange = 100...599

    public var description: String { status.map { "\(fault.rawValue) \($0)" } ?? fault.rawValue }
}
