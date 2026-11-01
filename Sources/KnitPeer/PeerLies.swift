import Foundation
import KnitControl
public import KnitMesh
public import KnitStore
public import KnitWire

/// What `knit-peer run --lying` wraps, a trial's switch (`door-cap-lying-peers`, ADR 2026-10.r88m): the radio, the blob
/// store and our own profile's store, each honest until a control command sets one of its lies. ``PeerNode`` takes them
/// and answers the six commands; a node without them refuses each one.
public struct PeerLyingParts: Sendable {
    /// The radio, outermost over the host's and any flood.
    public let radio: LyingRadio
    /// The blobs, which serve junk or keep a photo back.
    public let blobs: LyingBlobStore
    /// Our profile as the engine reads it, which can name another's photo.
    public let profile: ForgingOwnProfileStore
    /// Where the marker that a profile lie may be on air is kept (``ProfileLies``).
    public let stateDirectory: String

    /// The parts as given.
    public init(radio: LyingRadio, blobs: LyingBlobStore, profile: ForgingOwnProfileStore, stateDirectory: String) {
        self.radio = radio
        self.blobs = blobs
        self.profile = profile
        self.stateDirectory = stateDirectory
    }

    /// The parts over `radio` and `profileStore`, and the memory stores the node runs on, built as `knit-peer` builds
    /// them: the profile's store wrapped first, so the memory stores' unit checkpoints it through the wrapper, and the
    /// blobs wrapped over those stores, so the unit still covers the store under them.
    public static func wrapping(
        _ radio: any Radio,
        profileStore: any OwnProfileStore & Checkpointing,
        localId: NodeId,
        stateDirectory: String,
        random: some RandomNumberGenerator & Sendable,
        log: any KnitLog = SilentLog()
    ) -> (parts: Self, stores: MeshStores) {
        let forging = ForgingOwnProfileStore(wrapping: profileStore)
        let wrapped = LyingBlobStore.stores(over: .inMemory(ownProfileStore: forging))
        let lying = LyingRadio(wrapping: radio, localId: localId, profile: forging, random: random, log: log)
        return (Self(radio: lying, blobs: wrapped.blobs, profile: forging, stateDirectory: stateDirectory), wrapped.stores)
    }
}

/// The six lying commands, answered by ``PeerNode`` ahead of ``MeshControl``, which never hears of them:
///
/// - `{"cmd":"lie-blobhas","hash":H,"size":N}`, `{"cmd":"lie-blobhas","hash":H,"clear":true}`
/// - `{"cmd":"junk","hash":H,"bytes":N,"declare":D}` (`declare` optional), `{"cmd":"junk","hash":H,"clear":true}`
/// - `{"cmd":"advertise-photo","hash":H}`, `{"cmd":"advertise-photo","clear":true}`
/// - `{"cmd":"pad-profile","signedBytes":N}`, `{"cmd":"pad-profile","clear":true}`
/// - `{"cmd":"ask-blob","hash":H,"peer":NODE}`, a one-shot
/// - `{"cmd":"impostor","legacy":B,"claim":NODE,"dial":NODE}` (each optional), `{"cmd":"impostor","clear":true}`: the link
///   manager's ``LinkManager/Impostor``, for the links that open from then on (the `link-hello-proof` trial's T4 and T5)
///
/// Each reply carries `lying`, what ``status()`` answers, beside its own fields.
internal final class PeerLies: Sendable {
    /// The commands' names.
    static let names: Set<String> = ["lie-blobhas", "junk", "advertise-photo", "pad-profile", "ask-blob", "impostor"]
    /// What each answers on a node run without `--lying`.
    static let refusal = "lying switches need knit-peer run --lying"

    /// A line's command and tag, which every command line has.
    struct Head: Decodable {
        var cmd: String
        var tag: String?

        static func parse(_ line: String) -> Self? {
            try? JSONDecoder().decode(Self.self, from: Data(line.utf8))
        }
    }

    /// One lying command's fields.
    struct Request: Decodable {
        var cmd: String
        var hash: String?
        var size: Int64?
        var bytes: Int?
        var declare: Int?
        var signedBytes: Int?
        var peer: String?
        var clear: Bool? // swiftlint:disable:this discouraged_optional_boolean
        var legacy: Bool? // swiftlint:disable:this discouraged_optional_boolean
        var claim: String?
        var dial: String?

        /// The line's fields, or `nil` when it is not an object of them.
        static func parse(_ line: String) -> Self? {
            try? JSONDecoder().decode(Self.self, from: Data(line.utf8))
        }

        var clears: Bool { clear ?? false }
    }

    /// Why a command did not take: the reply's `error`.
    struct Refusal: Error {
        let message: String

        static func missing(_ field: String) -> Self {
            Self(message: "missing \(field)")
        }

        static func invalid(_ field: String) -> Self {
            Self(message: "not a valid \(field)")
        }
    }

    let parts: PeerLyingParts
    let profile: ProfileLies
    let mesh: Mesh

    init(parts: PeerLyingParts, profile: ProfileLies, mesh: Mesh) {
        self.parts = parts
        self.profile = profile
        self.mesh = mesh
    }

    /// The reply's fields for `request`, `lying` among them, or why it did not take.
    func answer(_ request: Request) async -> Result<[String: JSONValue], Refusal> {
        do {
            var fields: [String: JSONValue]
            switch request.cmd {
            case "lie-blobhas":
                fields = try lieBlobHas(request)
            case "junk":
                fields = try junk(request)
            case "advertise-photo":
                fields = try await advertisePhoto(request)
            case "pad-profile":
                fields = try await padProfile(request)
            case "impostor":
                fields = try await impostor(request)
            default:
                fields = try askBlob(request)
            }
            fields["lying"] = await status()
            return .success(fields)
        } catch let refusal as Refusal {
            return .failure(refusal)
        } catch {
            return .failure(Refusal(message: "\(error)"))
        }
    }

