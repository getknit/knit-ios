public import KnitCrypto
public import KnitStore
public import KnitWire

/// knit-peer's `pad-profile` forge, a trial's switch: our own profile frame, padded so its `signed` is exactly the length
/// asked for, and signed once. The trial (`door-cap-lying-peers`, case 4) sends it on air to watch a far end's door take a
/// profile at the cap (8,192 bytes, kept, its status cut) and one byte over it (refused before verify, with no pin, proof
/// or custody row; ADR 2026-10.r88m, "The door").
///
/// The frame is what the engine would sign for a new edit of what it already published, but for the status:
/// - its payload is our current profile frame's, read from custody, or from the frame our profile store keeps when custody's
///   quota has evicted the row (ADR 2026-11.xfcq), every field as the engine emitted it, with the status
///   padded by one printable ASCII letter (no whitespace, so `TextLimits.normalizeSingleLine` on the far end keeps it) and
///   the version moved to `now`;
/// - its stamp is fixed before the padding is searched: `publishedAt = max(now, own.publishedAt + 1)`, as
///   `MeshEngine.publishEdit` moves it, the id `FrameId.profileId(sender:publishedAt:)` and `sentAt` that same stamp, the
///   one shape `FrameId.admits` lets through;
/// - it is signed once, as `MeshEngine.sign` signs (`relay` on, the default TTL), and the caller sends those bytes on
///   every link, since CryptoKit's Ed25519 signatures are randomized and an id names one set of bytes.
///
/// The forge never saves anything: our profile store keeps our real version and stamp. Any later honest edit moves the
/// version to `max(now', version + 1)`, which beats the forge's `now` once the clock has moved past it, so the forge
/// refuses unless our version is already below `now`. That the clock moves is the caller's to check
/// (``ProfileLies``).
public enum ProfileForge {
    /// The letter the status is padded with: printable ASCII, one UTF-16 unit and one UTF-8 byte, never whitespace.
    public static let paddingLetter: Character = "x"

    /// Why no frame was forged.
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        /// Our version is not below the wall clock, so the forge's `version = now` would not beat it.
        case versionNotBehindClock(version: Int64, now: Int64)
        /// Neither custody nor the kept frame holds our current profile's id: there is nothing to forge from.
        case noProfileInCustody(id: String)
        /// The frame held under that id is not a profile of ours that decodes.
        case unreadableProfile(id: String)
        /// No padding makes `signed` exactly `signedBytes` long: the shortest forge is longer, or a CBOR length header
        /// grows by a byte across it.
        case unreachableLength(signedBytes: Int)
        /// The key refused to sign.
        case signing

        public var description: String {
            switch self {
            case .versionNotBehindClock(let version, let now):
                "our profile's version \(version) is not below the clock \(now); try again once the clock passes it"
            case .noProfileInCustody(let id):
                "neither custody nor the kept frame holds our profile \(id)"
            case .unreadableProfile(let id):
                "the frame held as \(id) is not our profile"
            case .unreachableLength(let signedBytes):
                "no padding of our profile's status makes its signed bytes exactly \(signedBytes) long"
            case .signing:
                "the identity refused to sign the forged profile"
            }
        }
    }

    /// A forged profile frame and the clocks it carries.
    public struct Forged: Sendable, Equatable {
        /// The signed frame, sent as it is on every link.
        public let wire: WireEnvelope
        /// Its id, `FrameId.profileId(sender:publishedAt:)` of our node and ``publishedAt``.
        public let id: String
        /// The version the payload carries, `now` when forged.
        public let version: Int64
        /// Its publish stamp, the envelope's `sentAt`.
        public let publishedAt: Int64

        /// The length of the signed bytes, the length asked for.
        public var signedBytes: Int { wire.signed.count }
    }

    /// Our profile as `own` names it, read from `custody`, or from `kept`, our profile store's kept frame, when custody holds
    /// no row under its id, padded to exactly `signedBytes` of `signed` and signed by `identity` at the wall clock `now`. A
    /// kept frame is read only under that id and only when its signature verifies against `identity`.
    public static func forge( // swiftlint:disable:this function_parameter_count - custody and the kept frame are two inputs
        signedBytes: Int, own: OwnProfile, custody: any CustodyStore, kept: KeptProfileFrame, identity: IdentityKeys, now: Int64
    ) throws(Refusal) -> Forged {
        guard own.version < now else {
            throw .versionNotBehindClock(version: own.version, now: now)
        }
        let sender = identity.nodeId.string
        let currentId = FrameId.profileId(sender: sender, publishedAt: own.publishedAt)
        guard let current = custody.frame(currentId, now: now)?.envelope ?? keptEnvelope(kept, id: currentId, identity: identity) else {
            throw .noProfileInCustody(id: currentId)
        }
        guard current.type == .profile, current.senderId.utf8.elementsEqual(sender.utf8),
            var content = try? ProfileContent(decoding: current.payload)
        else {
            throw .unreadableProfile(id: currentId)
        }
        let publishedAt = max(now, own.publishedAt + 1)
        content.version = now
        let status = content.status
        let envelope = { (padding: Int) -> RelayEnvelope in
            var padded = content
            padded.status = status + String(repeating: paddingLetter, count: padding)
            return RelayEnvelope(
                type: .profile,
                id: FrameId.profileId(sender: sender, publishedAt: publishedAt),
                senderId: sender,
                sentAt: publishedAt,
                payload: padded.encoded
            )
        }
        guard let padding = padding(reaching: signedBytes, by: { envelope($0).encoded.count }) else {
            throw .unreachableLength(signedBytes: signedBytes)
        }
        let forged = envelope(padding)
        let signed = forged.encoded
        let sig: [UInt8]
        do {
            sig = try identity.signature(for: signed)
        } catch {
            throw .signing
        }
        return Forged(wire: WireEnvelope(relay: true, sig: sig, signed: signed), id: forged.id, version: now, publishedAt: publishedAt)
    }

    /// The kept frame's envelope when it is the one under `id` and signed by `identity`, else `nil`.
    private static func keptEnvelope(_ kept: KeptProfileFrame, id: String, identity: IdentityKeys) -> RelayEnvelope? {
        guard case .kept(let wire) = kept, identity.bundle.isValidSignature(wire.sig, for: wire.signed),
            let envelope = try? RelayEnvelope(decoding: wire.signed), ExactKey(envelope.id) == ExactKey(id)
        else {
            return nil
        }
        return envelope
    }

    /// The padding whose envelope is exactly `target` bytes long, or `nil` for none. The length grows with the padding,
    /// one byte a letter but where a CBOR length header widens, so the search finds the shortest padding that reaches
    /// `target` and keeps it only if it lands there exactly.
    private static func padding(reaching target: Int, by length: (Int) -> Int) -> Int? {
        guard length(0) <= target else {
            return nil
        }
        var low = 0
        var high = target
        while low < high {
            let middle = low + (high - low) >> 1
            if length(middle) < target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return length(low) == target ? low : nil
    }
}
