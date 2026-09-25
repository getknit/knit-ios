import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

/// What this port emits for knit-next to check (`ios-emitted-v1.json`): Carol's identity from fixed keys, her
/// signed profile and room post, a v1 DM she seals to knit-next's Bob, and their safety number. knit-next's
/// `IosEmittedVectorTest` verifies each signature with Tink, re-encodes each frame with kotlinx, and opens the
/// DM as Bob.
///
/// `KNIT_WRITE_VECTORS=1` rewrites the file, keeping every committed frame that is still current, so a rewrite
/// moves only what changed; `scripts/sync-vectors.py --export` copies it into knit-next. A normal run checks
/// that the committed file is current: the identity and safety number match, and every frame is what this
/// build would send today, short of fresh randomness. CryptoKit randomizes Ed25519 and every v1 seal draws a
/// fresh key, so neither a signature nor a sealed DM is ever compared byte for byte.
@Suite struct EmittedVectorTests {
    private static let publishedAt: Int64 = 1_756_200_000_000
    private static let roomPostId = FrameId.text(for: fixtureBytes(16, seed: 31))
    private static let dmId = FrameId.text(for: fixtureBytes(16, seed: 32))
    private static let dmSentAt = publishedAt + 2000
    private static let about =
        "Frames the iOS port emits: Carol's identity from fixed keys, her signed profile and room post, a v1 DM she "
        + "seals to Bob from keyed-v1.json, and their safety number. Written by knit-ios with KNIT_WRITE_VECTORS=1; "
        + "IosEmittedVectorTest checks it. See vectors/README.md."

    private let roomBody = "Hello from Swift"
    private let dmBody = "Hi Bob, from Swift"

    private func carol() throws -> IdentityKeys {
        try #require(IdentityKeys(signingSeed: fixtureBytes(32, seed: 5), agreementScalar: fixtureBytes(32, seed: 6)))
    }

