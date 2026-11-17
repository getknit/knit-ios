import KnitWire

/// A spool's 32-byte scope or blob id (`SPOOL_ID_BYTES`, §12.1), held only once it has that shape: `SpoolConnection.isId`
/// in knit-next, made a type so no set or map in the plane can key on a byte string of any other length.
///
/// Compared by its bytes. Its description is the first four bytes in hex, the most of an id any log line names (Kotlin's
/// `LOG_HASH_CHARS`), so an id interpolated by mistake never puts a whole scope id in a log beside anything else, and
/// `String(reflecting:)` and `dump` see the same prefix and nothing more (P3a's security review).
internal struct SpoolID: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// How many bytes of an id a log line shows.
    static let shownBytes = 4
    private static let hexRadix = 16

    /// The id's 32 bytes.
    let bytes: [UInt8]

    /// The id, or `nil` for bytes that are not 32 long.
    init?(_ bytes: [UInt8]) {
        guard bytes.count == SpoolRecordLayer.idByteCount else {
            return nil
        }
        self.bytes = bytes
    }

    /// The short hex prefix a log line may carry.
    var description: String {
        bytes.prefix(Self.shownBytes).map { byte in
            let hex = String(byte, radix: Self.hexRadix)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }

    var debugDescription: String { description }

    /// No children: a mirror of the bytes would hand `dump` the whole id.
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Text a spool wrote (an error's code or message, an unknown record's `t`), cut and cleaned before it leaves the
/// session (P1's security review): `UnifiedLog` writes `privacy: .public`, and a spool is a hostile server.
///
/// Controls, format characters (the bidi marks and overrides among them) and the line and paragraph separators are
/// dropped, then the rest is cut to ``maxUTF16`` code units (`SPOOL_ERR_CODE_MAX`, which Kotlin applies with `take`)
/// without splitting a surrogate pair. A code is matched by its UTF-8 bytes, never Swift's canonical equivalence (ADR
/// 2026-09.jc2x).
internal struct SpoolText: Hashable, Sendable, CustomStringConvertible {
    /// How many UTF-16 code units are kept (`SpoolRecordLayer.maxErrorCodeCharacters`).
    static let maxUTF16 = SpoolRecordLayer.maxErrorCodeCharacters

    /// The cleaned, cut text.
    let text: String

    /// Cleans and cuts `raw`.
    init(_ raw: String) {
        var kept = String.UnicodeScalarView()
        var units = 0
        for scalar in raw.unicodeScalars where !Self.isDropped(scalar) {
            units += scalar.utf16.count
            guard units <= Self.maxUTF16 else {
                break
            }
            kept.append(scalar)
        }
        text = String(kept)
    }

    var description: String { text }

    /// Whether this is `code`, byte for byte.
    func `is`(_ code: String) -> Bool {
        text.utf8.elementsEqual(code.utf8)
    }

    private static func isDropped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            true
        default:
            false
        }
    }
}

/// Why this side ended a connection (`SpoolConnection.fault`, `ScopeSync.NO_HELLO`), the words Kotlin's status uses. A
/// session we end is no reached session: the backoff grows.
internal enum SpoolFault: String, Sendable {
    /// Three requests in a row went unanswered (`UNRESPONSIVE`).
    case unresponsive = "unresponsive"
    /// No usable `hello` inside the handshake's 20 s (`NO_HELLO`), or our reply did not fit the spool's `maxRecord`.
    case noHello = "no_hello"
    /// A `sub` did not fit the spool's `maxRecord` (`ScopeSync.subscribe`'s `too_large` abort).
    case tooLarge = "too_large"
    /// The spool's versions do not include ours; the close carries 4002.
    case version = "version"
    /// Most of what this spool served in the last hour failed its content address or came oversize (``SpoolIntake``). This
    /// port's own word.
    case unopenable = "unopenable"
}

/// A spool's refusal of a request or a scope, every field read through a clamp.
internal struct SpoolRefusal: Equatable, Sendable {
    /// The code, cut and cleaned.
    let code: SpoolText
    /// The spool's own words, cut and cleaned, for a log line at most.
    let message: SpoolText?
    /// How long a `rate` refusal is waited out (`MAX_RATE_WAIT_MS`): the spool's `retryMs` held to 0…5 s, 5 s without
    /// one (`ScopeSync.survivable`).
    let rateWaitMilliseconds: Int64
    /// How long a scope refused `quota` or `pow` is parked (C-9.1-5): the spool's `retryMs` held to 5 min…1 h, 5 min
    /// without one, `coerceIn` and never `max`, or one absurd hint parks a scope for good (`handleScopeError`). The park
    /// itself is the heal loop's.
    let parkMilliseconds: Int64

    init(_ err: SpoolErr) {
        code = SpoolText(err.code)
        message = err.message.map(SpoolText.init)
        rateWaitMilliseconds = Self.clamp(err.retryMs, SpoolSession.maxRateWaitMilliseconds, 0...SpoolSession.maxRateWaitMilliseconds)
        parkMilliseconds = Self.clamp(
            err.retryMs, SpoolSession.minParkMilliseconds, SpoolSession.minParkMilliseconds...SpoolSession.maxParkMilliseconds)
    }

    /// `hint`, or `fallback` without one, held to `range`. A clamp never adds, so no spool value can overflow it.
    private static func clamp(_ hint: Int64?, _ fallback: Int64, _ range: ClosedRange<Int64>) -> Int64 {
        min(max(hint ?? fallback, range.lowerBound), range.upperBound)
    }
}