    /// What is set and what it has done: `status`'s `lying`.
    func status() async -> JSONValue {
        let counts = parts.radio.counts
        let junkBytes = parts.blobs.junk
        let declared = parts.radio.junkHeaders
        let junk = Set(junkBytes.keys).union(declared.keys).reduce(into: [String: JSONValue]()) { fields, hash in
            let declare = declared[hash].flatMap(\.self)
            fields[hash.string] = [
                "bytes": junkBytes[hash].map { .int(Int64($0)) } ?? .null, "declare": declare.map { .int(Int64($0)) } ?? .null,
            ]
        }
        let padded = await profile.paddedProfile
        let impostor = await mesh.impostor
        return [
            "impostor": [
                "legacy": .bool(impostor.legacy), "claim": .text(impostor.claimedId?.string), "dial": .text(impostor.dials?.string),
            ],
            "blobhas": .object(parts.radio.blobHasLies.reduce(into: [:]) { $0[$1.key.string] = .int($1.value) }),
            "junk": .object(junk),
            "advertisedPhoto": .text(parts.profile.advertisedPhoto?.string),
            "paddedProfile": padded.map { ["id": .string($0.id), "signedBytes": .int(Int64($0.signedBytes))] } ?? .null,
            "counts": [
                "blobhasRewritten": .int(Int64(counts.blobhasRewritten)),
                "junkHeadersRewritten": .int(Int64(counts.junkHeadersRewritten)),
                "junkBytesServed": .int(parts.blobs.junkBytesServed),
                "advertisedPhotoPushed": .int(Int64(counts.advertisedPhotoPushed)),
                "forgedProfilesWritten": Self.byNode(counts.forgedProfilesWritten),
                "blobAsksSent": Self.byNode(counts.blobAsksSent),
            ],
        ]
    }

    // MARK: Commands

    private func lieBlobHas(_ request: Request) throws(Refusal) -> [String: JSONValue] {
        let hash = try Self.hash(request)
        if request.clears {
            parts.radio.clearBlobHasLie(hash)
            return [:]
        }
        guard let size = request.size else {
            throw .missing("size")
        }
        guard size >= 0 else {
            throw .invalid("size")
        }
        parts.radio.setBlobHasLie(hash, size: size)
        return [:]
    }

    private func junk(_ request: Request) throws(Refusal) -> [String: JSONValue] {
        let hash = try Self.hash(request)
        if request.clears {
            parts.blobs.clearJunk(hash)
            parts.radio.clearJunkHeader(hash)
            return [:]
        }
        guard let bytes = request.bytes else {
            throw .missing("bytes")
        }
        if let declare = request.declare, declare < 0 {
            throw .invalid("declare")
        }
        do {
            try parts.blobs.setJunk(hash, bytes: bytes)
        } catch {
            throw Refusal(message: error.description)
        }
        parts.radio.setJunkHeader(hash, declare: request.declare)
        return [:]
    }

    private func advertisePhoto(_ request: Request) async throws -> [String: JSONValue] {
        if request.clears {
            try await profile.clearAdvertisedPhoto()
        } else {
            try await profile.setAdvertisedPhoto(Self.hash(request))
        }
        return [:]
    }

    /// Forges the profile and injects it; a clear stops the injection before the honest edit goes out.
    private func padProfile(_ request: Request) async throws -> [String: JSONValue] {
        if request.clears {
            parts.radio.setPaddedProfile(nil)
            try await profile.clearPad()
            return [:]
        }
        guard let signedBytes = request.signedBytes else {
            throw Refusal.missing("signedBytes")
        }
        let forged = try await profile.pad(signedBytes: signedBytes)
        let written = parts.radio.setPaddedProfile(LyingRadio.Forge(wire: forged.wire, id: forged.id))
        return ["id": .string(forged.id), "signedBytes": .int(Int64(forged.signedBytes)), "written": .int(Int64(written))]
    }

    /// Sets the link manager's impostor, or clears it back to honest: a legacy HELLO, a claimed id, a peer dialed whatever
    /// the order. What is not given is honest.
    private func impostor(_ request: Request) async throws(Refusal) -> [String: JSONValue] {
        var impostor = LinkManager.Impostor()
        if !request.clears {
            impostor.legacy = request.legacy ?? false
            impostor.claimedId = try request.claim.map { text throws(Refusal) in try Self.node(text) }
            impostor.dials = try request.dial.map { text throws(Refusal) in try Self.node(text) }
        }
        await mesh.setImpostor(impostor)
        return [:]
    }

    private static func node(_ text: String) throws(Refusal) -> NodeId {
        guard let node = NodeId(text) else {
            throw Refusal(message: "not a node id: \(text)")
        }
        return node
    }

    private func askBlob(_ request: Request) throws(Refusal) -> [String: JSONValue] {
        let hash = try Self.hash(request)
        guard let text = request.peer else {
            throw .missing("peer")
        }
        guard let peer = NodeId(text) else {
            throw Refusal(message: "not a node id: \(text)")
        }
        let id = parts.radio.askBlob(hash, of: peer)
        return ["sent": .bool(id != nil), "id": .text(id)]
    }

    private static func hash(_ request: Request) throws(Refusal) -> BlobHash {
        guard let text = request.hash else {
            throw .missing("hash")
        }
        guard let hash = BlobHash(text) else {
            throw .invalid("hash")
        }
        return hash
    }

    private static func byNode(_ counts: [NodeId: Int]) -> JSONValue {
        .object(counts.reduce(into: [:]) { $0[$1.key.string] = .int(Int64($1.value)) })
    }
}
