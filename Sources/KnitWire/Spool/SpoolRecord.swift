/// One record of the client-to-spool layer, read by its discriminator `t` (`SpoolCodec.peekType`, then the type's own
/// decode, in `SpoolConnection.onMessage`).
///
/// Decoding never throws and never traps: a spool is untrusted, and a record Android's decode refuses is dropped there,
/// never closed on, so ``init(decoding:)`` answers `nil` for it here. A well-formed record under a name this build does
/// not read (the attachment family, TURN, tickets, casts, signals, or a name added later) is ``other(_:)``, which the
/// caller ignores.
public enum SpoolRecord: Equatable, Sendable {
    /// Version negotiation.
    case hello(SpoolHello)
    /// A subscription request.
    case sub(SpoolSub)
    /// A scope's digest.
    case digest(SpoolDigest)
    /// A listing, asked or answered.
    case list(SpoolList)
    /// A pull.
    case pull(SpoolPull)
    /// A pulled blob.
    case blob(SpoolBlob)
    /// A push.
    case push(SpoolPush)
    /// A live blob.
    case event(SpoolEvent)
    /// A success.
    case ok(SpoolOk)
    /// A failure.
    case err(SpoolErr)
    /// A record under a name this build reads no further.
    case other(String)

    /// Reads one record, or `nil` when the bytes are not one: past ``SpoolRecordLayer/maxInboundRecord``, which Android's
    /// socket drops before it decodes (`OkHttpSpoolDialer`), not one CBOR item, not a map with a text `t`, or a known name
    /// whose fields kotlinx's decode would refuse.
    public init?(decoding bytes: [UInt8]) {
        guard bytes.count <= SpoolRecordLayer.maxInboundRecord, let item = try? CBOR.decode(bytes),
            let type = try? Self.type(of: item)
        else {
            return nil
        }
        do {
            self = try Self.decode(item, type: type)
        } catch {
            return nil
        }
    }

    /// The record's bytes. `nil` for ``other(_:)``, which this build never sends.
    public var encoded: [UInt8]? {
        switch self {
        case .hello(let record):
            record.encoded
        case .sub(let record):
            record.encoded
        case .digest(let record):
            record.encoded
        case .list(let record):
            record.encoded
        case .pull(let record):
            record.encoded
        case .blob(let record):
            record.encoded
        case .push(let record):
            record.encoded
        case .event(let record):
            record.encoded
        case .ok(let record):
            record.encoded
        case .err(let record):
            record.encoded
        case .other:
            nil
        }
    }

    /// The discriminator alone (`SpoolRecordHead`): a required text `t`, every other key ignored.
    private static func type(of item: CBOR) throws(WireDecodingError) -> String {
        try CBORFields(item, type: "SpoolRecordHead").required("t", .text)
    }

    /// The record `t` names, matched by its UTF-8 bytes as Kotlin's `when` matches strings, never by Swift's canonical
    /// equivalence (ADR 2026-09.jc2x).
    private static func decode(_ item: CBOR, type: String) throws(WireDecodingError) -> Self {
        let decoders: [(String, (CBOR) throws(WireDecodingError) -> Self)] = [
            (SpoolRecordType.hello, { item throws(WireDecodingError) in .hello(try SpoolHello(cbor: item)) }),
            (SpoolRecordType.sub, { item throws(WireDecodingError) in .sub(try SpoolSub(cbor: item)) }),
            (SpoolRecordType.digest, { item throws(WireDecodingError) in .digest(try SpoolDigest(cbor: item)) }),
            (SpoolRecordType.list, { item throws(WireDecodingError) in .list(try SpoolList(cbor: item)) }),
            (SpoolRecordType.pull, { item throws(WireDecodingError) in .pull(try SpoolPull(cbor: item)) }),
            (SpoolRecordType.blob, { item throws(WireDecodingError) in .blob(try SpoolBlob(cbor: item)) }),
            (SpoolRecordType.push, { item throws(WireDecodingError) in .push(try SpoolPush(cbor: item)) }),
            (SpoolRecordType.event, { item throws(WireDecodingError) in .event(try SpoolEvent(cbor: item)) }),
            (SpoolRecordType.ok, { item throws(WireDecodingError) in .ok(try SpoolOk(cbor: item)) }),
            (SpoolRecordType.err, { item throws(WireDecodingError) in .err(try SpoolErr(cbor: item)) }),
        ]
        for (name, decode) in decoders where type.utf8.elementsEqual(name.utf8) {
            return try decode(item)
        }
        return .other(type)
    }
}
