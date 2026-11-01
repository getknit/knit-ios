public import KnitWire

/// The proof a link's peer gives of the node id its HELLO claims (`LinkProof.kt` in knit-next, #232; knit-ios #25).
/// Pure: no state and nothing of the mesh's, so the link manager owns when it runs and this owns only the bytes.
///
/// Each side signs, with its identity Ed25519 key, one transcript of both HELLOs as they crossed the link:
///
/// ```text
/// transcript = "knit/link/v1/proof" (18 ASCII) ‖ role (1) ‖ u32be(len hD) ‖ hD ‖ u32be(len hR) ‖ hR
/// role       = 0x01 the signer dialed | 0x02 the signer answered
/// payload    = sigPub (32) ‖ hpkePub (32) ‖ signature (64)                = 128 bytes
/// ```
///
/// - **Both HELLOs, dialer's first, whoever signs.** Each HELLO carries a nonce fresh for this connection
///   (``freshNonce()``), so a proof holds for this link's exchange and no other. The bytes are the payloads as they
///   crossed, never re-encoded from parsed fields, so both ids, versions, capabilities and nonces are covered, and the
///   two ends sign the same bytes without agreeing on a canonical form.
/// - **The role byte** keeps one side's signature from being taken as the other's: both proofs of a link sign the same
///   two HELLOs.
/// - **The keys ride the payload,** so a verifier that never met the peer can check it: the node id is the hash of the
///   bundle rebuilt from the two raw keys, as a contact card's is (`ContactCard.decodeSigned`).
/// - **Apart from everything else the identity key signs.** A frame's signed bytes are a CBOR map, and a transcript
///   starts with `k` (0x6B), a CBOR text-string head, so neither reads as the other. A contact card signs
///   `knit/card/v1 ‖ body` and a signed prekey `knit/dm/v2/spk ‖ id ‖ pub`; neither label is a prefix of this one.
///
/// CryptoKit randomizes Ed25519 and Tink does not, so a payload made here differs from Android's for the same transcript,
/// and two made here differ from each other. Verify one; never compare its bytes.
public enum LinkProof {
    /// The transcript's label (`LinkProof.LABEL`).
    public static let label = "knit/link/v1/proof"
    /// A HELLO's nonce: 16 bytes, 32 lowercase hex digits in the HELLO's fourth field.
    public static let nonceByteCount = 16
    /// An Ed25519 signature (RFC 8032).
    public static let signatureByteCount = 64
    /// The two raw public keys a PROOF carries, `sigPub ‖ hpkePub`, as a contact card's `pk` does.
    public static let keysByteCount = PublicKeyBundle.keyByteCount + PublicKeyBundle.keyByteCount
    /// A PROOF record's payload: the two raw public keys, then the signature (`LinkProof.PAYLOAD_BYTES`).
    public static let payloadByteCount = keysByteCount + signatureByteCount

    /// Which end of the link signed (`LinkProof.Role`). The byte is in the transcript, so it is wire.
    public enum Role: UInt8, Sendable {
        /// The side that dialed: its HELLO went first.
        case dialer = 0x01
        /// The side that answered: its HELLO is the reply.
        case responder = 0x02
    }

    /// Why a proof failed (`LinkProof.Failure`). Each one fails the link's handshake alike; the reason is for the log.
    public enum Failure: String, Sendable, Equatable {
        /// The payload is not exactly ``LinkProof/payloadByteCount`` bytes.
        case length = "length"
        /// The two keys hash to a node id other than the one the HELLO claimed.
        case idMismatch = "id mismatch"
        /// The signature does not hold over the signer's transcript of these two HELLOs. A key that is not a point on the
        /// curve answers this too: once the length is right, the bundle always builds, and only the verify can refuse it.
        case badSignature = "bad signature"
    }

    /// What ``verify(_:claimedId:signer:dialerHello:responderHello:)`` found.
    public enum Outcome: Sendable, Equatable {
        /// The claimed id signed this link's transcript; its bundle, rebuilt from the payload's keys.
        case proven(PublicKeyBundle)
        /// The proof failed.
        case failed(Failure)
    }

    /// The bytes `signer` signs for a link whose dialer wrote `dialerHello` and whose responder wrote `responderHello`
    /// (`LinkProof.transcript`): the label, the role, then each HELLO payload behind its length, as it crossed the link.
    public static func transcript(signer: Role, dialerHello: [UInt8], responderHello: [UInt8]) -> [UInt8] {
        var bytes = Array(label.utf8)
        bytes.append(signer.rawValue)
        appendLengthPrefixed(dialerHello, to: &bytes)
        appendLengthPrefixed(responderHello, to: &bytes)
        return bytes
    }

    /// Our PROOF record's payload as `signer` (`LinkProver.proof`): our two raw public keys, then our signature over the
    /// transcript. Sign once per link and write what this returns; a second call makes a different, equally valid payload.
    public static func payload(
        keys: IdentityKeys, signer: Role, dialerHello: [UInt8], responderHello: [UInt8]
    ) throws(CryptoFailure) -> [UInt8] {
        let signature = try keys.signature(for: transcript(signer: signer, dialerHello: dialerHello, responderHello: responderHello))
        return keys.bundle.signingKey + keys.bundle.agreementKey + signature
    }

    /// Whether `payload` proves that `claimedId`, the id the signer's HELLO named, signed `signer`'s transcript of these
    /// two HELLOs (`LinkProof.verify`), checked in this order: the length, the id the keys hash to, then the signature.
    /// Never throws, and answers ``Outcome/failed(_:)`` for anything malformed.
    public static func verify(
        _ payload: [UInt8], claimedId: NodeId, signer: Role, dialerHello: [UInt8], responderHello: [UInt8]
    ) -> Outcome {
        guard payload.count == payloadByteCount else {
            return .failed(.length)
        }
        let keyBytes = PublicKeyBundle.keyByteCount
        // Built as a contact card's is (`ContactCard.decodeSigned`); with both slices 32 bytes it never fails.
        guard
            let bundle = PublicKeyBundle(
                signingKey: Array(payload[0..<keyBytes]), agreementKey: Array(payload[keyBytes..<keysByteCount]))
        else {
            return .failed(.length)
        }
        // By the id's bytes, never as Swift strings (ADR 2026-09.jc2x).
        guard bundle.nodeId.string.utf8.elementsEqual(claimedId.string.utf8) else {
            return .failed(.idMismatch)
        }
        let signature = Array(payload[keysByteCount...])
        let message = transcript(signer: signer, dialerHello: dialerHello, responderHello: responderHello)
        guard bundle.isValidSignature(signature, for: message) else {
            return .failed(.badSignature)
        }
        return .proven(bundle)
    }

    /// A nonce for one HELLO: ``nonceByteCount`` bytes from the system's secure random source, fresh for every connection
    /// attempt, the dialer's and the reply's alike. Never from the mesh's injected generator, which a test seeds: a nonce
    /// anyone can predict lets a recorded proof be replayed.
    public static func freshNonce() -> [UInt8] {
        secureRandomBytes(nonceByteCount)
    }

    /// `bytes` behind its length as a 4-byte big-endian count. A HELLO crossed the link in a record whose own length field
    /// is 4 bytes, so its count always fits.
    private static func appendLengthPrefixed(_ bytes: [UInt8], to out: inout [UInt8]) {
        let count = UInt32(truncatingIfNeeded: bytes.count)
        out.append(contentsOf: [UInt8(truncatingIfNeeded: count >> 24), UInt8(truncatingIfNeeded: count >> 16)])
        out.append(contentsOf: [UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)])
        out.append(contentsOf: bytes)
    }
}
