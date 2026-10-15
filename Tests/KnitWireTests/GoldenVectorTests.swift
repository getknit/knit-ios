import KnitTestSupport
import KnitWire
import Testing

/// knit-next's `GoldenVectorTest` fixtures, byte for byte.
///
/// Every fixture must round-trip through the generic codec, which proves the kotlinx profile: definite lengths,
/// shortest integers, keys kept in order. The types this build models must also encode a Swift copy of the
/// Kotlin fixture to the same bytes, and decode the bytes back to it.
@Suite struct GoldenVectorTests {
    @Test(arguments: GoldenVectors.names)
    func everyVectorRoundTripsThroughTheGenericCodec(name: String) throws {
        let bytes = GoldenVectors.bytes(name)
        let item = try CBOR.decode(bytes)
        #expect(item.encoded == bytes, "\(name) did not re-encode to its pinned bytes")
    }

    @Test func thereAreSixtyFourVectors() {
        // A new fixture in knit-next needs a typed test here when this build models its type.
        #expect(GoldenVectors.names.count == 64)
    }

    @Test(arguments: typedFixtures)
    func typedFixtureEncodesToItsPinnedBytes(fixture: TypedFixture) throws {
        let pinned = GoldenVectors.bytes(fixture.name)
        #expect(fixture.encode() == pinned, "\(fixture.name) encoded differently from knit-next")
        #expect(try fixture.decodesToFixture(pinned), "\(fixture.name) did not decode back to the fixture")
    }

    @Test func theEnvelopesDecodeAndReencodeIdentically() throws {
        let wire = GoldenVectors.bytes("wireEnvelope")
        #expect(try WireEnvelope(decoding: wire).encoded == wire)
        let relay = GoldenVectors.bytes("relayEnvelope")
        #expect(try RelayEnvelope(decoding: relay).encoded == relay)
    }
}

/// One Kotlin fixture rebuilt in Swift.
struct TypedFixture: Sendable, CustomTestStringConvertible {
    let name: String
    let encode: @Sendable () -> [UInt8]
    let decodesToFixture: @Sendable ([UInt8]) throws -> Bool

    var testDescription: String { name }

    init<Value: CBORRepresentable & Equatable>(_ name: String, _ value: Value) {
        self.name = name
        encode = { value.encoded }
        decodesToFixture = { bytes in try Value(decoding: bytes) == value }
    }
}

private let initial = RatchetInit(eph: fixtureBytes(32, seed: 7), pkid: 3, at: 1234)
private let prekey = PrekeyInfo(id: 7, pub: fixtureBytes(32, seed: 9), sig: fixtureBytes(64, seed: 11))
private let wrapped = WrappedKey(to: "bob", wk: fixtureBytes(80, seed: 4))
private let loraKey = "oR62IJmFUE0Tgcw0GcypU5ZqUFCQllVBy2snB/BKQA4="
private let profileVersion: Int64 = 1_700_000_000_000
private let loraNode: Int64 = 0xDEAD_BEEF
private let groupSeed = GroupSeed(epoch: 3, seed: fixtureBytes(32, seed: 7), mintedAt: 1234)
private let groupRoot = GroupRootPayload(root: fixtureBytes(32, seed: 13), version: 2, minter: "aa")

/// The sealed profile update's fixtures all share these, as `GoldenVectorTest`'s do.
private func profileUpdate(
    status: String = "hiking",
    avatarHash: String? = "av1",
    openToChat: Bool = false,
    loraNode: Int64? = nil,
    loraKey: String? = nil
) -> ProfilePayload {
    ProfilePayload(
        name: "Ann",
        status: status,
        avatarHash: avatarHash,
        version: 1700,
        openToChat: openToChat,
        loraNode: loraNode,
        loraKey: loraKey
    )
}

private func profile(
    capabilities: Int64 = 15,
    prekey: PrekeyInfo? = nil,
    version: Int64? = nil,
    openToChat: Bool = false,
    loraNode: Int64? = nil,
    loraKey: String? = nil
) -> ProfileContent {
    ProfileContent(
        name: "Ann",
        status: "hiking",
        avatarHash: "av1",
        pubKey: "pk1",
        deviceTag: "dt1",
        protoVersion: 1,
        capabilities: capabilities,
        prekey: prekey,
        version: version,
        openToChat: openToChat,
        loraNode: loraNode,
        loraKey: loraKey
    )
}

