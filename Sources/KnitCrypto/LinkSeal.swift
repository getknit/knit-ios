import Crypto
import KnitSync
import KnitWire

/// A sealed link's key exchange and record AEAD (the `link-seal` contract, §5; knit-next #286, option 1; knit-ios #39).
/// Pure: no state of the mesh's, so the link manager owns when each step runs and this owns only the bytes.
///
/// Each side of a link opened in the sealed form writes a fresh X25519 key (``Ephemeral``) as its first record, a
/// `KEY_SHARE` (tag 10), and from the two derives one key per direction:
///
/// ```text
/// ss    = X25519(own ephemeral private, peer's ephemeral public)      refused when all zero (a low-order point)
/// salt  = eD ‖ eR                                                      64 bytes, the dialer's share first
/// kD2R  = HKDF-SHA256(ikm = ss, salt, info = "knit/link/v1/seal/d2r", L = 32)
/// kR2D  = HKDF-SHA256(ikm = ss, salt, info = "knit/link/v1/seal/r2d", L = 32)
/// frame = [0x0B][u32be len][AES-256-GCM(k, nonce = 00 00 00 00 ‖ u64be(n), aad = the 5 header bytes)]
/// ```
///
/// - **The dialer seals with `kD2R` and opens with `kR2D`;** the responder the reverse. A frame reflected back to its
///   sender never opens.
/// - **The counter is implicit.** `n` counts the `SEALED` frames one side wrote on this link, from 0, so a frame
///   dropped, replayed, reordered or injected fails to open, and the link closes. Neither side seals or opens frame 2^48
///   (`LinkLane.kt:145`).
/// - **Each half has one owner.** ``LinkSealer`` and ``LinkOpener`` are classes whose counter advances under a lock, so
///   however many references a sealer has, no two frames are ever sealed under one key and nonce. A copyable value
///   holding the counter would let two copies seal under one nonce, which leaks GCM's authentication key and lets a
///   listener forge.
/// - **Nothing prints a key.** ``Ephemeral``, ``Session``, ``LinkSealer`` and ``LinkOpener`` show no byte in
///   `description`, `debugDescription` or a mirror, and the raw keys are `internal`, for the vectors alone.
///
/// The HKDF takes Tink's argument order, the input key material then the salt, as ``RatchetCrypto``'s does
/// (`RatchetCrypto.swift`'s `hkdf`, Android's `LinkKeys.kt:74-75`). The AEAD is Android's `LinkLane` shape
/// (`LinkLane.kt:186-189`).
public enum LinkSeal {
    /// A `KEY_SHARE`'s payload: one raw X25519 public key.
    public static let keyShareByteCount = 32
    /// An AES-GCM tag's length; it ends every frame's payload.
    public static let tagByteCount = 16

    /// The info for the dialer-to-responder key (21 ASCII bytes).
    static let infoDialerToResponder = Array("knit/link/v1/seal/d2r".utf8)
    /// The info for the responder-to-dialer key (21 ASCII bytes).
    static let infoResponderToDialer = Array("knit/link/v1/seal/r2d".utf8)
    /// A direction key's length: AES-256.
    static let keyByteCount = 32

    /// Why no session came of a key exchange. Each is a failed seal (contract §4); the reason is for the log.
    public enum Failure: String, Error, Sendable, Equatable {
        /// The peer's `KEY_SHARE` was not exactly ``LinkSeal/keyShareByteCount`` bytes.
        case keyShareLength = "key share length"
        /// The exchange came to all zeros: the peer's share is a low-order point, which Tink refuses before it multiplies
        /// (`RatchetCrypto.kt:56-60`) and swift-crypto and CryptoKit do not (`SharedSecret+LowOrder.swift`).
        case lowOrderPoint = "low-order point"
        /// This ephemeral key already derived a session; its private half is gone.
        case spent = "spent"
    }

    /// The two `KEY_SHARE` payloads of one link: the HKDF's salt (``salt``) and what a sealed PROOF's transcript binds
    /// (``LinkProof/Form/sealed(_:)``), so the two always come from one value. Public keys, not secrets.
    public struct KeyShares: Sendable, Equatable {
        /// The dialer's ephemeral public key, `eD`.
        public let dialer: [UInt8]
        /// The responder's ephemeral public key, `eR`.
        public let responder: [UInt8]

