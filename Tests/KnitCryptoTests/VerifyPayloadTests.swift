import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

/// The verify code, ported from knit-next's `VerifyPayloadTest`, with the validity check `ContactCard.parseLegacy`
/// adds (ADR 2026-10.65xx).
@Suite struct VerifyPayloadTests {
    private func bundle(_ name: String) throws -> PublicKeyBundle {
        let entry = try #require(KeyedVectors.file.identities[name])
        return try #require(PublicKeyBundle(encoded: entry.bundle))
    }

    /// knit-next pins no vector for the code. This one is its format, `"knit-id:v1:$nodeId:$bundle"`, filled with
    /// keyed-v1 Alice, who is also `ContactCardTest`'s identity.
    @Test func alicesCodeIsKnitNextsFormat() throws {
        let code = VerifyPayload.encode(try bundle("alice"))
        #expect(
            code
                == "knit-id:v1:4cgq2pnhh6p3j3afwsue3chrpi:"
                + "omZzaWdQdWJYIOQDCZjP1a0XI8Fp+VaqC564YZtZkr1hLCr0KOvHn43wZ2hwa2VQdWJYIHPnmXHJEQApcjYyqAtwe/T2LBJXYzRuHocY1sDcw6o6"
        )
        #expect(code.utf8.count == 150)
    }

    @Test(arguments: ["alice", "bob"])
    func aCodeParsesBackToItsOwnCertifiedId(name: String) throws {
        let keys = try bundle(name)
        let parsed = try #require(VerifyPayload.parse(VerifyPayload.encode(keys)))
        #expect(parsed.nodeId == keys.nodeId.string)
        #expect(parsed.bundle == keys.encoded)
        #expect(parsed.certifiedNodeId == keys.nodeId)
    }

    @Test func anyTwoFieldsParse() throws {
        let parsed = try #require(VerifyPayload.parse("knit-id:v1:node1234:YmFzZTY0Kw=="))
        #expect(parsed.nodeId == "node1234")
        #expect(parsed.bundle == "YmFzZTY0Kw==")
    }

    @Test(arguments: [
        "https://example.com",
        "node1234:YmFzZTY0",
        "KNIT-ID:v1:node1234:YmFzZTY0",
        " knit-id:v1:node1234:YmFzZTY0",
        "knit-id:v1:onlynodeid",
        "knit-id:v1:node1234:",
        "knit-id:v1::YmFzZTY0",
        "knit-id:v1:\u{A0}:YmFzZTY0",
        "knit-id:v1:node1234:\u{2028}",
        "",
    ])
    func whatIsNotACodeIsRefused(text: String) {
        #expect(VerifyPayload.parse(text) == nil)
    }

    @Test func laterColonsBelongToTheBundle() throws {
        let parsed = try #require(VerifyPayload.parse("knit-id:v1:node1234:a:b:c"))
        #expect(parsed.nodeId == "node1234")
        #expect(parsed.bundle == "a:b:c")
    }

    /// Kotlin's `startsWith` compares code units, so a combining mark after the prefix leaves the prefix whole. A
    /// Swift `hasPrefix` would see `:` and the mark as one character and refuse it.
    @Test func theParseWalksBytesNotCharacters() throws {
        let parsed = try #require(VerifyPayload.parse("knit-id:v1:\u{301}node:bundle"))
        #expect(parsed.nodeId == "\u{301}node")
    }

    @Test func anIdItsBundleDoesNotDeriveToIsUncertified() throws {
        let alice = try bundle("alice")
        let bob = try bundle("bob")
        for id in [bob.nodeId.string, "node1234", alice.nodeId.string.uppercased()] {
            let parsed = try #require(VerifyPayload.parse(VerifyPayload.prefix + id + ":" + alice.encoded))
            #expect(parsed.certifiedNodeId == nil)
        }
    }
}