    /// Bob from knit-next's keyed vectors, private keys included, so this port can open what Carol seals to him.
    private func bob() throws -> IdentityKeys {
        let entry = try #require(KeyedVectors.file.identities["bob"])
        return try #require(IdentityKeys(signingSeed: hexBytes(entry.signingSeed), agreementScalar: hexBytes(entry.agreementScalar)))
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
            id: Self.roomPostId,
            senderId: carol.nodeId.string,
            sentAt: Self.publishedAt + 1000,
            payload: ChatContent(body: roomBody).encoded
        )
    }

    private func dmFrame(of carol: IdentityKeys, to bob: IdentityKeys, sentAt: Int64 = Self.dmSentAt) throws -> RelayEnvelope {
        let header = MessageCrypto.header(id: Self.dmId, senderId: carol.nodeId.string, sentAt: sentAt, thread: bob.nodeId.string)
        let recipients = [bob.nodeId: bob.bundle]
        let sealed = try #require(try MessageCrypto.seal(MessageContent(body: dmBody).encoded, header: header, to: recipients))
        return RelayEnvelope(
            type: .chat,
            id: Self.dmId,
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

    /// Whether a committed signed frame is still what this build sends: it re-encodes to its own bytes, it
    /// carries exactly `expected` as its signed bytes, and Carol's signature verifies.
    private func isCurrent(_ hex: String, expected: RelayEnvelope, from carol: IdentityKeys) -> Bool {
        guard let bytes = Hex.decode(hex), let wire = try? WireEnvelope(decoding: bytes) else {
            return false
        }
        return wire.encoded == bytes && wire.signed == expected.encoded && carol.bundle.isValidSignature(wire.sig, for: wire.signed)
    }

    /// Whether a committed DM is still what Carol would send, short of the fresh key material: every layer
    /// re-encodes to its own bytes, the id, clock and parties are the ones `dmFrame` uses, Carol's signature
    /// verifies, and Bob opens it to the body. knit-next's `KeyedVectorTest.isCurrentDm` asks the same of Alice's.
    private func isCurrentDm(_ hex: String, from carol: IdentityKeys, to bob: IdentityKeys) -> Bool {
        guard let bytes = Hex.decode(hex), let wire = try? WireEnvelope(decoding: bytes),
            let relay = try? RelayEnvelope(decoding: wire.signed), let chat = try? ChatContent(decoding: relay.payload),
            let envelope = chat.enc
        else {
            return false
        }
        let header = MessageCrypto.header(id: relay.id, senderId: relay.senderId, sentAt: relay.sentAt, thread: bob.nodeId.string)
        let reencodes = wire.encoded == bytes && relay.encoded == wire.signed && chat.encoded == relay.payload
        let addressed =
            relay.type == .chat && relay.id == Self.dmId && relay.senderId == carol.nodeId.string && relay.sentAt == Self.dmSentAt
            && relay.recipientId == bob.nodeId.string
        return reencodes && addressed && carol.bundle.isValidSignature(wire.sig, for: wire.signed)
            && MessageCrypto.open(envelope, header: header, as: bob)?.body == dmBody
    }

    /// The committed frame's wire while it is still current, so a rewrite moves only what changed.
    private func currentWire(_ committed: VectorFrame?, where isCurrent: (String) -> Bool) -> String? {
        guard let committed, isCurrent(committed.wire) else {
            return nil
        }
        return committed.wire
    }

    private func identityEntry(_ keys: IdentityKeys) -> VectorIdentity {
        VectorIdentity(
            signingSeed: Hex.encode(keys.signingSeed),
            agreementScalar: Hex.encode(keys.agreementScalar),
            bundle: keys.bundle.encoded,
            nodeId: keys.nodeId.string
        )
    }

    private func safetyNumber(carol: IdentityKeys, bob: IdentityKeys) -> VectorSafetyNumber {
        VectorSafetyNumber(between: ["carol", "bob"], number: SafetyNumber.compute(mine: carol.bundle, theirs: bob.bundle))
    }

    @Test(.enabled(if: VectorFile.writing))
    func writeTheEmittedVectors() throws {
        let carol = try carol()
        let bob = try bob()
        let committed = EmittedVectors.committed?.frames ?? [:]
        let profile = profileFrame(of: carol)
        let roomPost = roomPostFrame(of: carol)
        let profileWire =
            try currentWire(committed["carolProfile"]) { isCurrent($0, expected: profile, from: carol) }
            ?? wire(profile, signedBy: carol)
        let roomPostWire =
            try currentWire(committed["carolRoomPost"]) { isCurrent($0, expected: roomPost, from: carol) }
            ?? wire(roomPost, signedBy: carol)
        let dmWire =
            try currentWire(committed["carolDmToBob"]) { isCurrentDm($0, from: carol, to: bob) }
            ?? wire(dmFrame(of: carol, to: bob), signedBy: carol)
        #expect(isCurrentDm(dmWire, from: carol, to: bob))
        let vectors = EmittedVectors(
            about: Self.about,
            identities: ["carol": identityEntry(carol)],
            safetyNumber: safetyNumber(carol: carol, bob: bob),
            frames: [
                "carolProfile": VectorFrame(sender: "carol", wire: profileWire),
                "carolRoomPost": VectorFrame(sender: "carol", body: roomBody, wire: roomPostWire),
                "carolDmToBob": VectorFrame(sender: "carol", recipient: "bob", body: dmBody, wire: dmWire),
            ]
        )
        try VectorFile.write(vectors, to: EmittedVectors.fileName)
    }

    @Test(.disabled(if: VectorFile.writing))
    func theCommittedVectorsAreCurrent() throws {
        let committed = try #require(EmittedVectors.committed, "run the tests with KNIT_WRITE_VECTORS=1 to write the file")
        let carol = try carol()
        let bob = try bob()
        #expect(committed.identities == ["carol": identityEntry(carol)])
        #expect(committed.safetyNumber == safetyNumber(carol: carol, bob: bob))

        let profile = try #require(committed.frames["carolProfile"])
        let roomPost = try #require(committed.frames["carolRoomPost"])
        let dm = try #require(committed.frames["carolDmToBob"])
        let stale = "is not what this build sends; regenerate with KNIT_WRITE_VECTORS=1, then sync-vectors.py --export"
        #expect(isCurrent(profile.wire, expected: profileFrame(of: carol), from: carol), "carolProfile \(stale)")
        #expect(isCurrent(roomPost.wire, expected: roomPostFrame(of: carol), from: carol), "carolRoomPost \(stale)")
        #expect(isCurrentDm(dm.wire, from: carol, to: bob), "carolDmToBob \(stale)")
        #expect(roomPost.body == roomBody)
        #expect(dm.body == dmBody)
    }

    /// The currency checks must be able to fail: a fresh DM passes, and one sealed at another time does not.
    @Test func theDMCheckTellsACurrentDMFromAStaleOne() throws {
        let carol = try carol()
        let bob = try bob()
        let current = try wire(dmFrame(of: carol, to: bob), signedBy: carol)
        let stale = try wire(dmFrame(of: carol, to: bob, sentAt: Self.dmSentAt + 1), signedBy: carol)
        #expect(isCurrentDm(current, from: carol, to: bob))
        #expect(!isCurrentDm(stale, from: carol, to: bob))
        #expect(!isCurrentDm(current, from: carol, to: carol), "Carol cannot open what she sealed to Bob")
        #expect(!isCurrent(current, expected: profileFrame(of: carol), from: carol))
    }
}
