import Crypto
import Foundation

/// A photo in a DM or a group, sealed for the mesh (`AttachmentCrypto.kt`). The photo is sealed with AES-256-GCM under
/// a fresh key and nonce, with no AAD, and the blob that is stored, served and carried is `nonce ‖ ciphertext ‖ tag`.
/// The blob is named by its SHA-256 like any other, so the blob exchange and custody move it unchanged, while a relay
/// only ever sees ciphertext. The key travels inside the sealed message, in base64, and never in the clear. A photo is
/// sealed once: sent again, it goes as the blob and key this phone already holds it under (ADR 2026-10.f3mv), so a
/// carrier can tell that two messages carry one photo.
public enum AttachmentCrypto {
    /// The key's length.
    public static let keyByteCount = 32
    /// The nonce's length, which opens the blob (`AesGcm.IV_BYTES`).
    public static let nonceByteCount = 12
    /// The tag's length, which ends the blob.
    public static let tagByteCount = 16

    /// A sealed photo: the blob to store and serve, and the key that opens it.
    public struct Sealed: Sendable, Equatable {
        /// `nonce ‖ ciphertext ‖ tag`.
        public let blob: [UInt8]
        /// The key, which only the sealed message carries.
        public let key: [UInt8]
    }

    /// Seals `plain` under a fresh key and nonce from the system's generator, or `nil` if the library refuses.
    public static func seal(_ plain: [UInt8]) -> Sealed? {
        let key = secureRandomBytes(keyByteCount)
        return seal(plain, key: key, nonce: secureRandomBytes(nonceByteCount)).map { Sealed(blob: $0, key: key) }
    }

    /// The blob of `plain` sealed under `key` and `nonce`, for a known answer. A key must never seal twice under one
    /// nonce: ``seal(_:)`` draws both fresh.
    public static func seal(_ plain: [UInt8], key: [UInt8], nonce: [UInt8]) -> [UInt8]? {
        guard key.count == keyByteCount, nonce.count == nonceByteCount,
            let box = try? AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: [UInt8]())
        else {
            return nil
        }
        return nonce + Array(box.ciphertext) + Array(box.tag)
    }

    /// The photo in `blob`, opened with `key`, or `nil` when the key is wrong, the tag does not match, or the blob is too
    /// short to hold a nonce and a tag: on any failure, as Android answers null.
    public static func open(_ blob: [UInt8], key: [UInt8]) -> [UInt8]? {
        guard key.count == keyByteCount, blob.count >= nonceByteCount + tagByteCount else {
            return nil
        }
        let body = blob.dropFirst(nonceByteCount)
        guard
            let box = try? AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: blob.prefix(nonceByteCount)),
                ciphertext: body.dropLast(tagByteCount),
                tag: body.suffix(tagByteCount)
            )
        else {
            return nil
        }
        return (try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: [UInt8]())).map { Array($0) }
    }
}
