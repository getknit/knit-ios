import KnitTestSupport
import KnitWire
import Testing

/// The spool's record layer against the spec's §13 bytes (knit-next's `SpoolRecordsTest`, ADR 2026-11.adrq): each core
/// record is the Kotlin fixture's value, decodes from the pinned bytes to it, and encodes back to them. The attachment,
/// TURN, ticket, cast and signal records stay in knit-next: this build reads them as ``SpoolRecord/other(_:)``.
@Suite struct SpoolRecordTests {
    private static let bounds = ScopeBounds(maxFrames: 400, ttlMs: 172_800_000, maxBlob: 65_536)
    private static let stamp = PowStamp(counter: 42, day: 20_680)
    private static let limits = SpoolLimits(
        maxBlob: 65_536, maxRecord: 131_072, maxScopes: 64, maxPull: 64, maxFramesCap: 1000, maxTtlMs: 604_800_000
    )

    private static func fixture(_ count: Int, _ seed: Int) -> [UInt8] {
        SpoolVectors.fixture(count, seed: seed)
    }

    /// `SpoolRecordsTest.vectors()`'s fixtures for the core records, by vector name.
    static let fixtures: [(String, SpoolRecord)] = [
        ("helloSpool", .hello(SpoolHello(version: 1, minimum: 1, limits: limits, powBits: 20))),
        ("helloClient", .hello(.client)),
        ("sub", .sub(SpoolSub(request: 1, subs: [ScopeSub(scope: fixture(32, 1), bounds: bounds, pow: stamp)]))),
        ("digest", .digest(SpoolDigest(scope: fixture(32, 1), digest: fixture(8, 2), count: 3, full: false, bounds: bounds))),
        ("listRequest", .list(SpoolList(request: 2, scope: fixture(32, 1)))),
        (
            "listResponse",
            .list(SpoolList(request: 2, scope: fixture(32, 1), blobIds: [fixture(32, 3), fixture(32, 4)], tombstones: [fixture(32, 5)]))
        ),
        ("pull", .pull(SpoolPull(request: 3, scope: fixture(32, 1), blobIds: [fixture(32, 3)]))),
        ("blob", .blob(SpoolBlob(scope: fixture(32, 1), blobId: fixture(32, 3), data: fixture(48, 6)))),
        ("push", .push(SpoolPush(request: 4, scope: fixture(32, 1), blobId: fixture(32, 3), data: fixture(48, 6), pow: stamp))),
        ("event", .event(SpoolEvent(scope: fixture(32, 1), blobId: fixture(32, 3), data: fixture(48, 6)))),
        ("okBare", .ok(SpoolOk(request: 3))),
        ("okMissing", .ok(SpoolOk(request: 3, missing: [fixture(32, 4)]))),
        ("errScoped", .err(SpoolErr(code: SpoolErrorCode.tombstoned, request: 4, scope: fixture(32, 1)))),
        ("errRate", .err(SpoolErr(code: SpoolErrorCode.rate, message: "slow down", retryMs: 30_000))),
    ]

    @Test func everyCoreRecordVectorHasAFixture() {
        #expect(Set(Self.fixtures.map(\.0)) == Set(SpoolVectors.file.scope["Records"].map { Array($0.keys) } ?? []))
    }

    @Test(arguments: fixtures.map(\.0))
    func eachRecordDecodesToItsFixtureAndEncodesBackToItsBytes(name: String) throws {
        let fixture = try #require(Self.fixtures.first { $0.0 == name }?.1)
        let bytes = SpoolVectors.record(name)
        #expect(SpoolRecord(decoding: bytes) == fixture, "\(name) decoded to something else")
        #expect(fixture.encoded == bytes, "\(name) encoded to other bytes")
    }

    @Test func theClientHelloIsItsVersionAndNothingElse() {
        #expect(SpoolHello.client.encoded == Hex.decode("a261746568656c6c6f617601"))
    }

    /// A spool's optional capabilities, the commons, TURN, tickets, STUN, casts and signals, are read as kotlinx types
    /// them and dropped: each later section's hello is the core hello this build reads.
    @Test(arguments: SpoolVectors.file.helloVariants.keys.sorted())
    func everyHelloVariantDecodesWithItsCapabilitiesDropped(name: String) throws {
        let bytes = try #require(SpoolVectors.file.helloVariants[name].flatMap(Hex.decode))
        guard case .hello(let hello) = SpoolRecord(decoding: bytes) else {
            Issue.record("\(name) did not decode as a hello")
            return
        }
        #expect(hello.version == 1)
        #expect(hello.encoded.count <= bytes.count)
    }

    @Test func anAttachmentSpoolsLimitsCarryTheTriple() throws {
        let bytes = try #require(SpoolVectors.file.helloVariants["helloSpoolAttach"].flatMap(Hex.decode))
        let hello = try SpoolHello(decoding: bytes)
        #expect(hello.limits?.maxAttachBytes == 16_777_216)
        #expect(hello.limits?.maxAChunk == 49_221)
        #expect(hello.limits?.maxAget == 32)
    }

    /// Android's decode refuses a hello whose capability is the wrong shape, and closes 4002; so does this build.
    @Test(arguments: ["commons", "turn", "ent", "stun", "cast", "entGates", "rooms", "turnHosts", "sig"])
    func aMalformedCapabilityRefusesTheHello(field: String) throws {
        let hello = try CBOR.decode(SpoolVectors.record("helloSpool"))
        guard case .map(var entries) = hello else {
            Issue.record("helloSpool is not a map")
            return
        }
        entries.append(CBOR.Entry(key: .text(field), value: .text("not a capability")))
        #expect(SpoolRecord(decoding: CBOR.map(entries).encoded) == nil, "\(field)")
    }

