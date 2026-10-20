import KnitTestSupport
import KnitWire
import Testing

@testable import KnitCrypto

/// The contact card codec, ported from knit-next's `ContactCardTest` (`ContactCardTest.kt`, at `main`) against its golden
/// vectors (docs/CONTACT_CARD.md §5), with every refusal reason, the text forms found inside longer text, and the bytes
/// this port writes (ADR 2026-10.tpr5). Signatures are verified, never compared: CryptoKit randomizes Ed25519, so these
/// run on the Mac's `test:macos` as they do on Linux.
@Suite struct ContactCardTests {
    private static let spool = "wss://lax.spool.getknit.app/spool/v1"
    private static let issuedAt: Int64 = 1_756_100_000_000
    private static let nodeId = "4cgq2pnhh6p3j3afwsue3chrpi"
    private static let bundle =
        "omZzaWdQdWJYIOQDCZjP1a0XI8Fp+VaqC564YZtZkr1hLCr0KOvHn43wZ2hwa2VQdWJYIHPnmXHJEQApcjYyqAtwe/T2LBJXYzRuHocY1sDcw6o6"
    private static let fullCard =
        "omRib2R5WKimYXYBYmlkeBo0Y2dxMnBuaGg2cDNqM2Fmd3N1ZTNjaHJwaWJwa1hA5AMJmM_VrRcj"
        + "wWn5VqoLnrhhm1mSvWEsKvQo68efjfBz55lxyREAKXI2MqgLcHv09iwSV2M0bh6HGNbA3MOqOmRu"
        + "YW1lY0FubmJzcIF4JHdzczovL2xheC5zcG9vbC5nZXRrbml0LmFwcC9zcG9vbC92MWNpYXQbAAAB"
        + "mN-3eQBjc2lnWECn4VUyYreXsIMy1qJZ0Lan7cjpXGgbCijTCfSD68vSkGUrLis_L5ybjYzE86B8"
        + "AR6MbQdZ3f6f62UsQPQyRPoH"
    private static let minimalCard =
        "omRib2R5WGijYXYBYmlkeBo0Y2dxMnBuaGg2cDNqM2Fmd3N1ZTNjaHJwaWJwa1hA5AMJmM_VrRcj"
        + "wWn5VqoLnrhhm1mSvWEsKvQo68efjfBz55lxyREAKXI2MqgLcHv09iwSV2M0bh6HGNbA3MOqOmNz"
        + "aWdYQLL2FdNZ6dxdvl8HfEBnbj8yNsSoGoCPELMEIXuO6kA04Ra6SeNRPkpg1UGmp1ZQgU3qjVOp"
        + "M6JdH3puOvfihQA"

    /// `ContactCardTest`'s identity: Ed25519 from the seed `bytes(32, 1)`, X25519 from the scalar `bytes(32, 2)`.
    private let keys: IdentityKeys

    init() throws {
        keys = try #require(IdentityKeys(signingSeed: fixtureBytes(32, seed: 1), agreementScalar: fixtureBytes(32, seed: 2)))
    }

    private func card(_ text: String) throws -> ContactCard.Card {
        try #require(ContactCard.parse(text).card, "\(ContactCard.parse(text))")
    }

    private func reason(_ text: String) -> ContactCard.Reason? {
        guard case .invalid(let reason) = ContactCard.parse(text) else {
            return nil
        }
        return reason
    }

    /// Kotlin's `encode` with relays, signed by `keys` unless `signer` signs instead.
    private func encode(
        name: String?, spools: [String] = [], issuedAt: Int64 = 0, signer: IdentityKeys? = nil
    ) throws -> String {
        let signing = signer ?? keys
        let links = ContactCard.encode(bundle: keys.bundle, name: name, spools: spools, issuedAt: issuedAt, sign: signing.signature(for:))
        return try #require(links).compact
    }

    /// A card around `body` as written, signed by `keys`, whatever the body says.
    private func signed(_ body: ContactCardBody) throws -> String {
        let bytes = body.encoded
        let sig = try keys.signature(for: Array("knit/card/v1".utf8) + bytes)
        return Base64.encode(ContactCardSigned(body: bytes, sig: sig).encoded, variant: .urlSafeUnpadded)
    }

