import KnitTestSupport
import KnitWire
import Testing

/// The relay invite (knit-next's `RelayInviteTest`, ADR 2026-11.adrq): the three golden links, both link forms, every
/// refusal, the issuer and key's shape rules a build without Knit Anywhere still applies, and a parser that survives
/// any text. This build reads `u` alone, so the room's secret and name and the issuer's key are checked, never kept.
@Suite struct RelayInviteTests {
    private static let privateURL = "wss://home.example.org/spool/v1?k=fixture-token"
    private static let publicURL = "wss://lax.spool.getknit.app/spool/v1"
    private static let ticketURL = "wss://lab.example.org/spool/v1?k=fixture-token"
    private static let issuer = "https://anywhere.example.org"
    private static let key = "kak1_FBsiKTA3PkVMU1phaG92fYSLkpmgp661vMPK0djf5u0"

    private static func link(_ fields: [(String, CBOR)]) -> String {
        let body = CBOR.map(fields.map { CBOR.Entry(key: .text($0.0), value: $0.1) })
        return RelayInvite.urlPrefix + Base64.encode(body.encoded, variant: .urlSafeUnpadded)
    }

    private static func parsed(_ text: String, allowCleartext: Bool = false) -> RelayInvite.Invite? {
        guard case .invite(let invite) = RelayInvite.parse(text, allowCleartext: allowCleartext) else {
            return nil
        }
        return invite
    }

    private static func invalid(_ text: String) -> RelayInvite.Reason? {
        guard case .invalid(let reason) = RelayInvite.parse(text, allowCleartext: false) else {
            return nil
        }
        return reason
    }

    @Test(arguments: SpoolVectors.file.relayInvite.keys.sorted())
    func everyGoldenInviteReadsAsItsRelay(name: String) throws {
        let vector = try #require(SpoolVectors.file.relayInvite[name])
        for form in [RelayInvite.urlPrefix + vector.link, RelayInvite.schemePrefix + vector.link] {
            #expect(Self.parsed(form)?.url == vector.url, "\(name)")
        }
    }

    @Test func theBareInviteIsWhatThisBuildMints() throws {
        let bare = try #require(SpoolVectors.file.relayInvite["bareInvite"])
        #expect(RelayInvite.mint(url: bare.url) == bare.link)
        #expect(RelayInvite.mint(url: "  \(bare.url)\n") == bare.link)
    }

    @Test func anInviteIsFoundAnywhereInText() throws {
        let compact = try #require(SpoolVectors.file.relayInvite["fullInvite"]).link
        for form in [
            "Join my Knit relay: \(RelayInvite.urlPrefix)\(compact) — see you there",
            "  \(RelayInvite.schemePrefix)\(compact)\n",
        ] {
            #expect(Self.parsed(form)?.url == Self.privateURL)
        }
    }

    @Test func theTokenSurvivesByteForByte() {
        let tokened = "wss://spool.example.org:9470/spool/v1?k=s3cret-T0ken_with=chars"
        #expect(Self.parsed(RelayInvite.urlPrefix + RelayInvite.mint(url: tokened))?.url == tokened)
    }

