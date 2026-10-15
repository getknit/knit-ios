import Crypto
import Foundation
public import KnitWire

/// v1 direct messages (`MessageCrypto.kt`): a fresh AES-256-GCM key seals the body, and HPKE wraps that key to
/// each recipient. The header binds both to the frame, as the body's AAD and as HPKE's `info`.
///
/// The envelope is not signed here. It rides inside a `chat` frame whose one signature covers it, so a wrapped
/// key or a body cannot be moved into another message. v1 has no forward secrecy: whoever later takes a
/// recipient's X25519 key can open every v1 DM ever sent to it. The MVP seals nothing else, and the ratchet
/// comes next (ADR 2026-09.qsd9).
public enum MessageCrypto {
    /// The body key's length.
    public static let keyByteCount = 32
    /// The AES-GCM nonce's length.
    public static let nonceByteCount = 12
    /// The AES-GCM tag's length; the tag follows the ciphertext in ``EncEnvelope/ct``.
    public static let tagByteCount = 16
    /// HPKE's encapsulated X25519 key, which opens every ``WrappedKey/wk``.
    public static let encapsulatedKeyByteCount = 32

    /// Tink's `DHKEM_X25519_HKDF_SHA256_HKDF_SHA256_AES_256_GCM_RAW`, in base mode.
    private static let ciphersuite = HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256)

    /// The header that binds a message to its frame: `id|senderId|sentAt|thread` as UTF-8. `thread` is the
    /// recipient's node id for a DM.
    public static func header(id: String, senderId: String, sentAt: Int64, thread: String) -> [UInt8] {
        Array("\(id)|\(senderId)|\(sentAt)|\(thread)".utf8)
    }

    /// Seals `content`, an encoded ``MessageContent``, to each recipient. Returns `nil` when there are no
    /// recipients, because nobody could read the frame.
    ///
    /// Wrapped keys are sorted by node id, as knit-next sorts them, so the same message to the same people
    /// always lists its keys in the same order.
    public static func seal(
        _ content: [UInt8],
        header: [UInt8],
        to recipients: [NodeId: PublicKeyBundle]
    ) throws(CryptoFailure) -> EncEnvelope? {
        guard !recipients.isEmpty else {
            return nil
        }
        let key = secureRandomBytes(keyByteCount)
        let nonce = secureRandomBytes(nonceByteCount)
        do {
            let box = try AES.GCM.seal(
                content,
                using: SymmetricKey(data: key),
                nonce: AES.GCM.Nonce(data: nonce),
                authenticating: header
            )
            var keys: [WrappedKey] = []
            for (recipient, bundle) in recipients.sorted(by: { $0.key < $1.key }) {
                keys.append(WrappedKey(to: recipient.string, wk: try wrap(key, to: bundle, header: header)))
            }
            return EncEnvelope(nonce: nonce, ct: Array(box.ciphertext) + Array(box.tag), keys: keys)
        } catch {
            throw .sealing
        }
    }

    /// Opens an envelope addressed to `identity` (`MessageCrypto.open`): finds its wrapped key, unwraps the body
    /// key and decrypts the body. The caller has already dispatched on ``EncEnvelope/version``.
    ///
    /// Returns `nil` on any failure (no key for us, a bad tag, a body that does not decode) and never throws:
    /// a message that will not open is dropped, and its frame is still relayed.
    public static func open(_ envelope: EncEnvelope, header: [UInt8], as identity: IdentityKeys) -> MessageContent? {
        guard let body = openBody(envelope, header: header, as: identity) else {
            return nil
        }
        return try? MessageContent(decoding: body)
    }

    /// The decrypted body bytes, before they are decoded.
    static func openBody(_ envelope: EncEnvelope, header: [UInt8], as identity: IdentityKeys) -> [UInt8]? {
        guard let wrapped = envelope.keys.first(where: { $0.to == identity.nodeId.string }),
            wrapped.wk.count > encapsulatedKeyByteCount, envelope.ct.count >= tagByteCount
        else {
            return nil
        }
        do {
            let encapsulated = Array(wrapped.wk.prefix(encapsulatedKeyByteCount))
            guard try !Curve25519.KeyAgreement.PublicKey(rawRepresentation: encapsulated).isLowOrder() else {
                return nil
            }
            var recipient = try HPKE.Recipient(
                privateKey: identity.agreement,
                ciphersuite: ciphersuite,
                info: Data(header),
                encapsulatedKey: Data(encapsulated)
            )
            let key = try recipient.open(Array(wrapped.wk.dropFirst(encapsulatedKeyByteCount)))
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: envelope.nonce),
                ciphertext: Array(envelope.ct.dropLast(tagByteCount)),
                tag: Array(envelope.ct.suffix(tagByteCount))
            )
            return try Array(AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: header))
        } catch {
            return nil
        }
    }

    /// `key` wrapped to one recipient: the encapsulated key, then the sealed key and its tag (80 bytes).
    ///
    /// A recipient key that is a low-order point is refused (`SharedSecret+LowOrder.swift`): RFC 9180 §7.1.4 says both
    /// sides must abort on an all-zero X25519 output, and Tink refuses these keys, so Android can never seal to one or
    /// open from one.
    private static func wrap(_ key: [UInt8], to bundle: PublicKeyBundle, header: [UInt8]) throws -> [UInt8] {
        let recipientKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bundle.agreementKey)
        guard try !recipientKey.isLowOrder() else {
            throw CryptoFailure.sealing
        }
        var sender = try HPKE.Sender(recipientKey: recipientKey, ciphersuite: ciphersuite, info: Data(header))
        let sealed = try sender.seal(key)
        return Array(sender.encapsulatedKey) + Array(sealed)
    }
}
