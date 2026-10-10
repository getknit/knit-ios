import KnitTestSupport
import KnitWire
import Testing

/// Node ids, frame ids, frame keys, hex, base64, the digest fold and the text rules.
@Suite struct IdentityCodecTests {
    @Test(arguments: [
        ("", ""), ("f", "my"), ("fo", "mzxq"), ("foo", "mzxw6"), ("foob", "mzxw6yq"), ("fooba", "mzxw6ytb"),
        ("foobar", "mzxw6ytboi"),
    ])
    func base32MatchesRFC4648LowercasedAndUnpadded(plain: String, encoded: String) {
        #expect(Base32.encode(Array(plain.utf8)) == encoded)
        #expect(Base32.decode(encoded) == Array(plain.utf8))
    }

    @Test func nodeIdsAreCanonicalBase32() throws {
        let id = try #require(NodeId("ffbbh6thbepahqxsv2gqog45m4"))
        #expect(id.bytes.count == NodeId.byteCount)
        #expect(NodeId(bytes: id.bytes) == id)
        #expect(NodeId("cswad43wmlont27jr4tyvu63i4") != nil)
        // Wrong length, uppercase, a character outside the alphabet, and non-zero padding bits.
        #expect(NodeId("ffbbh6thbepahqxsv2gqog45m") == nil)
        #expect(NodeId("FFBBH6THBEPAHQXSV2GQOG45M4") == nil)
        #expect(NodeId("ffbbh6thbepahqxsv2gqog45m1") == nil)
        #expect(NodeId("ffbbh6thbepahqxsv2gqog45m5") == nil)
        #expect(NodeId(bytes: [1, 2, 3]) == nil)
    }

    @Test func nodeIdsOrderAsKotlinStringsDo() throws {
        // Digits sort before letters in ASCII, and the tie-break depends on it.
        let digitFirst = try #require(NodeId("2" + String(repeating: "a", count: 25)))
        let letterFirst = try #require(NodeId("a" + String(repeating: "a", count: 25)))
        #expect(digitFirst < letterFirst)
        #expect(!(letterFirst < digitFirst))
    }

    @Test(arguments: [
        ("", ""), ("f", "Zg=="), ("fo", "Zm8="), ("foo", "Zm9v"), ("foob", "Zm9vYg=="), ("fooba", "Zm9vYmE="),
        ("foobar", "Zm9vYmFy"),
    ])
    func base64MatchesRFC4648(plain: String, encoded: String) {
        #expect(Base64.encode(Array(plain.utf8)) == encoded)
        #expect(Base64.decode(encoded) == Array(plain.utf8))
    }

    @Test func base64RejectsWhatJavaRejects() {
        #expect(Base64.decode("Zm9v!") == nil)
        #expect(Base64.decode("Z") == nil)
        #expect(Base64.decode("Zg=") == nil)
        #expect(Base64.decode("Zm9v=") == nil, "padding after a complete group")
        #expect(Base64.decode("Zm9v====") == nil, "padding after a complete group")
        #expect(Base64.decode("Zg===") == nil)
        #expect(Base64.decode("Zm8=") == Array("fo".utf8))
        #expect(Base64.decode("Zg") == Array("f".utf8), "unpadded input decodes, as java.util.Base64 allows")
        #expect(Base64.decode("-_8", variant: .urlSafeUnpadded) == [0xFB, 0xFF])
        #expect(Base64.decode("+/8", variant: .urlSafeUnpadded) == nil)
        #expect(Base64.encode([0xFB, 0xFF], variant: .urlSafeUnpadded) == "-_8")
    }

    @Test func theBundleProbeDecodesToItsRawKeys() throws {
        let raw = try #require(Base64.decode(GoldenVectors.file.bundle.encoded))
        #expect(raw.count == 84)
        #expect(Base64.encode(raw) == GoldenVectors.file.bundle.encoded)
        let proto = try PublicKeyBundleProto(decoding: raw)
        #expect(proto == PublicKeyBundleProto(sigPub: fixtureBytes(32, seed: 10), hpkePub: fixtureBytes(32, seed: 20)))
        #expect(proto.encoded == raw)
    }