    @Test func theRefusalReasonsAreSpecific() throws {
        let compact = try #require(SpoolVectors.file.relayInvite["fullInvite"]).link
        #expect(Self.invalid("") == .notAnInvite)
        #expect(Self.invalid("hello there") == .notAnInvite)
        #expect(Self.invalid("https://getknit.app/") == .notAnInvite)
        #expect(Self.invalid(RelayInvite.urlPrefix) == .notAnInvite)
        #expect(Self.invalid(compact) == .notAnInvite, "there is no bare form")
        #expect(Self.invalid(RelayInvite.urlPrefix + "AAAA") == .malformed)
        #expect(Self.invalid(RelayInvite.urlPrefix + String(repeating: "A", count: 4000)) == .tooLarge)
        #expect(Self.invalid(Self.link([("v", .unsigned(2)), ("u", .text(Self.publicURL))])) == .badVersion)
        #expect(
            Self.invalid(Self.link([("v", .unsigned(1)), ("u", .text(Self.publicURL)), ("c", .bytes([UInt8](repeating: 0, count: 31)))]))
                == .badSecret)
        for url in [
            "", "https://spool.example/spool/v1", "wss://spool.example/spool/v1 ", "wss://spool.example/\u{7}",
            "wss://" + String(repeating: "a", count: 300),
        ] {
            #expect(Self.invalid(Self.link([("v", .unsigned(1)), ("u", .text(url))])) == .badURL, "\(url)")
        }
    }

    /// Kotlin's `isWhitespace` counts the no-break space, which Java's `Character.isWhitespace` does not.
    @Test func aNoBreakSpaceInTheURLRefusesTheInvite() {
        #expect(Self.invalid(Self.link([("v", .unsigned(1)), ("u", .text("wss://spool.example\u{A0}/spool/v1"))])) == .badURL)
    }

    /// An invite whose host could be shown as another's is refused (P1's security review): user info, a backslash, a bidi
    /// override, a lookalike letter.
    @Test func anInviteWhoseShownHostIsNotItsDialledHostIsRefused() {
        for url in [
            "wss://relay.example@other.example/spool/v1",
            "wss://other.example\\relay.example/spool/v1",
            "wss://\u{202E}gro.elpmaxe/spool/v1",
            "wss://r\u{0435}lay.example/spool/v1",
        ] {
            #expect(Self.invalid(Self.link([("v", .unsigned(1)), ("u", .text(url))])) == .badURL, "\(url)")
        }
    }

    /// 684 symbols, the most read, decode to 513 bytes: one past the body's bound.
    @Test func aCompactTextAtItsBoundThatDecodesPastTheBodysIsTooLarge() {
        #expect(Self.invalid(RelayInvite.urlPrefix + String(repeating: "A", count: 684)) == .tooLarge)
    }

    @Test func aBodyPastFiveHundredTwelveBytesIsTooLarge() {
        let padded = Self.link([("v", .unsigned(1)), ("u", .text(Self.publicURL)), ("later", .bytes([UInt8](repeating: 1, count: 480)))])
        #expect(Self.invalid(padded) == .tooLarge)
    }

    @Test func theTicketInviteIsTheRelayAloneHere() throws {
        let compact = try #require(SpoolVectors.file.relayInvite["ticketInvite"]).link
        #expect(Self.parsed(RelayInvite.urlPrefix + compact) == RelayInvite.Invite(url: Self.ticketURL))
    }

    @Test func anIssuerAndAKeyComeTogetherOrTheInviteIsRefused() {
        #expect(Self.invalid(Self.link([("v", .unsigned(1)), ("u", .text(Self.ticketURL)), ("i", .text(Self.issuer))])) == .badKey)
        #expect(Self.invalid(Self.link([("v", .unsigned(1)), ("u", .text(Self.ticketURL)), ("k", .text(Self.key))])) == .badIssuer)
    }

    @Test func aKeyThatIsNotACustomerKeysShapeRefusesTheInvite() {
        let refused = [
            "", "kak1_", String(Self.key.dropLast()), Self.key + "A", "kak2_" + Self.key.dropFirst(5), Self.key.dropLast() + "=",
            Self.key.dropLast() + "+",
        ]
        for bad in refused {
            let text = Self.link([("v", .unsigned(1)), ("u", .text(Self.ticketURL)), ("i", .text(Self.issuer)), ("k", .text(String(bad)))])
            #expect(Self.invalid(text) == .badKey, "\(bad)")
        }
    }

    @Test func anIssuerMustBeABareOrigin() {
        let refused = [
            "https://anywhere.example.org/", "https://anywhere.example.org/api", "https://anywhere.example.org?x=1",
            "https://anywhere.example.org#f", "https://user@anywhere.example.org", "HTTPS://anywhere.example.org",
            "https://Anywhere.example.org", "https://anywhere.example.org:0", "https://anywhere.example.org:65536",
            "https://anywhere.example.org:080", "wss://anywhere.example.org", "https://", "https://anywhere .example.org",
            "https://" + String(repeating: "a", count: 128), "https://-a.example.org", "https://a..example.org", "https://[]",
            "https://[::G]", "https://anywhere.example.org:", "https://anywhere.ex\u{E1}mple.org",
        ]
        for bad in refused {
            let text = Self.link([("v", .unsigned(1)), ("u", .text(Self.ticketURL)), ("i", .text(bad)), ("k", .text(Self.key))])
            #expect(Self.invalid(text) == .badIssuer, "\(bad)")
        }
        for good in [
            "https://anywhere.example.org:8443", "https://10.0.2.2", "https://[::1]:3000", "https://localhost", "https://a-b.c:65535",
        ] {
            let text = Self.link([("v", .unsigned(1)), ("u", .text(Self.ticketURL)), ("i", .text(good)), ("k", .text(Self.key))])
            #expect(Self.parsed(text) == RelayInvite.Invite(url: Self.ticketURL), "\(good)")
        }
    }

    @Test func aCleartextIssuerIsRefusedUnlessTheBuildAllowsIt() {
        let local = Self.link([
            ("v", .unsigned(1)), ("u", .text(Self.ticketURL)), ("i", .text("http://127.0.0.1:3000")), ("k", .text(Self.key)),
        ])
        #expect(Self.invalid(local) == .badIssuer)
        #expect(Self.parsed(local, allowCleartext: true)?.url == Self.ticketURL)
    }

    @Test func aCleartextRelayIsRefusedUnlessTheBuildAllowsIt() {
        let link = RelayInvite.urlPrefix + RelayInvite.mint(url: "ws://lab.spool/spool/v1")
        #expect(Self.invalid(link) == .badURL)
        #expect(Self.parsed(link, allowCleartext: true)?.url == "ws://lab.spool/spool/v1")
    }

    @Test func anInviteIsNeverACardAndACardIsNeverAnInvite() throws {
        let compact = try #require(SpoolVectors.file.relayInvite["fullInvite"]).link
        #expect(RelayInvite.looksLikeInvite(RelayInvite.urlPrefix + compact))
        #expect(RelayInvite.looksLikeInvite(RelayInvite.schemePrefix + compact))
        #expect(!RelayInvite.looksLikeInvite("https://getknit.app/c#" + String(repeating: "A", count: 240)))
        #expect(!RelayInvite.looksLikeInvite("knit://c/" + String(repeating: "A", count: 240)))
        #expect(!RelayInvite.looksLikeInvite("just some text"))
        #expect(!RelayInvite.looksLikeInvite(RelayInvite.schemePrefix))
    }

    @Test func theParsedInviteNeverPrintsItsToken() throws {
        let compact = try #require(SpoolVectors.file.relayInvite["fullInvite"]).link
        let invite = try #require(Self.parsed(RelayInvite.urlPrefix + compact))
        var dumped = ""
        dump(invite, to: &dumped)
        for shown in [String(describing: invite), String(reflecting: invite), "\(RelayInvite.Parsed.invite(invite))", dumped] {
            #expect(!shown.contains("fixture-token"), "\(shown)")
            #expect(shown.contains("home.example.org"), "\(shown)")
        }
    }

    @Test func parseNeverTrapsOnArbitraryInput() throws {
        var generator = SplitMix(state: 42)
        let compact = try #require(SpoolVectors.file.relayInvite["fullInvite"]).link
        for _ in 0..<500 {
            let junk = (0..<Int.random(in: 0..<600, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = RelayInvite.parse(RelayInvite.urlPrefix + Base64.encode(junk, variant: .urlSafeUnpadded), allowCleartext: false)
            // Lossy on purpose: every input becomes some string, replacement characters included.
            // swiftlint:disable:next optional_data_string_conversion
            _ = RelayInvite.parse(RelayInvite.schemePrefix + String(decoding: junk, as: UTF8.self), allowCleartext: false)
        }
        for length in 0..<compact.count {
            _ = RelayInvite.parse(RelayInvite.urlPrefix + compact.prefix(length), allowCleartext: false)
        }
        _ = RelayInvite.parse(RelayInvite.schemePrefix + "!!!", allowCleartext: false)
    }
}

/// SplitMix64, so the arbitrary inputs above are the same on every run.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
