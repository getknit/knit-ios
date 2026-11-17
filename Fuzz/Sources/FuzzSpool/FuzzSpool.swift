import KnitWire

/// Arbitrary bytes as a record from a spool, which is untrusted (ADR 2026-11.adrq), and as a pasted or opened text
/// through the relay invite's parser and the spool URL rules. Nothing traps. A record that decodes encodes to bytes that
/// decode to it again; an invite that parses carries a URL a release build may dial; the stored form of a URL is stable.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzSpool(_ data: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let bytes = Array(unsafe UnsafeBufferPointer(start: data, count: count))
    if let record = SpoolRecord(decoding: bytes), let encoded = record.encoded {
        if case .hello(let hello) = record, let limits = hello.limits?.clamped() {
            precondition(
                limits.maxBlob <= SpoolRecordLayer.maxInboundRecord && (1...SpoolLimits.maxPullCeiling).contains(limits.maxPull),
                "a clamp let a claim through")
        }
        precondition(SpoolRecord(decoding: encoded) == record, "a record changed on a round trip")
    }
    // Lossy on purpose: every input becomes some string, replacement characters included.
    // swiftlint:disable:next optional_data_string_conversion
    let text = String(decoding: bytes, as: UTF8.self)
    for parsed in [
        RelayInvite.parse(text, allowCleartext: false),
        RelayInvite.parse(RelayInvite.schemePrefix + Base64.encode(bytes, variant: .urlSafeUnpadded), allowCleartext: false),
    ] {
        guard case .invite(let invite) = parsed else {
            continue
        }
        precondition(SpoolURL.isAcceptable(invite.url, allowCleartext: false), "an invite kept a URL a release build refuses")
        precondition(invite.url.utf16.count <= RelayInvite.maxURLCharacters, "an invite's URL past its limit")
        precondition(SpoolURL.isPlain(invite.url), "an invite kept a URL whose shown host is not its dialled one")
    }
    _ = RelayInvite.looksLikeInvite(text)
    let canonical = SpoolURL.canonical(text)
    precondition(SpoolURL.canonical(canonical) == canonical, "the stored form moved when stored again")
    precondition(!SpoolURL.redact(text).utf8.contains(UInt8(ascii: "?")), "a redacted URL kept its query")
    _ = SpoolURL.host(text)
    return 0
}