let typedFixtures: [TypedFixture] = [
    TypedFixture(
        "wireEnvelope",
        WireEnvelope(ttl: 7, hops: 3, relay: false, sig: fixtureBytes(64, seed: 1), signed: fixtureBytes(8, seed: 2))
    ),
    TypedFixture("wireEnvelopeUnsigned", WireEnvelope(relay: false, sig: [], signed: fixtureBytes(8, seed: 2))),
    TypedFixture(
        "relayEnvelope",
        RelayEnvelope(
            type: .chat,
            id: "m1",
            senderId: "alice00000000000000000000aa",
            sentAt: 100,
            recipientId: "bob0000000000000000000000bb",
            payload: fixtureBytes(4, seed: 3)
        )
    ),
    TypedFixture(
        "chatContent",
        ChatContent(
            body: "hi there",
            mentions: [Mention(nodeId: "node1", name: "Ann")],
            attachmentHash: "abc123",
            attachmentMime: "image/webp"
        )
    ),
    TypedFixture("profileContent", profile()),
    TypedFixture("profileContentPrekey", profile(capabilities: 31, prekey: prekey)),
    TypedFixture("profileContentVersion", profile(capabilities: 31, prekey: prekey, version: profileVersion)),
    TypedFixture(
        "profileContentOpenToChat",
        profile(capabilities: 31, prekey: prekey, version: profileVersion, openToChat: true)
    ),
    TypedFixture(
        "profileContentLoraNode",
        profile(capabilities: 31, prekey: prekey, version: profileVersion, loraNode: loraNode)
    ),
    TypedFixture(
        "profileContentLoraKey",
        profile(capabilities: 31, prekey: prekey, version: profileVersion, loraNode: loraNode, loraKey: loraKey)
    ),
    TypedFixture(
        "groupInfo",
        GroupInfo(id: "g-1", name: "Team", members: ["a", "b"], createdBy: "a", photoHash: "ph1", photoUpdatedAt: 42)
    ),
    TypedFixture("groupInfoDeparted", GroupInfo(id: "g-1", members: ["a", "b"], createdBy: "a", departed: ["c"])),
    TypedFixture("receiptContent", ReceiptContent(ackId: "m1")),
    TypedFixture("reactionContent", ReactionContent(messageId: "m1", emoji: "👍")),
    TypedFixture("reactionPayload", ReactionContent(messageId: "m1", emoji: "👍")),
    TypedFixture("reactionPayloadRetraction", ReactionContent(messageId: "m1")),
    TypedFixture("groupLeaveContent", GroupLeaveContent(groupId: "g-1")),
    TypedFixture("keyReqContent", KeyRequestContent(nodeIds: ["a", "b"])),
    TypedFixture("blobReqContent", BlobRequestContent(hash: "h1")),
    TypedFixture("blobReqContentResumed", BlobRequestContent(hash: "h1", offset: 400_000)),
    TypedFixture("blobHaveContent", BlobHaveContent(hashes: ["h1", "h2"])),
    TypedFixture(
        "blobHasContent",
        BlobHasContent(
            items: [
                BlobHasItem(hash: "h1", state: .have, size: 140_948),
                BlobHasItem(hash: "h2", state: .sending, size: 4096),
                BlobHasItem(hash: "h3", state: .fetching),
                BlobHasItem(hash: "h4", state: .notHeld),
            ],
            load: 2,
            re: "q1"
        )
    ),
    TypedFixture(
        "blobHasContentReserved",
        BlobHasContent(items: [BlobHasItem(hash: "h1", state: .partial, size: 1000, held: 400)])
    ),
    // knit-next ADR 2026-10.nsr7: a SENDING answer that says when the asker's copy should land, and a receiver's report.
    TypedFixture(
        "blobHasContentSendingEta",
        BlobHasContent(items: [BlobHasItem(hash: "h1", state: .sending, size: 409_600, eta: 140_000)])
    ),
    TypedFixture("blobProgressContent", BlobProgressContent(hash: "h1", held: 245_760, ms: 13_500)),
    TypedFixture("blobCancelContent", BlobCancelContent(hash: "h1")),
    TypedFixture("typingContent", TypingContent(groupId: "g-1")),
    TypedFixture("mention", Mention(nodeId: "node1", name: "Ann")),
    TypedFixture(
        "replyRef",
        ReplyRef(messageId: "m0", authorId: "a", author: "Ann", snippet: "see you", hasAttachment: true)
    ),
    TypedFixture("wrappedKey", wrapped),
    TypedFixture("encEnvelope", EncEnvelope(nonce: fixtureBytes(12, seed: 5), ct: fixtureBytes(48, seed: 6), keys: [wrapped])),
    TypedFixture(
        "encEnvelopeV2",
        EncEnvelope(
            version: EncEnvelope.Version.ratchet,
            nonce: fixtureBytes(12, seed: 5),
            ct: fixtureBytes(48, seed: 6),
            keys: [],
            ratchet: RatchetHeader(se: 1, ek: fixtureBytes(32, seed: 8), pe: 0, n: 0, initial: initial)
        )
    ),
    TypedFixture(
        "encEnvelopeGroup",
        EncEnvelope(
            version: EncEnvelope.Version.ratchet,
            nonce: fixtureBytes(12, seed: 5),
            ct: fixtureBytes(48, seed: 6),
            keys: [],
            groupRatchet: GroupRatchetHeader(se: 2, n: 57)
        )
    ),
    TypedFixture(
        "encEnvelopeV3",
        EncEnvelope(
            version: EncEnvelope.Version.compactRatchet,
            nonce: [],
            ct: fixtureBytes(48, seed: 6),
            keys: [],
            ratchet: RatchetHeader(se: 2, ek: fixtureBytes(32, seed: 8), pe: 1, n: 5)
        )
    ),
    TypedFixture("ratchetInit", initial),
    TypedFixture(
        "ratchetHeader",
        RatchetHeader(se: 2, ek: fixtureBytes(32, seed: 8), pe: 1, n: 5, initial: initial, flags: RatchetHeader.resetFlag)
    ),
    TypedFixture("prekeyInfo", prekey),
    // The ratchet's sealed payloads (`Wire.kt:598-709`): the group seed and its distribution, the spool's root, and the
    // sealed profile update (ADR 2026-10.5sk9). The two distributions that carry a root raw are `SealedPayloadTests`',
    // outside this list: a `CBOR` value in a parameterized argument leaks under ASan (`scripts/lsan-suppressions.txt`).
    TypedFixture("groupSeed", groupSeed),
    TypedFixture("groupKeyPayload", GroupKeyPayload(groupId: "g-1", keys: [groupSeed])),
    TypedFixture("groupRootPayload", groupRoot),
    TypedFixture("profilePayload", profileUpdate()),
    TypedFixture("profilePayloadNoAvatar", profileUpdate(status: "", avatarHash: nil)),
    TypedFixture("profilePayloadOpenToChat", profileUpdate(openToChat: true)),
    TypedFixture("profilePayloadLoraNode", profileUpdate(loraNode: loraNode)),
    TypedFixture("profilePayloadLoraKey", profileUpdate(loraNode: loraNode, loraKey: loraKey)),
    TypedFixture("messageContentReceipt", MessageContent(body: "", ctl: MessageContent.Control.receipt, ack: "m1")),
    TypedFixture(
        "messageContentReceiptBatch",
        MessageContent(body: "", ctl: MessageContent.Control.receipt, acks: ["m1", "m2"])
    ),
    TypedFixture(
        "messageContentFile",
        MessageContent(
            body: "",
            attachmentHash: Hex.encode(fixtureBytes(32, seed: 4)),
            attachmentMime: "application/pdf",
            attachmentKey: Base64.encode(fixtureBytes(32, seed: 5)),
            attachmentName: "report.pdf",
            attachmentSize: 1_400_000
        )
    ),
]