    /// The signed body a compact card carries, as it arrived.
    private func bodyBytes(of compact: String) throws -> [UInt8] {
        let raw = try #require(Base64.decode(compact, variant: .urlSafeUnpadded))
        return try ContactCardSigned(decoding: raw).body
    }

    // MARK: Vectors

    @Test func theIdentityIsTheVectorsIdentity() {
        #expect(keys.nodeId.string == Self.nodeId)
        #expect(keys.bundle.encoded == Self.bundle)
    }

    @Test func theFullCardVectorParsesToItsFields() throws {
        let card = try card(Self.fullCard)
        #expect(card.nodeId.string == Self.nodeId)
        #expect(card.bundle == Self.bundle)
        #expect(card.name == "Ann")
        #expect(card.spools == [Self.spool])
        #expect(card.issuedAt == Self.issuedAt)
    }

    @Test func theMinimalCardVectorParsesToItsFields() throws {
        let card = try card(Self.minimalCard)
        #expect(card.nodeId.string == Self.nodeId)
        #expect(card.bundle == Self.bundle)
        #expect(card.name.isEmpty && card.spools.isEmpty && card.issuedAt == 0)
    }

    /// The body is what both platforms sign, so ours must be Kotlin's byte for byte; the signature over it is checked by
    /// verifying, since it differs from Kotlin's on Apple platforms.
    @Test func ourBodyIsTheVectorsBodyByteForByte() throws {
        let full = try encode(name: "Ann", spools: [Self.spool], issuedAt: Self.issuedAt)
        #expect(try bodyBytes(of: full) == bodyBytes(of: Self.fullCard))
        let minimal = try encode(name: nil)
        #expect(try bodyBytes(of: minimal) == bodyBytes(of: Self.minimalCard))
        #expect(try card(full) == card(Self.fullCard))
        #expect(try card(minimal) == card(Self.minimalCard))
        // Our own card writes no relays, and an empty name the same as none.
        let ours = try #require(ContactCard.encode(keys, name: "  ", issuedAt: 0))
        #expect(try bodyBytes(of: ours.compact) == bodyBytes(of: Self.minimalCard))
        #expect(try card(ours.compact).nodeId == keys.nodeId)
    }

    @Test func theLinksCarryTheCompactCard() throws {
        let links = try #require(ContactCard.encode(keys, name: "Ann", issuedAt: Self.issuedAt))
        #expect(links.url == "https://getknit.app/c#" + links.compact)
        #expect(links.scheme == "knit://c/" + links.compact)
        #expect(!links.compact.contains("="), "unpadded")
        let card = try card(links.url)
        #expect(card.name == "Ann" && card.spools.isEmpty && card.issuedAt == Self.issuedAt)
    }

    // MARK: Text forms

    @Test func aCardRoundTripsThroughEveryAcceptedForm() throws {
        let compact = try encode(name: "Ann", spools: [Self.spool], issuedAt: Self.issuedAt)
        let links = ContactCard.Links(compact: compact)
        let forms = [
            compact,
            links.url,
            links.scheme,
            "Add me on Knit: \(links.url) — thanks!",
            "  \(links.scheme)\n",
            "\u{3000}\(compact)\u{2029}",
        ]
        for form in forms {
            let card = try card(form)
            #expect(card.nodeId == keys.nodeId, "\(form)")
            #expect(card.bundle == Self.bundle)
            #expect(card.name == "Ann" && card.spools == [Self.spool] && card.issuedAt == Self.issuedAt)
            #expect(ContactCard.looksLikeCard(form))
        }
    }

    /// The App Link is looked for first, and a prefix found ends the search: what follows it is the card, or nothing.
    @Test func theAppLinkIsFoundBeforeTheSchemeLink() throws {
        let links = ContactCard.Links(compact: Self.minimalCard)
        #expect(reason("\(links.scheme) and https://getknit.app/c#AAAA") == .malformed, "the App Link's run, though later")
        #expect(reason("https://getknit.app/c# then \(links.scheme)") == .notACard, "an empty run after the App Link")
        #expect(try card("see https://getknit.app/c#\(Self.minimalCard)?x=1").nodeId == keys.nodeId, "the run stops at '?'")
    }

