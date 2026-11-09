import Crypto
import KnitTestSupport
import KnitWire

@testable import KnitCrypto

/// Carol's sealed links for `ios-emitted-v1.json` (`link.seal`, the `link-seal` contract's "Vectors"; knit-next #286): she
/// dials Alice, and Alice dials her, with Carol's ephemeral scalar `80..9f` and nonce `20..2f` and Alice's `a0..bf` and
/// `30..3f` in both. Every HELLO carries caps `140009`, keyed-v1's `link.seal` convention (the vectors' `0x9` with
/// ``Capabilities/linkProof`` and ``Capabilities/linkSeal``), so the bytes never follow `Capabilities.local`.
///
/// Everything but Carol's PROOF is deterministic and is rebuilt byte for byte. CryptoKit and swift-crypto randomize
/// Ed25519, so her PROOF, and the frame it is sealed in, are made once and kept while they still open and verify.
enum EmittedLinkSeals {
    /// The HELLOs' capabilities: keyed-v1's `link.seal` convention.
    static let capabilities = Capabilities(rawValue: 0x140009)
    static let carolScalar = (0x80...0x9F).map { UInt8($0) }
    static let aliceScalar = (0xA0...0xBF).map { UInt8($0) }
    /// The counter of Carol's HELLO frame in her direction, and of her PROOF frame after it.
    static let helloCounter: UInt64 = 0
    static let proofCounter: UInt64 = 1
    static let about =
        "Carol's sealed links (link-seal, knit-next #286). carolDialsAlice: Carol dials Alice, Carol's ephemeral scalar "
        + "80..9f and nonce 20..2f, Alice's a0..bf and 30..3f; Carol's sealed HELLO (counter 0, keyD2R) and her dialer "
        + "PROOF (role 1, counter 1). aliceDialsCarol: Alice dials Carol with the same keys and nonces in the other roles; "
        + "Carol's sealed reply HELLO (counter 0, keyR2D) and her responder PROOF (role 2, counter 1). Every HELLO carries "
        + "caps 140009, as keyed-v1's link.seal does. Each entry gives both KEY_SHAREs with their scalars, shared, keyD2R, "
        + "keyR2D, both HELLO payloads and the v2 transcript Carol signed; all but the PROOF are deterministic. CryptoKit "
        + "randomizes Ed25519: open the PROOF frame and verify its signature, never compare it."

    /// One link's fixed inputs.
    struct Case {
        let name: String
        let dialer: String
        let responder: String
        /// Carol's role on this link.
        let role: LinkProof.Role
        let dialerScalar: [UInt8]
        let responderScalar: [UInt8]
        let helloDialer: Hello
        let helloResponder: Hello

        /// The direction Carol writes in, by the entry's key name.
        var carolKey: String { role == .dialer ? "keyD2R" : "keyR2D" }
        var carolHello: Hello { role == .dialer ? helloDialer : helloResponder }
    }

    static func cases(carol: IdentityKeys, alice: IdentityKeys) -> [Case] {
        let carolHello = Hello(nodeId: carol.nodeId.string, capabilities: capabilities, nonce: EmittedLinkProofs.carolNonce)
        let aliceHello = Hello(nodeId: alice.nodeId.string, capabilities: capabilities, nonce: EmittedLinkProofs.aliceNonce)
        return [
            Case(
                name: "carolDialsAlice",
                dialer: "carol",
                responder: "alice",
                role: .dialer,
                dialerScalar: carolScalar,
                responderScalar: aliceScalar,
                helloDialer: carolHello,
                helloResponder: aliceHello),
            Case(
                name: "aliceDialsCarol",
                dialer: "alice",
                responder: "carol",
                role: .responder,
                dialerScalar: aliceScalar,
                responderScalar: carolScalar,
                helloDialer: aliceHello,
                helloResponder: carolHello),
        ]
    }

    /// What both ends of `link` derive: each side from its own scalar and the other's share, which must agree.
    private struct Exchange {
        let session: LinkSeal.Session

        init?(_ link: Case) {
            guard let dialer = LinkSeal.Ephemeral(scalar: link.dialerScalar),
                let responder = LinkSeal.Ephemeral(scalar: link.responderScalar)
            else {
                return nil
            }
            let responderShare = responder.keyShare
            guard let dialing = try? LinkSeal.derive(dialer, peerShare: responderShare, role: .dialer),
                let answering = try? LinkSeal.derive(responder, peerShare: dialing.shares.dialer, role: .responder),
                dialing.shares == answering.shares, dialing.shared == answering.shared, dialing.keyD2R == answering.keyD2R,
                dialing.keyR2D == answering.keyR2D
            else {
                return nil
            }
            session = dialing
        }

        func key(_ name: String) -> SymmetricKey? {
            switch name {
            case "keyD2R":
                SymmetricKey(data: session.keyD2R)
            case "keyR2D":
                SymmetricKey(data: session.keyR2D)
            default:
                nil
            }
        }
    }

    private static func keyShare(scalar: [UInt8], share: [UInt8]) -> VectorLink.Seal.KeyShare? {
        LinkRecord(.keyShare, payload: share).encoded.map { VectorLink.Seal.KeyShare(scalar: Hex.encode(scalar), record: Hex.encode($0)) }
    }

