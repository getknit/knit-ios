import KnitTestSupport
import KnitWire
import Testing

/// The ratchet's payloads inside a sealed ``MessageContent``: the group key's distribution, request and ack (`gk`), its
/// seeds, the spool's root it may carry, and the sealed profile update (`pr`), against knit-next's fixtures and kotlinx's
/// rules (`Wire.kt:598-709`).
@Suite struct SealedPayloadTests {
    private let seed = GroupSeed(epoch: 3, seed: fixtureBytes(32, seed: 7), mintedAt: 1234)
    private let root = GroupRootPayload(root: fixtureBytes(32, seed: 13), version: 2, minter: "aa")

    private func entry(_ key: String, _ value: CBOR) -> CBOR.Entry {
        CBOR.Entry(key: .text(key), value: value)
    }

    /// `groupKeyPayloadRoot` and `groupKeyPayloadRoster`, which `GoldenVectorTests` leaves to a plain test because their
    /// root is a `CBOR` value: a root rides as received, and the founding roster beside it.
    @Test func aDistributionCarryingARootEncodesAsAndroidsDoes() throws {
        let rootOnly = GroupKeyPayload(groupId: "g-1", gr: root.cbor)
        let pinnedRoot = GoldenVectors.bytes("groupKeyPayloadRoot")
        #expect(rootOnly.encoded == pinnedRoot)
        #expect(try GroupKeyPayload(decoding: pinnedRoot) == rootOnly)

        let founding = GroupInfo(id: "g-1", name: "Team", members: ["aa", "bb"], createdBy: "aa", departed: ["cc"])
        let roster = GroupKeyPayload(groupId: "g-1", keys: [seed], gr: root.cbor, group: founding)
        let pinnedRoster = GoldenVectors.bytes("groupKeyPayloadRoster")
        #expect(roster.encoded == pinnedRoster)
        #expect(try GroupKeyPayload(decoding: pinnedRoster) == roster)
    }

    /// A root is kept exactly as it arrived, a key this build does not know included, and goes back out unchanged.
    @Test func aRootIsKeptAsItArrived() throws {
        guard case .map(let fields) = root.cbor else {
            Issue.record("a root is a map")
            return
        }
        let grown = CBOR.map(fields + [entry("scope", .unsigned(1))])
        let item = CBOR.map([entry("groupId", .text("g-1")), entry("gr", grown)])
        let payload = try GroupKeyPayload(cbor: item)
        #expect(payload.gr == grown)
        #expect(payload.cbor == item)
    }

    /// kotlinx types `gr`, so a root of the wrong shape fails the whole payload there, and here.
    @Test func aRootOfTheWrongShapeFailsThePayload() throws {
        let textRoot = CBOR.map([entry("root", .text("r")), entry("version", .unsigned(2)), entry("minter", .text("aa"))])
        #expect(throws: WireDecodingError.invalidValue(type: "GroupRootPayload", field: "root")) {
            try GroupKeyPayload(cbor: .map([entry("groupId", .text("g-1")), entry("gr", textRoot)]))
        }
        #expect(throws: WireDecodingError.notAMap(type: "GroupRootPayload")) {
            try GroupKeyPayload(cbor: .map([entry("groupId", .text("g-1")), entry("gr", .unsigned(1))]))
        }
        // `null` is no root at all.
        #expect(try GroupKeyPayload(cbor: .map([entry("groupId", .text("g-1")), entry("gr", .null)])).gr == nil)
    }

    /// A request carries the group alone and an ack its epoch: `keys` stays off the wire while empty, and has no `null`.
    @Test func aRequestAndAnAckCarryNoKeys() throws {
        #expect(GroupKeyPayload(groupId: "g-1").cbor == .map([entry("groupId", .text("g-1"))]))
        let ack = GroupKeyPayload(groupId: "g-1", ackEpoch: 3)
        #expect(try GroupKeyPayload(decoding: ack.encoded) == ack)
        #expect(throws: WireDecodingError.unexpectedNull(type: "GroupKeyPayload", field: "keys")) {
            try GroupKeyPayload(cbor: .map([entry("groupId", .text("g-1")), entry("keys", .null)]))
        }
        #expect(throws: WireDecodingError.missingField(type: "GroupSeed", field: "mintedAt")) {
            try GroupSeed(cbor: .map([entry("epoch", .unsigned(1)), entry("seed", .bytes([1]))]))
        }
    }

    /// A profile update's name and status have no default; its version and open-to-chat flag do.
    @Test func aProfileUpdateNeedsANameAndAStatus() throws {
        #expect(throws: WireDecodingError.missingField(type: "ProfilePayload", field: "status")) {
            try ProfilePayload(cbor: .map([entry("name", .text("Ann"))]))
        }
        let minimal = try ProfilePayload(cbor: .map([entry("name", .text("Ann")), entry("status", .text(""))]))
        #expect(minimal == ProfilePayload(name: "Ann", status: ""))
        #expect(minimal.version == 0)
        #expect(!minimal.openToChat)
    }

    /// The named plaintext types both payloads, as kotlinx does, so one it cannot read fails the content. This build
    /// used to keep them raw; no build seals either under v1, where a ctl never rides.
    @Test func aSealedPlaintextReadsItsPayloadsTyped() throws {
        let distribution = MessageContent(body: "", ctl: MessageContent.Control.groupKey, gk: GroupKeyPayload(groupId: "g-1", keys: [seed]))
        #expect(try MessageContent(decoding: distribution.encoded) == distribution)
        let update = MessageContent(
            body: "", ctl: MessageContent.Control.profile, pr: ProfilePayload(name: "Ann", status: "out", version: 5))
        #expect(try MessageContent(decoding: update.encoded) == update)

        #expect(throws: WireDecodingError.notAMap(type: "GroupKeyPayload")) {
            try MessageContent(cbor: .map([entry("body", .text("")), entry("ctl", .unsigned(2)), entry("gk", .unsigned(5))]))
        }
        #expect(throws: WireDecodingError.missingField(type: "ProfilePayload", field: "name")) {
            try MessageContent(cbor: .map([entry("body", .text("")), entry("ctl", .unsigned(8)), entry("pr", .map([]))]))
        }
    }
}
