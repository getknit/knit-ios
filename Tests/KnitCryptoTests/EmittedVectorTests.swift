import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

/// What this port emits for knit-next to check (`ios-emitted-v1.json`): Carol's identity from fixed keys, her
/// signed profile and room post, a v1 DM she seals to knit-next's Bob, and their safety number. knit-next's
/// `IosEmittedVectorTest` verifies each signature with Tink, re-encodes each frame with kotlinx, and opens the
/// DM as Bob.
///
/// `KNIT_WRITE_VECTORS=1` rewrites the file; `scripts/sync-vectors.py --export` copies it into knit-next. A
/// normal run checks the committed file: the identity and safety number must match, every frame must verify,
/// and the profile and room post must still be the bytes this build would sign.
@Suite struct EmittedVectorTests {
    private static let publishedAt: Int64 = 1_756_200_000_000
    private static let about =
        "Frames the iOS port emits: Carol's identity from fixed keys, her signed profile and room post, a v1 DM she "
        + "seals to Bob from keyed-v1.json, and their safety number. Written by knit-ios with KNIT_WRITE_VECTORS=1; "
        + "IosEmittedVectorTest checks it. See vectors/README.md."

    private let roomBody = "Hello from Swift"
    private let dmBody = "Hi Bob, from Swift"

    private func carol() throws -> IdentityKeys {
        try #require(IdentityKeys(signingSeed: fixtureBytes(32, seed: 5), agreementScalar: fixtureBytes(32, seed: 6)))
    }

    private func bob() throws -> PublicKeyBundle {
        let entry = try #require(KeyedVectors.file.identities["bob"])
        return try #require(PublicKeyBundle(encoded: entry.bundle))
    }

    private func profileFrame(of carol: IdentityKeys) -> RelayEnvelope {
        let profile = ProfileContent(
            name: "Carol",
            status: "Sent from Swift",
            pubKey: carol.bundle.encoded,
            deviceTag: DeviceTag.derive("vector-device-carol"),
            protoVersion: WireProtocol.version,
            capabilities: Capabilities.local.rawValue,
            version: 1
        )
        return RelayEnvelope(
            type: .profile,
            id: "profile-\(carol.nodeId)-\(Self.publishedAt)",
            senderId: carol.nodeId.string,
            sentAt: Self.publishedAt,
            payload: profile.encoded
        )
    }

    private func roomPostFrame(of carol: IdentityKeys) -> RelayEnvelope {
        RelayEnvelope(
            type: .chat,
            id: FrameId.text(for: fixtureBytes(16, seed: 31)),
            senderId: carol.nodeId.string,
            sentAt: Self.publishedAt + 1000,
            payload: ChatContent(body: roomBody).encoded
        )
    }

    private func dmFrame(of carol: IdentityKeys, to bob: PublicKeyBundle) throws -> RelayEnvelope {
        let id = FrameId.text(for: fixtureBytes(16, seed: 32))
        let sentAt = Self.publishedAt + 2000
        let header = MessageCrypto.header(id: id, senderId: carol.nodeId.string, sentAt: sentAt, thread: bob.nodeId.string)
        let sealed = try #require(try MessageCrypto.seal(MessageContent(body: dmBody).encoded, header: header, to: [bob.nodeId: bob]))
        return RelayEnvelope(
            type: .chat,
            id: id,
            senderId: carol.nodeId.string,
            sentAt: sentAt,
            recipientId: bob.nodeId.string,
            payload: ChatContent(enc: sealed).encoded
        )
    }

    private func wire(_ relay: RelayEnvelope, signedBy sender: IdentityKeys) throws -> String {
        let signed = relay.encoded
        return Hex.encode(WireEnvelope(sig: try sender.signature(for: signed), signed: signed).encoded)
    }

    private func identityEntry(_ keys: IdentityKeys) -> VectorIdentity {
        VectorIdentity(
            signingSeed: Hex.encode(keys.signingSeed),
            agreementScalar: Hex.encode(keys.agreementScalar),
            bundle: keys.bundle.encoded,
            nodeId: keys.nodeId.string
        )
    }

    private func safetyNumber(carol: IdentityKeys, bob: PublicKeyBundle) -> VectorSafetyNumber {
        VectorSafetyNumber(between: ["carol", "bob"], number: SafetyNumber.compute(mine: carol.bundle, theirs: bob))
    }

    @Test(.enabled(if: VectorFile.writing))
    func writeTheEmittedVectors() throws {
        let carol = try carol()
        let bob = try bob()
        let vectors = EmittedVectors(
            about: Self.about,
            identities: ["carol": identityEntry(carol)],
            safetyNumber: safetyNumber(carol: carol, bob: bob),
            frames: [
                "carolProfile": VectorFrame(sender: "carol", wire: try wire(profileFrame(of: carol), signedBy: carol)),
                "carolRoomPost": VectorFrame(sender: "carol", body: roomBody, wire: try wire(roomPostFrame(of: carol), signedBy: carol)),
                "carolDmToBob": VectorFrame(
                    sender: "carol",
                    recipient: "bob",
                    body: dmBody,
                    wire: try wire(dmFrame(of: carol, to: bob), signedBy: carol)
                ),
            ]
        )
        try VectorFile.write(vectors, to: EmittedVectors.fileName)
    }

    @Test(.disabled(if: VectorFile.writing))
    func theCommittedVectorsStillHold() throws {
        let committed = try #require(EmittedVectors.committed, "run the tests with KNIT_WRITE_VECTORS=1 to write the file")
        let carol = try carol()
        let bob = try bob()
        #expect(committed.identities == ["carol": identityEntry(carol)])
        #expect(committed.safetyNumber == safetyNumber(carol: carol, bob: bob))

        let rebuilt = ["carolProfile": profileFrame(of: carol), "carolRoomPost": roomPostFrame(of: carol)]
        for name in ["carolProfile", "carolRoomPost", "carolDmToBob"] {
            let entry = try #require(committed.frames[name])
            let wire = try WireEnvelope(decoding: hexBytes(entry.wire))
            #expect(carol.bundle.isValidSignature(wire.sig, for: wire.signed), "\(name) verifies")
            if let relay = rebuilt[name] {
                #expect(wire.signed == relay.encoded, "\(name) is still the bytes this build signs")
            }
        }
    }
}