    /// `java.util.Base64`'s URL decoder takes the padding as optional, and exact when present.
    @Test func paddingIsOptionalButExact() throws {
        let compact = Self.minimalCard
        let missing = (4 - compact.utf8.count % 4) % 4
        let padded = compact + String(repeating: "=", count: missing)
        if missing > 0 {
            #expect(try card(padded).nodeId == keys.nodeId)
        }
        #expect(reason(padded + "====") == .malformed)
        #expect(reason("knit://c/" + compact.dropLast(4) + "=" + compact.suffix(4)) == .malformed, "padding inside the run")
    }

    // MARK: The verify code

    @Test func theVerifyCodeIsAcceptedAsANamelessCard() throws {
        let card = try card(VerifyPayload.encode(keys.bundle))
        #expect(card == ContactCard.Card(nodeId: keys.nodeId, bundle: Self.bundle, name: "", spools: [], issuedAt: 0))
        #expect(try self.card("  " + VerifyPayload.encode(keys.bundle) + "\n").nodeId == keys.nodeId)
        #expect(reason("knit-id:v1:" + String(repeating: "a", count: 26) + ":" + Self.bundle) == .idMismatch)
        #expect(reason("knit-id:v1:not-an-id:" + Self.bundle) == .badId)
        #expect(reason("knit-id:v1:" + Self.nodeId) == .malformed, "no bundle")
        #expect(ContactCard.looksLikeCard("knit-id:v1:"))
    }

    /// The text is read as UTF-8: a combining mark after the prefix leaves the prefix whole, as Kotlin's `startsWith`
    /// does, so the code is read and refused for its id. Read as characters, the prefix would be missed.
    @Test func aCombiningMarkAfterThePrefixLeavesThePrefixWhole() {
        #expect(reason("knit-id:v1:\u{301}" + Self.nodeId.dropFirst() + ":" + Self.bundle) == .badId)
    }

    // MARK: Normalizing

    @Test func theNameIsNormalizedAndCutAndTheRelaysCapped() throws {
        let compact = try encode(
            name: "  Ann   Example " + String(repeating: "x", count: 60),
            spools: (0..<6).map { "wss://s\($0).example/spool/v1" },
            issuedAt: 1
        )
        let card = try card(compact)
        #expect(card.name.utf16.count == 32)
        #expect(card.name.hasPrefix("Ann Example x"))
        #expect(card.spools.count == ContactCard.maxSpools)
    }

    /// A name read from a card is normalized and cut too, never splitting a surrogate pair (`clampToUtf16`, past the pin).
    @Test func aReceivedNameIsCutWithoutSplittingAPair() throws {
        let long = String(repeating: "a", count: 31) + "😀" + "b"
        let body = ContactCardBody(version: 1, nodeId: Self.nodeId, keys: keys.bundle.signingKey + keys.bundle.agreementKey, name: long)
        let card = try card(try signed(body))
        #expect(card.name == String(repeating: "a", count: 31))
        let spaced = ContactCardBody(
            version: 1, nodeId: Self.nodeId, keys: keys.bundle.signingKey + keys.bundle.agreementKey, name: "\u{85}Ann\u{2028}\u{2028}Lee\t"
        )
        #expect(try self.card(try signed(spaced)).name == " Ann Lee", "U+0085 is regex \\s on ART but not Kotlin's isWhitespace")
    }

    // MARK: Refusals

    @Test func aTamperedCardIsRefused() throws {
        let raw = try #require(Base64.decode(Self.fullCard, variant: .urlSafeUnpadded))
        for index in raw.indices {
            var mutated = raw
            mutated[index] ^= 0x01
            let text = Base64.encode(mutated, variant: .urlSafeUnpadded)
            #expect(ContactCard.parse(text).card == nil, "byte \(index)")
        }
    }

    @Test func aCardSignedByAnotherKeyIsRefusedEvenWhenItsBundleIsGenuine() throws {
        let other = try #require(IdentityKeys(signingSeed: fixtureBytes(32, seed: 9), agreementScalar: fixtureBytes(32, seed: 2)))
        #expect(reason(try encode(name: "Mallory", issuedAt: 5, signer: other)) == .badSignature)
    }

