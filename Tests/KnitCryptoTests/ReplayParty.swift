import Crypto
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitCrypto

/// One side of a ratchet transcript: a fixed identity, the prekeys it holds, the prekey it pins for its peer, an engine
/// on its draw plan, and the rows it keeps for its peer (`TranscriptParty`, knit-next's `RatchetTranscript.kt:242-301`).
final class ReplayParty {
    let name: String
    let identity: IdentityKeys
    let holds: [SignedPrekey]
    /// The prekey it seals against, by peer name, with the prekey's name.
    let pins: [String: (name: String, prekey: PeerPrekey)]
    let draws: DrawPlan
    let engine: RatchetEngine
    var rows: [String: RatchetRows] = [:]
    /// When it last adopted a replacement from each peer: `RatchetSessions`' in-memory floor (`RatchetSessions.kt:103-104`).
    var lastReplacementAt: [String: Int64] = [:]

    var nodeId: NodeId { identity.nodeId }

    init(_ name: String, in transcript: RatchetVectors.Transcript, file: RatchetVectors.File) throws {
        let entry = try #require(transcript.parties[name])
        self.name = name
        identity = try Self.identity(entry.identity, file: file)
        #expect(identity.nodeId.string == entry.nodeId)
        holds = try entry.holdsPrekeys.map { prekeyName in try Self.prekey(prekeyName, file: file) }
        var pinned: [String: (name: String, prekey: PeerPrekey)] = [:]
        for (peer, prekeyName) in entry.pins {
            let held = try Self.prekey(prekeyName, file: file)
            let owner = try #require(file.profiles.prekeys.first { $0.name == prekeyName }).owner
            let bundle = try Self.identity(owner, file: file).bundle
            pinned[peer] = (prekeyName, try #require(PeerPrekey(verifying: held.info, signedBy: bundle)))
        }
        pins = pinned
        let plan = DrawPlan(owner: name, plan: transcript.draws[name] ?? [])
        draws = plan
        engine = RatchetEngine(keyPair: { plan.keyPair() }, iv: { plan.iv() })
    }

    /// The prekey this party holds for an init's `pkid`, as `IdentityKeyStore.prekeyPrivFor` finds it.
    func prekey(id: Int) -> SignedPrekey? {
        holds.first { $0.id == id }
    }

    private static func identity(_ name: String, file: RatchetVectors.File) throws -> IdentityKeys {
        let entry = try #require(file.identities[name])
        return try #require(IdentityKeys(signingSeed: hexBytes(entry.signingSeed), agreementScalar: hexBytes(entry.agreementScalar)))
    }

    /// A vector prekey whose public key and owner's signature check out. Tink signed it, so it is verified, never
    /// compared.
    private static func prekey(_ name: String, file: RatchetVectors.File) throws -> SignedPrekey {
        let vector = try #require(file.profiles.prekeys.first { $0.name == name })
        let pair = try RatchetCrypto.KeyPair(privateKey: hexBytes(vector.priv))
        #expect(hexString(pair.publicKey) == vector.pub)
        let signature = hexBytes(vector.sig)
        let owner = try identity(vector.owner, file: file)
        #expect(owner.bundle.isValidSignature(signature, for: RatchetCrypto.spkSigningBytes(id: vector.id, pub: pair.publicKey)))
        return SignedPrekey(
            id: vector.id,
            privateKey: pair.privateKey,
            publicKey: pair.publicKey,
            signature: signature,
            createdAt: vector.createdAt
        )
    }
}

/// One party's injected values, popped in order (`DrawSource`, `RatchetTranscript.kt:66-106`): a draw of the wrong
/// kind, or one past the plan, is a failed expectation, so a change to the engine's draw order cannot pass.
final class DrawPlan: Sendable {
    let owner: String
    private let plan: [RatchetVectors.TranscriptDraw]
    private let taken = Lock(0)

    init(owner: String, plan: [RatchetVectors.TranscriptDraw]) {
        self.owner = owner
        self.plan = plan
    }

    /// How many draws the engine has taken.
    var count: Int { taken.withLock { $0 } }

    /// Whether the plan was used up exactly.
    var spent: Bool { count == plan.count }

    func keyPair() -> RatchetCrypto.KeyPair {
        guard let draw = next("keyPair"), let priv = draw.priv, let pair = try? RatchetCrypto.KeyPair(privateKey: hexBytes(priv)) else {
            return RatchetCrypto.generateKeyPair()
        }
        #expect(hexString(pair.publicKey) == draw.pub, "\(owner)'s draw \(draw.index) derives the public key it lists")
        return pair
    }

    func iv() -> [UInt8] {
        guard let draw = next("iv"), let iv = draw.iv else {
            return RatchetCrypto.randomNonce()
        }
        return hexBytes(iv)
    }

    private func next(_ kind: String) -> RatchetVectors.TranscriptDraw? {
        let index = taken.withLock { taken in
            defer { taken += 1 }
            return taken
        }
        guard index < plan.count else {
            Issue.record("\(owner) drew more than its plan's \(plan.count) draws")
            return nil
        }
        guard plan[index].kind == kind else {
            Issue.record("\(owner) drew a \(kind) where its plan has a \(plan[index].kind) (draw \(index))")
            return nil
        }
        return plan[index]
    }
}

/// Bytes as lowercase hex.
func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { byte in
        let digits = String(byte, radix: 16)
        return digits.count == 1 ? "0" + digits : digits
    }
    .joined()
}

/// SHA-256 as lowercase hex, as the file digests a secret.
func sha256Hex(_ bytes: [UInt8]) -> String {
    hexString(Array(SHA256.hash(data: bytes)))
}

/// A root tag as the file writes it, Kotlin's `"%016x".format(tag)`: a negative tag's two's complement bits.
func tagHex(_ tag: Int64) -> String {
    let digits = String(UInt64(bitPattern: tag), radix: 16)
    return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
}