/// One blob the spool sent for a scope this connection subscribed: a pulled one (``SpoolSessionEvent/pulled(request:_:)``)
/// or a live one (``SpoolSessionEvent/live(_:)``). The bytes are the caller's to open; nothing else rides with them.
///
/// Its descriptions name the two ids' prefixes and the blob's size, and its mirror has no children, so no log line,
/// `String(reflecting:)` or `dump` carries a whole id or the bytes.
internal struct SpoolArrival: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The scope.
    let scope: SpoolID
    /// The id the spool claims, unchecked against the bytes: the heal loop hashes them first (§4.4).
    let blobId: SpoolID
    /// The sealed blob, at most the `maxBlob` this side declared for the scope.
    let data: [UInt8]

    var description: String { "\(scope)/\(blobId), \(data.count) bytes" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What the spool's last `digest` for a scope said, held for the connection's life (`spoolDigests`, `spoolCounts`).
/// ``count`` is the spool's echo for a status line, never a size or a range bound.
internal struct SpoolAnchor: Equatable, Sendable {
    /// The fold of the spool's live ids.
    var digest: UInt64
    /// How many the spool says it holds.
    var count: Int
    /// Whether the spool says the scope is at its bounds.
    var full: Bool
}

/// A request's terminal answer.
internal enum SpoolReply: Equatable, Sendable {
    /// A listing's live ids and tombstones, each id 32 bytes (`onListing`'s `isId` filter).
    case listing(live: [SpoolID], tombstones: [SpoolID])
    /// A pull's end. `missing` holds only ids this pull named and the spool never served; `oversize` the named ids it
    /// served past the `maxBlob` this side declared, which the heal loop quarantines in its invalid set (§9.3,
    /// `PullOutcome.oversize`).
    case pulled(missing: [SpoolID], oversize: [SpoolID])
    /// A push stored, or acked as the duplicate it was (S-7.2-7).
    case stored
    /// The spool refused it.
    case refused(SpoolRefusal)
    /// Nothing usable came within the request's 30 s, or an `ok` came for a list (which Kotlin's `as? Listing` reads as
    /// no answer).
    case unanswered
    /// The connection ended under it.
    case closed
}

/// What a record the session dropped was, for a count and a log line.
internal enum SpoolDrop: Equatable, Sendable {
    /// Not a record this build reads: past ``SpoolRecordLayer/maxInboundRecord``, not CBOR, or fields kotlinx refuses.
    case undecodable
    /// A well-formed record under a name this build ignores, its `t` cleaned.
    case unknown(SpoolText)
    /// Anything but `hello` before the spool's `hello`.
    case beforeHello
    /// A `hello` after the first, which never renegotiates.
    case lateHello
    /// An id that is not 32 bytes, or a digest that is not 8.
    case malformed
    /// A `digest`, `event`, `blob` or uncorrelated `err` for a scope this connection has not subscribed.
    case unsubscribed
    /// A `blob` no outstanding pull named, or named and already served.
    case unsolicited
    /// An `event` past the `maxBlob` this side declared.
    case oversize
    /// An `ok`, `list` or `err` that answers no outstanding request of ours, or answers it about another scope.
    case unmatched
}

/// What the session tells its caller.
internal enum SpoolSessionEvent: Equatable, Sendable {
    /// The hello exchange finished: what "connected" means.
    case connected
    /// A `digest` moved the scope's anchor or count, or set its first: the cue for a heal round.
    case digest(SpoolID)
    /// A live `event` for a subscribed scope.
    case live(SpoolArrival)
    /// A blob an outstanding pull named, at most once per named id.
    case pulled(request: Int64, SpoolArrival)
    /// A blob an outstanding pull named, served past the `maxBlob` this side declared: its id goes back in the pull's
    /// `oversize`, and this says how many bytes it cost, so the heal loop charges them to the relay's hourly budget.
    case servedOversize(request: Int64, scope: SpoolID, bytes: Int)
    /// A request's terminal answer.
    case answered(request: Int64, SpoolReply)
    /// A scope the spool refused (a `sub` refused `pow` or `quota`, most often). It is no longer subscribed here.
    case scopeRefused(SpoolID, SpoolRefusal)
    /// A scope whose `sub` went 30 s without its `digest` or refusal. It is no longer subscribed here.
    case subscriptionLapsed(SpoolID)
    /// An error naming neither a request of ours nor a scope.
    case spoolError(SpoolRefusal)
    /// A record dropped unread.
    case dropped(SpoolDrop)
    /// The connection is over: `fault` is ours when we ended it, `nil` when the socket went.
    case ended(fault: SpoolFault?)
}

/// What the session asks of its socket and its caller. A record to send is described by its size alone, and the mirror
/// has no children, so neither a log line nor `dump` carries a record's bytes.
internal enum SpoolSessionOutput: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Send one record as one binary WebSocket message.
    case send([UInt8])
    /// Close the socket with this code.
    case close(code: Int)
    /// Tell the caller.
    case event(SpoolSessionEvent)

    var description: String {
        switch self {
        case .send(let bytes):
            "send(\(bytes.count) bytes)"
        case .close(let code):
            "close(\(code))"
        case .event(let event):
            "event(\(event))"
        }
    }

    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}