    @Test func aBundleProtoNeedsBothKeysAsByteStrings() {
        let sigOnly = CBOR.map([CBOR.Entry(key: .text("sigPub"), value: .bytes([1]))])
        #expect(throws: WireDecodingError.missingField(type: "PublicKeyBundle", field: "hpkePub")) {
            try PublicKeyBundleProto(cbor: sigOnly)
        }
        let textKey = CBOR.map([
            CBOR.Entry(key: .text("sigPub"), value: .text("AAAA")), CBOR.Entry(key: .text("hpkePub"), value: .bytes([2])),
        ])
        #expect(throws: WireDecodingError.self) {
            try PublicKeyBundleProto(cbor: textKey)
        }
    }

    @Test func blankMeansKotlinBlank() {
        #expect(TextLimits.isBlank(""))
        #expect(TextLimits.isBlank(" \t\u{2003}\u{1F}"))
        #expect(!TextLimits.isBlank(" a "))
        #expect(!TextLimits.isBlank("\u{200B}"), "a zero-width space is a format character, not whitespace, to Kotlin")
    }

    @Test func frameIdsAreTwentyTwoCharacterBase64URL() {
        let id = fixtureFrameId(1)
        #expect(id.count == FrameId.length)
        #expect(FrameId.bytes(of: id) == fixtureBytes(16, seed: 1))
        #expect(FrameId.bytes(of: "m1") == nil)
        #expect(FrameId.bytes(of: "profile-ffbbh6thbepahqxsv2gqog45m4-1") == nil)
        var generator = CountingGenerator()
        let generated = FrameId.generate(using: &generator)
        #expect(FrameId.bytes(of: generated) != nil)
        #expect(generated != FrameId.generate(using: &generator))
    }

    @Test func frameKeysUseTheSignaturePrefixOrTheUnsignedId() {
        let envelope = RelayEnvelope(type: .blobRequest, id: "id-1", senderId: "a", payload: [])
        let signed = WireEnvelope(sig: Array(0..<64), signed: [])
        #expect(FrameKey.of(signed, envelope) == "0001020304050607")
        #expect(FrameKey.of(WireEnvelope(sig: [], signed: []), envelope) == "u:id-1")
    }

    @Test func hexIsLowercaseAndStrict() {
        #expect(Hex.encode([0x00, 0xAB, 0xFF]) == "00abff")
        #expect(Hex.decode("00abff") == [0x00, 0xAB, 0xFF])
        #expect(Hex.decode("0") == nil)
        #expect(Hex.decode("AB") == nil)
        #expect(Hex.decode("zz") == nil)
    }

    @Test func theDigestFoldIsFNV1a64XoredAcrossTheSet() {
        #expect(StoreDigest.hash("a") == 0xAF63_DC4C_8601_EC8C)
        #expect(StoreDigest.hash("") == 0xCBF2_9CE4_8422_2325)
        #expect(StoreDigest.fingerprint(of: []) == 0)
        #expect(StoreDigest.fingerprint(of: ["a", "b"]) == StoreDigest.fingerprint(of: ["b", "a"]))
        #expect(StoreDigest.fingerprint(of: ["a", "a"]) == 0)
    }

    @Test func frameTypesKeepKnitNextsCustodyMembership() {
        let custodial: [FrameType] = [.chat, .reaction, .receipt, .groupUpdate, .groupLeave, .profile]
        let transient: [FrameType] = [.blobRequest, .blobHave, .blobHas, .keyRequest, .typing, .commons, FrameType(rawValue: "future")]
        let allCustodial = custodial.allSatisfy(\.isCustodial)
        let anyTransientCustodial = transient.contains(where: \.isCustodial)
        #expect(allCustodial)
        #expect(!anyTransientCustodial)
        #expect(!FrameType.profile.isReplayable)
    }

    @Test func relayEnvelopesKnowTheirShape() {
        #expect(RelayEnvelope(type: .chat, id: "m", senderId: "a", payload: []).isRoomPost)
        #expect(RelayEnvelope(type: .chat, id: "m", senderId: "a", recipientId: "b", payload: []).isDirect)
        let group = GroupInfo(id: "g-1", members: ["a"], createdBy: "a")
        let groupPost = RelayEnvelope(type: .chat, id: "m", senderId: "a", group: group, payload: [])
        #expect(!groupPost.isRoomPost && !groupPost.isDirect)
        let relayed = WireEnvelope(ttl: 20, hops: 2, sig: [1], signed: [2]).relayed()
        #expect(relayed == WireEnvelope(ttl: 8, hops: 3, sig: [1], signed: [2]))
    }
}

@Suite struct TextLimitsTests {
    @Test func normalizationTrimsAndCollapsesUnicodeWhitespaceAsOnART() {
        #expect(TextLimits.normalizeSingleLine("  Ann   Lee \t") == "Ann Lee")
        #expect(TextLimits.normalizeSingleLine("a\n\n\tb") == "a b")
        // Kotlin's trim() is Unicode-wide: a no-break space at the ends goes.
        #expect(TextLimits.normalizeSingleLine("\u{00A0}Ann\u{2003}") == "Ann")
        // Java's \s on ART is Unicode White_Space: a no-break space inside collapses too.
        #expect(TextLimits.normalizeSingleLine("Ann\u{00A0}\u{00A0}Lee") == "Ann Lee")
        // The two sets differ: trim() keeps U+0085 and \s takes it; \s keeps U+001F and trim() takes it.
        #expect(TextLimits.normalizeSingleLine("\u{0085}Ann") == " Ann")
        #expect(TextLimits.normalizeSingleLine("\u{001F}Ann\u{001F}\u{001F}Lee") == "Ann\u{001F}\u{001F}Lee")
        #expect(TextLimits.normalizeSingleLine(" \t ").isEmpty)
    }