    @Test func aCapabilityGivenNullIsNoCapability() throws {
        let hello = try CBOR.decode(SpoolVectors.record("helloSpool"))
        guard case .map(var entries) = hello else {
            Issue.record("helloSpool is not a map")
            return
        }
        entries.append(CBOR.Entry(key: .text("commons"), value: .null))
        #expect(SpoolRecord(decoding: CBOR.map(entries).encoded) == Self.fixtures.first?.1)
    }

    @Test func aRecordThisBuildDoesNotReadIsOtherAndNeverEncoded() {
        let ahave = CBOR.map([CBOR.Entry(key: .text("t"), value: .text("ahave")), CBOR.Entry(key: .text("q"), value: .unsigned(5))])
        #expect(SpoolRecord(decoding: ahave.encoded) == .other("ahave"))
        #expect(SpoolRecord.other("ahave").encoded == nil)
        let shouting = CBOR.map([CBOR.Entry(key: .text("t"), value: .text("HELLO")), CBOR.Entry(key: .text("v"), value: .unsigned(1))])
        #expect(SpoolRecord(decoding: shouting.encoded) == .other("HELLO"))
    }

    @Test func unknownKeysAreIgnored() throws {
        guard case .map(var entries) = try CBOR.decode(SpoolVectors.record("digest")) else {
            Issue.record("digest is not a map")
            return
        }
        entries.append(CBOR.Entry(key: .text("later"), value: .array([.unsigned(1)])))
        #expect(SpoolRecord(decoding: CBOR.map(entries).encoded) == Self.fixtures.first { $0.0 == "digest" }?.1)
    }

    /// Bytes that are not one record are dropped, never thrown: what Kotlin's `SpoolCodec.decode` turns to `null`.
    @Test func whatIsNotARecordDecodesToNothing() {
        let notRecords: [[UInt8]] = [
            [],
            [0xFF],
            CBOR.text("hello").encoded,
            CBOR.map([]).encoded,
            CBOR.map([CBOR.Entry(key: .text("t"), value: .unsigned(1))]).encoded,
            CBOR.map([CBOR.Entry(key: .text("t"), value: .text("ok"))]).encoded,
            CBOR.map([CBOR.Entry(key: .text("t"), value: .text("digest")), CBOR.Entry(key: .text("full"), value: .null)]).encoded,
            SpoolVectors.record("okBare") + [0x00],
        ]
        for bytes in notRecords {
            #expect(SpoolRecord(decoding: bytes) == nil, "\(bytes)")
        }
    }

    /// A record past 128 KiB is dropped before it is decoded, as Android's socket drops it.
    @Test func aRecordPastTheInboundBoundIsDropped() {
        let event = SpoolEvent(
            scope: SpoolVectors.fixture(32, seed: 1),
            blobId: SpoolVectors.fixture(32, seed: 3),
            data: [UInt8](repeating: 7, count: SpoolRecordLayer.maxInboundRecord)
        )
        #expect(event.encoded.count > SpoolRecordLayer.maxInboundRecord)
        #expect(SpoolRecord(decoding: event.encoded) == nil)
        let fits = SpoolEvent(scope: event.scope, blobId: event.blobId, data: [UInt8](repeating: 7, count: 1024))
        #expect(SpoolRecord(decoding: fits.encoded) == .event(fits))
    }

    /// A spool's limits are a claim: the two sizes go no higher than the inbound bound, a pull names 1 to 256 ids, and
    /// nothing is below 0.
    @Test func aSpoolsLimitsAreClampedToWhatThisClientTracks() {
        let greedy = SpoolLimits(
            maxBlob: Int(Int32.max),
            maxRecord: Int(Int32.max),
            maxScopes: 9,
            maxPull: Int(Int32.max),
            maxFramesCap: 7,
            maxTtlMs: .max,
            maxAttachBytes: 1,
            maxAChunk: 2,
            maxAget: 3
        )
        let clamped = greedy.clamped()
        #expect(clamped.maxBlob == SpoolRecordLayer.maxInboundRecord)
        #expect(clamped.maxRecord == SpoolRecordLayer.maxInboundRecord)
        #expect(clamped.maxPull == SpoolLimits.maxPullCeiling)
        #expect(clamped.maxScopes == 9 && clamped.maxFramesCap == 7 && clamped.maxTtlMs == .max)
        #expect(clamped.maxAttachBytes == 1 && clamped.maxAChunk == 2 && clamped.maxAget == 3)
        let negative = SpoolLimits(
            maxBlob: -1,
            maxRecord: -1,
            maxScopes: -1,
            maxPull: Int(Int32.min),
            maxFramesCap: -1,
            maxTtlMs: .min
        ).clamped()
        #expect(negative == SpoolLimits(maxBlob: 0, maxRecord: 0, maxScopes: 0, maxPull: 1, maxFramesCap: 0, maxTtlMs: 0))
        #expect(Self.limits.clamped() == Self.limits)
    }

    /// A listing's ids are byte strings; an id written as an array of integers is the wrong kind, as under kotlinx's
    /// `alwaysUseByteString`.
    @Test func anIdListOfIntegersIsRefused() {
        let list = CBOR.map([
            CBOR.Entry(key: .text("t"), value: .text("list")),
            CBOR.Entry(key: .text("q"), value: .unsigned(2)),
            CBOR.Entry(key: .text("scope"), value: .bytes(SpoolVectors.fixture(32, seed: 1))),
            CBOR.Entry(key: .text("blobIds"), value: .array([.array([.unsigned(1)])])),
        ])
        #expect(SpoolRecord(decoding: list.encoded) == nil)
    }
}
