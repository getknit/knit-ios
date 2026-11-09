import KnitCrypto
import KnitTestSupport
import KnitWire

/// Carol's link proofs for `ios-emitted-v1.json` (`link-hello-proof`, the contract's "Vectors"): she dials Alice, and Alice
/// dials her, with Carol's nonce `20..2f` and Alice's `30..3f` in both. Every HELLO carries caps `40009`, keyed-v1's
/// convention (the vectors' own `0x9` with ``Capabilities/linkProof``), so the bytes never follow `Capabilities.local`.
///
/// CryptoKit randomizes Ed25519, so a proof is signed once and kept while it still verifies; a check compares the HELLOs,
/// the transcript, the record's header and Carol's keys, and verifies the signature.
enum EmittedLinkProofs {
    /// The HELLOs' capabilities: keyed-v1's link-proof convention.
    static let capabilities = Capabilities(rawValue: 0x40009)
    static let carolNonce = (0x20..<0x30).map { UInt8($0) }
    static let aliceNonce = (0x30..<0x40).map { UInt8($0) }
    static let about =
        "Carol's link proofs (link-hello-proof). carolDialsAlice: Carol dials Alice, Carol's nonce 20..2f, Alice's "
        + "30..3f; Carol's dialer PROOF (role 1). aliceDialsCarol: Alice dials Carol with the same nonces, Alice's HELLO "
        + "(30..3f) first; Carol's responder PROOF (role 2). Every HELLO carries caps 40009, as keyed-v1's link entries "
        + "do. Each entry gives both HELLO payloads and records, the transcript Carol signed and her PROOF record. "
        + "CryptoKit randomizes Ed25519: verify the signature, never compare it."

    /// One link's fixed inputs.
    struct Case {
        let name: String
        let dialer: String
        let responder: String
        let role: LinkProof.Role
        let helloDialer: Hello
        let helloResponder: Hello

        var dialerBytes: [UInt8] { helloDialer.payload }
        var responderBytes: [UInt8] { helloResponder.payload }
        var transcript: [UInt8] {
            LinkProof.transcript(form: .plain, signer: role, dialerHello: dialerBytes, responderHello: responderBytes)
        }
    }

    static func cases(carol: IdentityKeys, alice: IdentityKeys) -> [Case] {
        let carolHello = Hello(nodeId: carol.nodeId.string, capabilities: capabilities, nonce: carolNonce)
        let aliceHello = Hello(nodeId: alice.nodeId.string, capabilities: capabilities, nonce: aliceNonce)
        return [
            Case(
                name: "carolDialsAlice",
                dialer: "carol",
                responder: "alice",
                role: .dialer,
                helloDialer: carolHello,
                helloResponder: aliceHello),
            Case(
                name: "aliceDialsCarol",
                dialer: "alice",
                responder: "carol",
                role: .responder,
                helloDialer: aliceHello,
                helloResponder: carolHello),
        ]
    }

    private static func helloEntry(_ hello: Hello) -> VectorLink.Hello? {
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: hello.payload, as: UTF8.self)
        return LinkRecord(.hello, payload: hello.payload).encoded.map { VectorLink.Hello(payload: text, record: Hex.encode($0)) }
    }

    /// Whether a committed entry is still what Carol would send on `link`: its HELLOs, role and transcript are this case's,
    /// and its PROOF is one whole tag-8 record with Carol's keys whose signature verifies for her role.
    static func isCurrent(_ entry: EmittedLinkProof, _ link: Case, carol: IdentityKeys) -> Bool {
        guard entry.dialer == link.dialer, entry.responder == link.responder, entry.signer == "carol",
            entry.role == link.role.rawValue, entry.helloDialer == helloEntry(link.helloDialer),
            entry.helloResponder == helloEntry(link.helloResponder), entry.transcript == Hex.encode(link.transcript),
            let record = Hex.decode(entry.proof)
        else {
            return false
        }
        var reader = LinkRecordReader()
        reader.append(record)
        guard let proof = try? reader.next(), proof.tag == .proof, !reader.hasPartialRecord,
            Array(proof.payload.prefix(LinkProof.keysByteCount)) == carol.bundle.signingKey + carol.bundle.agreementKey
        else {
            return false
        }
        let outcome = LinkProof.verify(
            proof.payload,
            claimedId: carol.nodeId,
            form: .plain,
            signer: link.role,
            dialerHello: link.dialerBytes,
            responderHello: link.responderBytes)
        return outcome == .proven(carol.bundle)
    }

    /// A fresh entry for `link`, Carol signing once.
    static func entry(_ link: Case, carol: IdentityKeys) throws -> EmittedLinkProof? {
        let payload = try LinkProof.payload(
            keys: carol, form: .plain, signer: link.role, dialerHello: link.dialerBytes, responderHello: link.responderBytes)
        guard let record = LinkRecord(.proof, payload: payload).encoded, let dialer = helloEntry(link.helloDialer),
            let responder = helloEntry(link.helloResponder)
        else {
            return nil
        }
        return EmittedLinkProof(
            dialer: link.dialer,
            responder: link.responder,
            signer: "carol",
            role: link.role.rawValue,
            helloDialer: dialer,
            helloResponder: responder,
            transcript: Hex.encode(link.transcript),
            proof: Hex.encode(record))
    }

    /// The section, keeping each committed proof while it is still current, with Carol's sealed links
    /// (``EmittedLinkSeals``) under `seal`.
    static func section(carol: IdentityKeys, alice: IdentityKeys, committed: EmittedLink?) throws -> EmittedLink? {
        var entries: [String: EmittedLinkProof] = [:]
        for link in cases(carol: carol, alice: alice) {
            let kept = committed.flatMap { link.name == "carolDialsAlice" ? $0.carolDialsAlice : $0.aliceDialsCarol }
            if let kept, isCurrent(kept, link, carol: carol) {
                entries[link.name] = kept
            } else {
                entries[link.name] = try entry(link, carol: carol)
            }
        }
        guard let dialing = entries["carolDialsAlice"], let answering = entries["aliceDialsCarol"] else {
            return nil
        }
        return EmittedLink(
            about: about,
            carolDialsAlice: dialing,
            aliceDialsCarol: answering,
            seal: try EmittedLinkSeals.section(carol: carol, alice: alice, committed: committed?.seal))
    }
}