    /// Every code point against the two sets knit-next's instrumented test read on ART (`ArtTextSemanticsTest`), through
    /// what each one decides: `isBlank` for Kotlin's `isWhitespace`, and a collapse inside a name for regex `\s`.
    @Test func everyCodePointIsWhitespaceExactlyWhereARTSaysSo() {
        var kotlin: [UInt32] = []
        var regex: [UInt32] = []
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else {
                continue
            }
            if TextLimits.isBlank(String(scalar)) {
                kotlin.append(value)
            }
            if TextLimits.collapsingWhitespaceRuns("a\(scalar)b") == "a b" {
                regex.append(value)
            }
        }
        #expect(kotlin == Self.artIsWhitespace)
        #expect(regex == Self.artRegexWhitespace)
    }

    /// Kotlin's `Char.isWhitespace()` on ART, as `ArtTextSemanticsTest` read it.
    private static let artIsWhitespace: [UInt32] =
        Array(0x09...0x0D) + Array(0x1C...0x20) + [0xA0, 0x1680] + Array(0x2000...0x200A)
        + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

    /// Java's regex `\s` on ART, as `ArtTextSemanticsTest` read it.
    private static let artRegexWhitespace: [UInt32] =
        Array(0x09...0x0D) + [0x20, 0x85, 0xA0, 0x1680] + Array(0x2000...0x200A) + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

    @Test func truncationCountsUTF16Units() {
        let name = String(repeating: "a", count: 40)
        #expect(TextLimits.truncated(name, toUTF16: TextLimits.displayName).utf16.count == 32)
        // An emoji is two UTF-16 units; one that would straddle the limit is left out whole.
        let emojiName = String(repeating: "a", count: 31) + "😀"
        #expect(TextLimits.truncated(emojiName, toUTF16: 32) == String(repeating: "a", count: 31))
        #expect(TextLimits.truncated("short", toUTF16: 32) == "short")
    }

    @Test func reactionsMustBeNonBlankAndShort() {
        #expect(TextLimits.isValidReaction("👍"))
        #expect(!TextLimits.isValidReaction(" "))
        #expect(!TextLimits.isValidReaction(""))
        #expect(!TextLimits.isValidReaction(String(repeating: "👍", count: 17)))
    }

    /// This port's own rule on top of Android's: a reaction is one emoji, whatever the emoji, including one newer than
    /// this build's Unicode tables (U+1FAFF, in the emoji planes).
    @Test(arguments: [
        "👍", "\u{2764}\u{FE0F}", "😂", "😮", "😢", "🙏", "👍🏽", "🇺🇸", "1\u{FE0F}\u{20E3}", "👨\u{200D}👩\u{200D}👧", "🔥",
        "\u{1FAE8}", "\u{1FAFF}",
    ])
    func aReactionThatIsOneEmojiIsAccepted(emoji: String) {
        #expect(TextLimits.isSingleEmoji(emoji))
        #expect(TextLimits.isAcceptedReaction(emoji))
    }

    @Test(arguments: ["lol", "a", "1", "#", "\u{2764}", "\u{00A9}", "👍👍", "👍 ", " ", "", "\u{1FB00}"])
    func aReactionThatIsNotOneEmojiIsRefused(text: String) {
        #expect(!TextLimits.isAcceptedReaction(text))
    }

    /// `GroupDetailsViewModel.rename`: one line, at most 32 units, and never blank.
    @Test func aRenameIsNormalizedCutAndNeverBlank() {
        #expect(TextLimits.outgoingGroupName("  Hiking\t\tclub ") == "Hiking club")
        #expect(TextLimits.outgoingGroupName(String(repeating: "a", count: 40)) == String(repeating: "a", count: 32))
        #expect(TextLimits.outgoingGroupName(" \t ") == nil)
        #expect(TextLimits.outgoingGroupName("") == nil)
    }

    /// `InboundPipeline.reconcileGroup`: a received name is only cut, and a blank one is no name at all.
    @Test func aReceivedNameIsCutButNotNormalized() {
        #expect(TextLimits.incomingGroupName("Hiking  club") == "Hiking  club")
        #expect(TextLimits.incomingGroupName(String(repeating: "b", count: 33)) == String(repeating: "b", count: 32))
        #expect(TextLimits.incomingGroupName("   ") == nil)
        #expect(TextLimits.incomingGroupName(nil) == nil)
    }
}

@Suite struct GroupInfoTests {
    /// `GroupInfo.MAX_MEMBERS` and `GROUP_ID_PREFIX`, which every platform must share.
    @Test func theRosterCapAndIdPrefixAreKnitNexts() {
        #expect(GroupInfo.maxMembers == 8)
        #expect(GroupInfo.idPrefix == "g-")
    }
}

/// A deterministic generator for tests: it counts.
struct CountingGenerator: RandomNumberGenerator {
    private var state: UInt64 = 0

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return state
    }
}