        /// The shares of a link, or `nil` unless each is exactly ``LinkSeal/keyShareByteCount`` bytes.
        public init?(dialer: [UInt8], responder: [UInt8]) {
            guard dialer.count == LinkSeal.keyShareByteCount, responder.count == LinkSeal.keyShareByteCount else {
                return nil
            }
            self.dialer = dialer
            self.responder = responder
        }

        /// `eD ‖ eR`, the HKDF's salt.
        public var salt: [UInt8] { dialer + responder }
    }

    /// Our side's X25519 key for one connection attempt, fresh every time and used once: ``LinkSeal/derive(_:peerShare:role:)``
    /// takes its private half and leaves none behind. A reference, so a channel can hold it while it waits for the
    /// peer's share without a copy of the private key ever existing.
    public final class Ephemeral: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        /// The `KEY_SHARE` payload: our raw public key, ``LinkSeal/keyShareByteCount`` bytes.
        public let keyShare: [UInt8]
        private let privateKey: Lock<Curve25519.KeyAgreement.PrivateKey?>

        /// A fresh key from the system's secure generator: `Curve25519.KeyAgreement.PrivateKey()`, which draws from
        /// BoringSSL's `RAND_bytes` under swift-crypto on Linux and from CryptoKit's own generator on Apple platforms, as
        /// ``RatchetCrypto/generateKeyPair()`` does. Never from the mesh's seedable `random`: a key a test can predict is a
        /// link anyone can read.
        public convenience init() {
            self.init(Curve25519.KeyAgreement.PrivateKey())
        }

