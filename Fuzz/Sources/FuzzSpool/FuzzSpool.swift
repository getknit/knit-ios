import KnitCrypto
import KnitWire

/// §13's DM scope (`spool-v1.json`'s `Derivations`: `dmScopeId`, `dmSealKey`, `dmNonceKey`), under which §13's sealed
/// blob, one of the seeds, opens. `ScopeVectorTests` ties the three to their derivation.
private let scope = ScopeKeys(
    id: Hex.decode("aeced0ad65f9e416c3a4d6015ff6bd61849df5bcaf89b5a6f19aa9d654e7a8b2") ?? [],
    sealKey: Hex.decode("fe7c47b82425bb4dbbd224ca192bf81131bdae07299380728b6eb3721d82eac7") ?? [],
    nonceKey: Hex.decode("1704dfd72d5f529e8491784d17ed69e10fa7cbc2236667c23c77638dfd645dbe") ?? []
)

/// Arbitrary bytes as a record from a spool, which is untrusted (ADR 2026-11.adrq), as a blob it serves, and as a pasted
/// or opened text through the relay invite's parser and the spool URL rules. Nothing traps. A record that decodes encodes
/// to bytes that decode to it again; a blob that opens seals back to the same bytes and id; an invite that parses carries
/// a URL a release build may dial; the stored form of a URL is stable; a dialled address passes every rule and prints its
/// host alone.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzSpool(_ data: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let bytes = Array(unsafe UnsafeBufferPointer(start: data, count: count))
    // The blob under its own hash, so the hash check passes and every later check sees the bytes; under the id a pulled
    // blob's first 32 bytes would claim; and as a `blob` or `event` record's data under the id beside it.
    let idCount = ScopeCrypto.idByteCount
    var served = [
        (blobId: ScopeCrypto.blobId(of: bytes), blob: bytes),
        (blobId: Array(bytes.prefix(idCount)), blob: Array(bytes.dropFirst(idCount))),
    ]
    let record = SpoolRecord(decoding: bytes)
    switch record {
    case .blob(let blob):
        served.append((blob.blobId, blob.data))
    case .event(let event):
        served.append((event.blobId, event.data))
    default:
        break
    }
    for (blobId, blob) in served {
        guard let scope, let opened = ScopeCrypto.open(scope, blobId: blobId, blob: blob) else {
            continue
        }
        precondition(opened.sig.count == ScopeCrypto.signatureByteCount && !opened.signed.isEmpty, "an opened blob split wrong")
        let resealed = ScopeCrypto.seal(scope, sig: opened.sig, signed: opened.signed)
        precondition(resealed?.blob == blob && resealed?.blobId == blobId, "an opened blob sealed back to other bytes")
    }
    if let record, let encoded = record.encoded {
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
    checkDialledAddress(text)
    return 0
}

/// The dialled address (P4b1): what the factory takes from `text` passes every rule, and prints no query, user info or
/// fragment.
private func checkDialledAddress(_ text: String) {
    for cleartext in [false, true] {
        guard let accepted = AcceptedSpoolURL(text, allowCleartext: cleartext) else {
            continue
        }
        let dialled = accepted.socketURLText
        precondition(SpoolURL.isAcceptable(SpoolURL.canonical(dialled), allowCleartext: cleartext), "a dialled address its build refuses")
        precondition(SpoolURL.isPlain(dialled) && dialled.utf8.count <= AcceptedSpoolURL.maxBytes, "a dialled address not plain")
        let afterScheme = dialled.utf8.drop { $0 != UInt8(ascii: "/") }.dropFirst("//".utf8.count)
        let authority = afterScheme.prefix { $0 != UInt8(ascii: "/") && $0 != UInt8(ascii: "?") && $0 != UInt8(ascii: "#") }
        precondition(!authority.contains(UInt8(ascii: "%")), "a dialled authority holding a percent")
        precondition(
            !"\(accepted)".utf8.contains { $0 == UInt8(ascii: "?") || $0 == UInt8(ascii: "@") || $0 == UInt8(ascii: "#") },
            "an address printed past its host")
    }
}
