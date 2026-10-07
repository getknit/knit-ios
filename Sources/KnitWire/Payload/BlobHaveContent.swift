/// "Do you hold these blobs?", asked of one linked neighbour whose HELLO carries ``Capabilities/blobHave``
/// (`BlobHaveContent` in knit-next's `Wire.kt`, ADR 2026-10.6e5t there).
///
/// Unsigned and point to point like a `blobreq`, and answered with a ``BlobHasContent``. A query is not an ask: it
/// serves nothing, pulls nothing and stamps no serve memo. A responder answers the first 32 hashes and ignores the rest.
public struct BlobHaveContent: CBORRepresentable, Equatable {
    /// The content hashes the asker wants the holders of.
    public var hashes: [String]

    /// Makes a holder query.
    public init(hashes: [String]) {
        self.hashes = hashes
    }

    /// Reads a holder query from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "BlobHaveContent")
        hashes = try fields.required("hashes", .texts)
    }

    /// The query as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.texts("hashes", hashes)
        return writer.cbor
    }
}

/// What a neighbour says about one blob in a ``BlobHasItem`` (`BlobHasItem`'s constants in knit-next's `Wire.kt`).
///
/// A raw number rather than an enum, because a later build may answer a state this one does not know, and such a state
/// must survive decoding and still never be taken for ``have`` (`aStateThisBuildDoesNotKnowIsNeverTakenForHave`).
public struct BlobHolding: RawRepresentable, Hashable, Sendable, ExpressibleByIntegerLiteral {
    /// Not held, and not on its way to the responder (Android's `NONE`).
    public static let notHeld: Self = 0
    /// Held whole: a `blobreq` from the asker now is served.
    public static let have: Self = 1
    /// Held, and a copy is already queued or streaming to the asker, or was served inside the memo: wait for it.
    public static let sending: Self = 2
    /// Not held yet, but streaming in or landing at the responder: query again shortly.
    public static let fetching: Self = 3
    /// Reserved for a prefix kept from a cut transfer, its length in ``BlobHasItem/held``. No build emits it yet.
    public static let partial: Self = 4

    /// The state as the wire carries it.
    public let rawValue: Int

    /// Wraps a state, known or not.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Wraps a state written as a literal.
    public init(integerLiteral value: Int) {
        rawValue = value
    }

    /// Whether a holder in this state has the blob whole (`HELD`): ``have`` or ``sending``, never a state this build
    /// does not know.
    public var isHeld: Bool { self == .have || self == .sending }
}

/// One hash's answer inside a ``BlobHasContent`` (`BlobHasItem` in knit-next's `Wire.kt`).
public struct BlobHasItem: CBORRepresentable, Equatable, Sendable {
    /// The hash asked about.
    public var hash: String
    /// The responder's state for it, always on the wire, `0` included.
    public var state: BlobHolding
    /// The whole blob's length, given with ``BlobHolding/have`` and ``BlobHolding/sending``.
    public var size: Int64?
    /// Reserved for ``BlobHolding/partial``: the bytes held from 0.
    public var held: Int64?
    /// With ``BlobHolding/sending``, when the holder can tell: the milliseconds until the asker's copy should have landed
    /// (knit-next ADR 2026-10.nsr7). The asker holds on that holder that long rather than ask another.
    public var eta: Int64?

    /// Makes one answer.
    public init(hash: String, state: BlobHolding, size: Int64? = nil, held: Int64? = nil, eta: Int64? = nil) {
        self.hash = hash
        self.state = state
        self.size = size
        self.held = held
        self.eta = eta
    }

    /// Reads one answer from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "BlobHasItem")
        hash = try fields.required("hash", .text)
        state = BlobHolding(rawValue: try fields.required("state", .int32))
        size = try fields.nullable("size", .int64)
        held = try fields.nullable("held", .int64)
        eta = try fields.nullable("eta", .int64)
    }

    /// The answer as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("hash", hash)
        writer.int("state", state.rawValue)
        writer.long("size", optional: size)
        writer.long("held", optional: held)
        writer.long("eta", optional: eta)
        return writer.cbor
    }
}

/// The answer to one ``BlobHaveContent`` (`BlobHasContent` in knit-next's `Wire.kt`): an item per hash asked, how many
/// files the responder is feeding, and the query's envelope id, so the asker matches the answer to its query.
public struct BlobHasContent: CBORRepresentable, Equatable, Sendable {
    /// One answer per hash asked.
    public var items: [BlobHasItem]
    /// How many files the responder is feeding now, never to whom.
    public var load: Int?
    /// The envelope id of the query this answers.
    public var re: String?

    /// Makes an answer.
    public init(items: [BlobHasItem], load: Int? = nil, re: String? = nil) {
        self.items = items
        self.load = load
        self.re = re
    }

    /// Reads an answer from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "BlobHasContent")
        items = try fields.required("items", .list(of: BlobHasItem.self))
        load = try fields.nullable("load", .int32)
        re = try fields.nullable("re", .text)
    }

    /// The answer as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.list("items", items)
        writer.int("load", optional: load)
        writer.text("re", optional: re)
        return writer.cbor
    }
}

/// How much of a file streaming in over a link its receiver holds (`BlobProgressContent` in knit-next's `Wire.kt`, ADR
/// 2026-10.nsr7 there), sent back to the file's sender every couple of seconds of chunks.
///
/// Unsigned and point to point like a ``BlobHaveContent``, under the same ``Capabilities/blobHave`` bit. `ms` is by the
/// receiver's own clock, so the rate between two reports is the drain whatever a report waited for on its way back: the
/// sender measures what its stack's queue hides from it, and times the asks it parked behind the feed by it.
public struct BlobProgressContent: CBORRepresentable, Equatable, Sendable {
    /// The key of the file streaming in, its content hash.
    public var hash: String
    /// The bytes of it held so far, a resumed stream's kept prefix included.
    public var held: Int64
    /// The milliseconds since its header arrived, by the receiver's clock.
    public var ms: Int64

    /// Makes a progress report.
    public init(hash: String, held: Int64, ms: Int64) {
        self.hash = hash
        self.held = held
        self.ms = ms
    }

    /// Reads a progress report from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "BlobProgressContent")
        hash = try fields.required("hash", .text)
        held = try fields.required("held", .int64)
        ms = try fields.required("ms", .int64)
    }

    /// The report as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("hash", hash)
        writer.long("held", held)
        writer.long("ms", ms)
        return writer.cbor
    }
}