        /// The key for a fixed scalar, for the vectors (contract "Vectors": Alice `40…5f`, Bob `60…7f`). `nil` unless
        /// the scalar is 32 bytes.
        convenience init?(scalar: [UInt8]) {
            guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar) else {
                return nil
            }
            self.init(key)
        }

        private init(_ key: Curve25519.KeyAgreement.PrivateKey) {
            keyShare = Array(key.publicKey.rawRepresentation)
            privateKey = Lock(key)
        }

        /// The private half, taken once: every later call answers `nil`. Only ``LinkSeal/derive(_:peerShare:role:)`` calls it.
        func take() -> Curve25519.KeyAgreement.PrivateKey? {
            privateKey.withLock { key in
                let taken = key
                key = nil
                return taken
            }
        }

        /// No key bytes, public or private.
        public var description: String { "LinkSeal.Ephemeral" }
        /// As ``description``.
        public var debugDescription: String { description }
        /// No children, so reflection shows no byte.
        public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }
    }

    /// What one side of a sealed link derived: the two shares, the half that seals what it writes and the half that opens
    /// what it reads. Hand ``sealer`` to whatever writes the socket and keep ``opener`` where the records are read; drop
    /// the session itself once both are placed, so the shared secret goes with it.
    public struct Session: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        /// Both `KEY_SHARE` payloads, which the sealed PROOF's transcript binds (``LinkProof/Form/sealed(_:)``).
        public let shares: KeyShares
        /// Seals what this side writes, under its sending direction's key.
        public let sealer: LinkSealer
        /// Opens what this side reads, under the other direction's key.
        public let opener: LinkOpener
        /// The X25519 output, for the vectors alone.
        let sharedSecret: SymmetricKey
        /// The dialer-to-responder key, for the vectors alone.
        let dialerToResponder: SymmetricKey
        /// The responder-to-dialer key, for the vectors alone.
        let responderToDialer: SymmetricKey

        /// `ss`'s bytes (the vectors' `shared`). The vector tests alone read these three, through `@testable`, which
        /// `swiftlint analyze` (Sources only) does not see.
        var shared: [UInt8] { copiedBytes(sharedSecret) } // swiftlint:disable:this unused_declaration
        /// `kD2R`'s bytes (the vectors' `keyD2R`).
        var keyD2R: [UInt8] { copiedBytes(dialerToResponder) } // swiftlint:disable:this unused_declaration
        /// `kR2D`'s bytes (the vectors' `keyR2D`).
        var keyR2D: [UInt8] { copiedBytes(responderToDialer) } // swiftlint:disable:this unused_declaration

        /// No key bytes.
        public var description: String { "LinkSeal.Session" }
        /// As ``description``.
        public var debugDescription: String { description }
        /// No children, so reflection shows no byte.
        public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
    }

    /// The session `own` and the peer's `KEY_SHARE` payload derive for the side that plays `role` (contract §5), or the
    /// failed seal that refuses it: a share that is not 32 bytes, a low-order point (an all-zero `ss`), or an ephemeral
    /// that already derived once. Takes `own`'s private half whatever the outcome, so it never derives twice.
    public static func derive(_ own: Ephemeral, peerShare: [UInt8], role: LinkProof.Role) throws(Failure) -> Session {
        guard let privateKey = own.take() else {
            throw .spent
        }
        let ours = own.keyShare
        guard peerShare.count == keyShareByteCount,
            let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerShare),
            let shares = role == .dialer ? KeyShares(dialer: ours, responder: peerShare) : KeyShares(dialer: peerShare, responder: ours)
        else {
            throw .keyShareLength
        }
        // An exchange the library refuses outright counts as the zeros it would otherwise return, as `RatchetCrypto.dh`
        // reads it: either way the share gives no secret, which is when Tink throws.
        guard let secret = try? privateKey.sharedSecretFromKeyAgreement(with: theirs), !secret.isAllZero else {
            throw .lowOrderPoint
        }
        let shared = SymmetricKey(data: secret)
        let dialerToResponder = directionKey(shared, salt: shares.salt, info: infoDialerToResponder)
        let responderToDialer = directionKey(shared, salt: shares.salt, info: infoResponderToDialer)
        let (sending, receiving) = role == .dialer ? (dialerToResponder, responderToDialer) : (responderToDialer, dialerToResponder)
        return Session(
            shares: shares,
            sealer: LinkSealer(key: sending, counter: 0),
            opener: LinkOpener(key: receiving, counter: 0),
            sharedSecret: shared,
            dialerToResponder: dialerToResponder,
            responderToDialer: responderToDialer
        )
    }

    /// HKDF-SHA256 with Tink's argument order, the input key material then the salt (`RatchetCrypto.hkdf`).
    private static func directionKey(_ shared: SymmetricKey, salt: [UInt8], info: [UInt8]) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: shared, salt: salt, info: info, outputByteCount: keyByteCount)
    }

    // MARK: The frame, shared by both halves

    /// The `SEALED` record's tag. It must stay `LinkRecord.Tag.sealed`'s raw value (contract §3).
    static let sealedTag: UInt8 = 0x0B
    /// Neither half seals or opens a frame at this counter or past it (`LinkLane.kt:145`).
    static let counterLimit: UInt64 = 1 << 48
    /// The counter nonce's zero prefix, before `u64be(n)`.
    private static let noncePrefix = [UInt8](repeating: 0, count: noncePrefixByteCount)
    /// The nonce's 4 zero bytes, which with the 8-byte counter make GCM's 12.
    private static let noncePrefixByteCount = 4

    /// The 5 header bytes of a `SEALED` record whose payload is `payloadCount` bytes: the frame's AAD.
    static func header(payloadCount: Int) -> [UInt8] {
        [sealedTag] + RatchetCrypto.u32be(payloadCount)
    }

    /// Frame `counter`'s nonce, `00 00 00 00 ‖ u64be(counter)`.
    static func nonce(_ counter: UInt64) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: noncePrefix + RatchetCrypto.u64be(Int64(bitPattern: counter)))
    }
}

