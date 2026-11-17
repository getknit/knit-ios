/// The client-to-spool record layer's names and bounds (`SpoolRecords.kt` in knit-next, `docs/SPOOL_PROTOCOL.md` §7, ADR
/// 2026-11.adrq): one CBOR record per WebSocket binary message, in kotlinx's profile with every byte array a byte string.
/// None of it is mesh wire. A spool moves opaque sealed blobs, digests and bounds, and never a `WireEnvelope`.
public enum SpoolRecordLayer {
    /// The record-layer version this build speaks, negotiated in `hello` (`SPOOL_RECORD_VERSION`).
    public static let version = 1
    /// Scope ids, blob ids, roots and keys are all 32 bytes (`SPOOL_ID_BYTES`, §12.1), the one shape check the layer
    /// owns.
    public static let idByteCount = 32
    /// A digest is 8 bytes, big-endian (§2, B-2-7).
    public static let digestByteCount = 8
    /// The largest blob this build declares for a scope (`ScopeRegistry.DEFAULT_MAX_BLOB`, §12.2), 64 KiB.
    public static let defaultMaxBlob = 65_536
    /// The largest inbound record this build will decode at all (`MAX_INBOUND_RECORD`), twice ``defaultMaxBlob``: a
    /// `blob` carrying one frame at the declared `maxBlob` is the largest record a conforming spool sends.
    public static let maxInboundRecord = defaultMaxBlob + defaultMaxBlob
    /// The most ids one listing can carry under ``maxInboundRecord`` (`MAX_PINNED_FRAMES`).
    public static let maxPinnedFrames = maxInboundRecord / idByteCount
    /// How much of a spool's error code is kept (`SPOOL_ERR_CODE_MAX`): the registry's longest code is 14 characters,
    /// and a code outlives the connection in the plane's status.
    public static let maxErrorCodeCharacters = 32
}

/// The record discriminators, `t` (`SpoolRecordType`). This build reads and writes the core ten; every other name,
/// the attachment family, TURN, tickets, casts and signals among them, is ignored on arrival and never sent.
public enum SpoolRecordType {
    /// Version negotiation, each direction's first record.
    public static let hello = "hello"
    /// Subscribe to scopes and declare their bounds.
    public static let sub = "sub"
    /// A scope's anti-entropy cue.
    public static let digest = "digest"
    /// The id exchange behind a digest mismatch, asked and answered under one name.
    public static let list = "list"
    /// Ask for blobs by id.
    public static let pull = "pull"
    /// One pulled blob.
    public static let blob = "blob"
    /// Store a blob.
    public static let push = "push"
    /// A blob another subscriber pushed, fanned out live.
    public static let event = "event"
    /// A request's success.
    public static let ok = "ok"
    /// A request's or a scope's failure.
    public static let err = "err"
}

/// A spool's error codes (`SpoolErrCode`), an append-only registry: a code this build does not know is a generic
/// failure.
public enum SpoolErrorCode {
    /// Reserved; a version mismatch is close code 4002, never a record (B-7.2-1).
    public static let version = "version"
    /// The spool wants proof of work for a scope it does not hold (§8).
    public static let pow = "pow"
    /// The blob was deleted at the spool and may not come back inside its tombstone's life.
    public static let tombstoned = "tombstoned"
    /// A scope or byte quota is spent.
    public static let quota = "quota"
    /// The blob is past the scope's `maxBlob`.
    public static let tooLarge = "too_large"
    /// A blob id that is not the hash of its blob.
    public static let badId = "bad_id"
    /// Too many requests; `retryMs` says how long to wait.
    public static let rate = "rate"
    /// A scope operation before its `sub` on this connection.
    public static let notSubscribed = "not_subscribed"
    /// A record the spool could not read.
    public static let malformed = "malformed"
    /// The spool's own fault.
    public static let `internal` = "internal"
    /// An attachment chunk that differs from the one stored; only `aput` draws it.
    public static let conflict = "conflict"
    /// A ticket refusal; never the answer to a `sub`.
    public static let ticket = "ticket"
}

/// WebSocket close codes (`SpoolCloseCode`, §7.1). None of them means "come back later": a full spool refuses the
/// upgrade with HTTP 503 instead (S-7.1-10).
public enum SpoolCloseCode {
    /// The ordinary close, which is what this client sends.
    public static let normal = 1000
    /// The spool is going away, or stopped a room; reconnect under the usual backoff.
    public static let goingAway = 1001
    /// Malformed traffic before `hello`.
    public static let malformed = 4000
    /// A private spool's `?k=` token did not match.
    public static let auth = 4001
    /// No record-layer version in common.
    public static let version = 4002
    /// The spool judged the connection abusive.
    public static let abuse = 4003
}
