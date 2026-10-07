import KnitTestSupport
import KnitWire
import Testing

/// The holder query's wire types beyond their golden vectors (knit-next ADR 2026-10.6e5t).
@Suite struct BlobHaveContentTests {
    @Test func onlyTheBlobTrafficIsUnsignedPointToPoint() {
        let unsigned: [FrameType] = [.blobRequest, .blobHave, .blobHas, .blobProgress]
        let signed: [FrameType] = [.chat, .profile, .receipt, .reaction, .keyRequest, .typing, FrameType(rawValue: "future")]
        let allUnsigned = unsigned.allSatisfy(\.isUnsignedPointToPoint)
        let anySignedUnsigned = signed.contains(where: \.isUnsignedPointToPoint)
        #expect(allUnsigned)
        #expect(!anySignedUnsigned)
    }

    @Test func aStateThisBuildDoesNotKnowSurvivesDecodingAndIsNeverHeld() throws {
        // The reserved PARTIAL, and a state no build knows yet, both read back as written and neither counts as HAVE.
        let reserved = try BlobHasContent(decoding: GoldenVectors.bytes("blobHasContentReserved"))
        let future = BlobHasContent(items: [BlobHasItem(hash: "h1", state: BlobHolding(rawValue: 9))])
        let decoded = try BlobHasContent(decoding: future.encoded)
        #expect(reserved.items.map(\.state) == [.partial])
        #expect(decoded.items.map(\.state.rawValue) == [9])
        #expect(!BlobHolding.partial.isHeld && !BlobHolding(rawValue: 9).isHeld)
        #expect(BlobHolding.have.isHeld && BlobHolding.sending.isHeld)
        #expect(!BlobHolding.notHeld.isHeld && !BlobHolding.fetching.isHeld)
    }

    @Test func aNoneStateIsStillWrittenAndAnAbsentLoadOrReIsLeftOut() {
        // `state` has no default in Kotlin, so 0 is encoded; `load` and `re` default to null and are omitted.
        let answer = BlobHasContent(items: [BlobHasItem(hash: "h", state: .notHeld)])
        let expected: CBOR = .map([
            CBOR.Entry(
                key: .text("items"),
                value: .array([.map([CBOR.Entry(key: .text("hash"), value: .text("h")), CBOR.Entry(key: .text("state"), value: CBOR(0))])])
            )
        ])
        #expect(answer.cbor == expected)
    }

    @Test func aProgressReportMissingAFieldIsRefused() throws {
        // Every field of Android's `BlobProgressContent` is required: a report without one is malformed.
        let partial = CBOR.map([CBOR.Entry(key: .text("hash"), value: .text("h1")), CBOR.Entry(key: .text("held"), value: CBOR(1))])
        #expect(throws: WireDecodingError.self) { try BlobProgressContent(decoding: partial.encoded) }
        let whole = try BlobProgressContent(decoding: GoldenVectors.bytes("blobProgressContent"))
        #expect(whole == BlobProgressContent(hash: "h1", held: 245_760, ms: 13_500))
    }

    @Test func aPlainBlobRequestIsTheBytesEveryBuildSends() {
        #expect(BlobRequestContent(hash: "h1").encoded == GoldenVectors.bytes("blobReqContent"))
    }
}