    private static func text(_ hello: Hello) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: hello.payload, as: UTF8.self)
    }

    private static func transcript(_ link: Case, _ exchange: Exchange) -> [UInt8] {
        LinkProof.transcript(
            form: .sealed(exchange.session.shares),
            signer: link.role,
            dialerHello: link.helloDialer.payload,
            responderHello: link.helloResponder.payload)
    }

    /// `link`'s entry carrying `proof`: every field but the proof rebuilt from the fixed inputs.
    private static func entry(_ link: Case, proof: VectorLink.Seal.SealedProof) -> EmittedLinkSealCase? {
        guard let exchange = Exchange(link), let key = exchange.key(link.carolKey),
            let dialerShare = keyShare(scalar: link.dialerScalar, share: exchange.session.shares.dialer),
            let responderShare = keyShare(scalar: link.responderScalar, share: exchange.session.shares.responder),
            let helloRecord = LinkRecord(.hello, payload: link.carolHello.payload).encoded,
            let helloFrame = LinkSealer(key: key, counter: helloCounter).seal(helloRecord)
        else {
            return nil
        }
        return EmittedLinkSealCase(
            dialer: link.dialer,
            responder: link.responder,
            signer: "carol",
            role: link.role.rawValue,
            capabilities: capabilities.hex,
            keyShareDialer: dialerShare,
            keyShareResponder: responderShare,
            shared: Hex.encode(exchange.session.shared),
            keyD2R: Hex.encode(exchange.session.keyD2R),
            keyR2D: Hex.encode(exchange.session.keyR2D),
            helloDialer: text(link.helloDialer),
            helloResponder: text(link.helloResponder),
            helloSealed: VectorLink.Seal.SealedHello(
                payload: text(link.carolHello), key: link.carolKey, counter: helloCounter, frame: Hex.encode(helloFrame)),
            transcript: Hex.encode(transcript(link, exchange)),
            proof: proof)
    }

    /// A fresh entry for `link`, Carol signing once.
    static func entry(_ link: Case, carol: IdentityKeys) throws -> EmittedLinkSealCase? {
        guard let exchange = Exchange(link), let key = exchange.key(link.carolKey) else {
            return nil
        }
        let payload = try LinkProof.payload(
            keys: carol,
            form: .sealed(exchange.session.shares),
            signer: link.role,
            dialerHello: link.helloDialer.payload,
            responderHello: link.helloResponder.payload)
        guard let record = LinkRecord(.proof, payload: payload).encoded,
            let frame = LinkSealer(key: key, counter: proofCounter).seal(record)
        else {
            return nil
        }
        let proof = VectorLink.Seal.SealedProof(
            signer: "carol", record: Hex.encode(record), key: link.carolKey, counter: proofCounter, frame: Hex.encode(frame))
        return entry(link, proof: proof)
    }

    /// Whether a committed entry is still what Carol would send on `link`: every deterministic field is rebuilt byte for
    /// byte, and her PROOF frame opens at counter 1 under her direction's key to one whole tag-8 record with her keys,
    /// whose signature verifies for her role over the v2 transcript.
    static func isCurrent(_ committed: EmittedLinkSealCase, _ link: Case, carol: IdentityKeys) -> Bool {
        guard entry(link, proof: committed.proof) == committed, committed.proof.signer == "carol", let exchange = Exchange(link),
            let key = exchange.key(link.carolKey), committed.proof.key == link.carolKey, committed.proof.counter == proofCounter,
            let frame = Hex.decode(committed.proof.frame)
        else {
            return false
        }
        var frames = LinkRecordReader()
        frames.append(frame)
        guard let sealed = try? frames.next(), sealed.tag == .sealed, !frames.hasPartialRecord,
            let opened = LinkOpener(key: key, counter: proofCounter).open(sealedPayload: sealed.payload),
            Hex.encode(opened) == committed.proof.record
        else {
            return false
        }
        var records = LinkRecordReader()
        records.append(opened)
        guard let proof = try? records.next(), proof.tag == .proof, !records.hasPartialRecord,
            Array(proof.payload.prefix(LinkProof.keysByteCount)) == carol.bundle.signingKey + carol.bundle.agreementKey
        else {
            return false
        }
        let outcome = LinkProof.verify(
            proof.payload,
            claimedId: carol.nodeId,
            form: .sealed(exchange.session.shares),
            signer: link.role,
            dialerHello: link.helloDialer.payload,
            responderHello: link.helloResponder.payload)
        return outcome == .proven(carol.bundle)
    }

    /// The section, keeping each committed proof while it is still current.
    static func section(carol: IdentityKeys, alice: IdentityKeys, committed: EmittedLinkSeal?) throws -> EmittedLinkSeal? {
        var entries: [String: EmittedLinkSealCase] = [:]
        for link in cases(carol: carol, alice: alice) {
            let kept = committed.map { link.name == "carolDialsAlice" ? $0.carolDialsAlice : $0.aliceDialsCarol }
            if let kept, isCurrent(kept, link, carol: carol) {
                entries[link.name] = kept
            } else {
                entries[link.name] = try entry(link, carol: carol)
            }
        }
        guard let dialing = entries["carolDialsAlice"], let answering = entries["aliceDialsCarol"] else {
            return nil
        }
        return EmittedLinkSeal(about: about, carolDialsAlice: dialing, aliceDialsCarol: answering)
    }
}