    @Test func everyRefusalHasItsOwnReason() throws {
        let rawKeys = keys.bundle.signingKey + keys.bundle.agreementKey
        let other = TestIds.otherNodeId
        let cases: [(String, ContactCard.Reason)] = [
            ("", .notACard),
            ("hello there", .notACard),
            ("https://getknit.app/", .notACard),
            ("AAAA", .notACard),
            ("aaaaabbbbbcccccdddddeeeeef", .notACard),
            (String(repeating: "A", count: 4000), .tooLarge),
            ("knit://c/" + String(repeating: "A", count: 685), .tooLarge),
            ("knit://c/" + String(repeating: "A", count: 684), .tooLarge),
            (String(repeating: "A", count: 260), .malformed),
            ("https://getknit.app/c#AAAA", .malformed),
            (try signed(ContactCardBody(version: 2, nodeId: Self.nodeId, keys: rawKeys)), .badVersion),
            (try signed(ContactCardBody(version: 1, nodeId: "not-an-id", keys: rawKeys)), .badId),
            (try signed(ContactCardBody(version: 1, nodeId: Self.nodeId, keys: Array(rawKeys.dropLast()))), .badKey),
            (try signed(ContactCardBody(version: 1, nodeId: other, keys: rawKeys)), .idMismatch),
            (try encode(name: "Mallory", signer: TestIds.mallory), .badSignature),
        ]
        for (text, expected) in cases {
            #expect(reason(text) == expected, "\(text.prefix(40))")
        }
        #expect(Set(cases.map(\.1)) == Set(ContactCard.Reason.allCases), "every reason")
    }

    @Test func looksLikeCardIsStricterThanParse() {
        #expect(ContactCard.looksLikeCard(ContactCard.Links(compact: Self.minimalCard).url))
        #expect(ContactCard.looksLikeCard("text with knit://c/AAAA in it"))
        #expect(!ContactCard.looksLikeCard("https://getknit.app/c#"))
        #expect(!ContactCard.looksLikeCard("just some text"))
        #expect(!ContactCard.looksLikeCard(Self.nodeId))
        #expect(!ContactCard.looksLikeCard(String(repeating: "A", count: 199)))
        #expect(ContactCard.looksLikeCard(String(repeating: "A", count: 200)))
    }

    /// `parseNeverThrowsOnArbitraryInput`: junk, junk as base64url, and every prefix of a card, each answered.
    @Test func parseAnswersArbitraryInput() throws {
        var state: UInt64 = 42
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        for _ in 0..<500 {
            let junk = (0..<Int(next() % 600)).map { _ in UInt8(truncatingIfNeeded: next()) }
            _ = ContactCard.parse(Base64.encode(junk, variant: .urlSafeUnpadded))
            // Lossy on purpose: junk becomes some text, replacement characters included, as Kotlin's ISO-8859-1 read does.
            // swiftlint:disable:next optional_data_string_conversion
            let text = String(decoding: junk, as: UTF8.self)
            _ = ContactCard.parse(text)
            _ = ContactCard.looksLikeCard(text)
        }
        let raw = try #require(Base64.decode(Self.fullCard, variant: .urlSafeUnpadded))
        for length in 0..<raw.count {
            #expect(ContactCard.parse(Base64.encode(Array(raw.prefix(length)), variant: .urlSafeUnpadded)).card == nil)
            #expect(ContactCard.parse(String(Self.fullCard.prefix(length))).card == nil)
        }
        #expect(ContactCard.parse(ContactCard.urlPrefix) == .invalid(.notACard))
        #expect(ContactCard.parse(ContactCard.schemePrefix + "!!!") == .invalid(.notACard))
    }
}

/// Fixed identities the refusals need beside the card's own.
private enum TestIds {
    /// Another identity's node id, for a card whose keys derive to a different id.
    static var otherNodeId: String {
        mallory.nodeId.string
    }

    /// Someone who is not the card's owner.
    static var mallory: IdentityKeys {
        guard let keys = IdentityKeys(signingSeed: fixtureBytes(32, seed: 9), agreementScalar: fixtureBytes(32, seed: 10)) else {
            fatalError("fixed seeds make valid keys")
        }
        return keys
    }
}