/// The half of a sealed link that seals what one side writes (contract §5), one `SEALED` frame per call, in the order the
/// frames reach the socket. Sendable, so the link manager can hand it to the radio's outbox on another thread: its
/// counter advances under a lock, so even a shared reference never seals two frames under one nonce. Seal at the moment a
/// frame's bytes are committed to the socket's order, after any queue that replaces or reorders records.
public final class LinkSealer: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The largest plaintext one frame takes (contract §3): a longer run of the inner stream is split across frames.
    public static let maxPlaintextBytes = 65_536
    /// What a frame adds to its plaintext: the 5-byte record header and the 16-byte tag.
    public static let overheadBytes = LinkRecord.headerBytes + LinkSeal.tagByteCount

    private struct State {
        var counter: UInt64
        var poisoned = false
    }

    private let key: SymmetricKey
    private let state: Lock<State>

    /// A sealer under `key` whose next frame is `counter`: ``LinkSeal/derive(_:peerShare:role:)``'s at 0, and a test's
    /// at any counter.
    init(key: SymmetricKey, counter: UInt64) {
        self.key = key
        state = Lock(State(counter: counter))
    }

    /// One whole `SEALED` record, `[0x0B][u32be len][ciphertext ‖ tag]` with `len = plaintext.count + 16`, sealed at the
    /// next counter, or `nil` for an empty plaintext, one over ``maxPlaintextBytes``, or the 2^48th frame. A `nil` is
    /// final: every later call answers `nil` too, and the caller closes the link.
    public func seal(_ plaintext: some Collection<UInt8>) -> [UInt8]? {
        let bytes = Array(plaintext)
        return state.withLock { current -> [UInt8]? in
            guard !current.poisoned, !bytes.isEmpty, bytes.count <= Self.maxPlaintextBytes,
                current.counter < LinkSeal.counterLimit
            else {
                current.poisoned = true
                return nil
            }
            let header = LinkSeal.header(payloadCount: bytes.count + LinkSeal.tagByteCount)
            guard let nonce = try? LinkSeal.nonce(current.counter),
                let box = try? AES.GCM.seal(bytes, using: key, nonce: nonce, authenticating: header)
            else {
                current.poisoned = true
                return nil
            }
            current.counter += 1
            return header + Array(box.ciphertext) + Array(box.tag)
        }
    }

    /// No key bytes and no counter.
    public var description: String { "LinkSealer" }
    /// As ``description``.
    public var debugDescription: String { description }
    /// No children, so reflection shows no byte.
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }
}

/// The half of a sealed link that opens what the other side wrote (contract §5): each `SEALED` frame at the next counter,
/// in the order it was read. The first frame that fails to open poisons it, so a link that saw one bad frame reads no
/// more, and the caller closes it.
public final class LinkOpener: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// A `SEALED` record's payload length, read from its header (contract §3): a plaintext of 1 to 65,536 bytes and the tag.
    public static let payloadByteRange = (1 + LinkSeal.tagByteCount)...(LinkSealer.maxPlaintextBytes + LinkSeal.tagByteCount)

    private struct State {
        var counter: UInt64
        var poisoned = false
    }

    private let key: SymmetricKey
    private let state: Lock<State>

    /// An opener under `key` whose next frame is `counter`: ``LinkSeal/derive(_:peerShare:role:)``'s at 0, and a test's
    /// at any counter.
    init(key: SymmetricKey, counter: UInt64) {
        self.key = key
        state = Lock(State(counter: counter))
    }

    /// The plaintext of a `SEALED` record's `sealedPayload` (`ciphertext ‖ tag`, the record's header stripped), opened at
    /// the next counter under the AAD rebuilt from tag `0x0B` and the payload's length. `nil` when it fails: a payload
    /// outside ``payloadByteRange``, a frame sealed at another counter, under another key or with any bit changed, or the
    /// 2^48th frame. A `nil` is final.
    public func open(sealedPayload: [UInt8]) -> [UInt8]? {
        state.withLock { current -> [UInt8]? in
            guard !current.poisoned, Self.payloadByteRange.contains(sealedPayload.count), current.counter < LinkSeal.counterLimit,
                let nonce = try? LinkSeal.nonce(current.counter),
                let box = try? AES.GCM.SealedBox(
                    nonce: nonce,
                    ciphertext: sealedPayload.dropLast(LinkSeal.tagByteCount),
                    tag: sealedPayload.suffix(LinkSeal.tagByteCount)
                ),
                let plaintext = try? AES.GCM.open(box, using: key, authenticating: LinkSeal.header(payloadCount: sealedPayload.count))
            else {
                current.poisoned = true
                return nil
            }
            current.counter += 1
            return Array(plaintext)
        }
    }

    /// No key bytes and no counter.
    public var description: String { "LinkOpener" }
    /// As ``description``.
    public var debugDescription: String { description }
    /// No children, so reflection shows no byte.
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }
}
