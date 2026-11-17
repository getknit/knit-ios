import KnitWire
import Testing

/// The rules every door that stores or dials a relay agrees on (knit-next's `SpoolUrlTest`, ADR 2026-11.adrq). The
/// build document's URL and the ticket host are Android's alone and are not ported.
@Suite struct SpoolURLTests {
    @Test func aSchemeIsReadIgnoringItsCase() {
        #expect(SpoolURL.isAcceptable("WSS://relay.example.org/spool/v1", allowCleartext: false))
        #expect(SpoolURL.isAcceptable("Wss://relay.example.org/spool/v1", allowCleartext: false))
        #expect(SpoolURL.isAcceptable("WS://10.0.0.5:8080/spool/v1", allowCleartext: true))
    }

    @Test func caseDoesNotWidenWhatAReleaseBuildMayDial() {
        #expect(!SpoolURL.isAcceptable("WS://10.0.0.5:8080/spool/v1", allowCleartext: false))
        #expect(!SpoolURL.isAcceptable("ws://10.0.0.5:8080/spool/v1", allowCleartext: false))
        #expect(!SpoolURL.isAcceptable("HTTPS://relay.example.org/spool/v1", allowCleartext: true))
        #expect(!SpoolURL.isAcceptable("relay.example.org/spool/v1", allowCleartext: true))
        #expect(!SpoolURL.isAcceptable("", allowCleartext: true))
        #expect(!SpoolURL.isAcceptable("wss:/", allowCleartext: true))
    }

    /// The one departure from Kotlin: its `startsWith(ignoreCase = true)` folds the long s into `s`; this build refuses
    /// a scheme that is not ASCII.
    @Test func aSchemeSpelledWithALongSIsRefused() {
        #expect(!SpoolURL.isAcceptable("w\u{017F}s://relay.example.org/spool/v1", allowCleartext: true))
        #expect(SpoolURL.canonical("w\u{017F}s://relay.example.org/spool/v1") == "w\u{017F}s://relay.example.org/spool/v1")
    }

    @Test func theStoredFormLowercasesTheSchemeAndNothingElse() {
        #expect(SpoolURL.canonical("WSS://Relay.Example.ORG/Spool/v1?k=SeCrEt") == "wss://Relay.Example.ORG/Spool/v1?k=SeCrEt")
        #expect(SpoolURL.canonical("WS://10.0.0.5:8080/spool/v1") == "ws://10.0.0.5:8080/spool/v1")
        #expect(SpoolURL.canonical("wss://relay.example.org/spool/v1") == "wss://relay.example.org/spool/v1")
        #expect(SpoolURL.canonical("HTTPS://relay.example.org") == "HTTPS://relay.example.org")
    }

    @Test func theRenamedHouseRelayFoldsToItsCurrentNameKeepingThePortPathAndToken() {
        #expect(SpoolURL.canonical("wss://lax.spool.getknit.app/spool/v1") == SpoolURL.house)
        #expect(
            SpoolURL.canonical("WSS://LAX.spool.getknit.app:8443/spool/v1?k=SeCrEt")
                == "wss://public-1.spool.getknit.app:8443/spool/v1?k=SeCrEt"
        )
        #expect(SpoolURL.canonical("wss://lax.spool.getknit.app?k=t") == "wss://public-1.spool.getknit.app?k=t")
        #expect(SpoolURL.canonical("wss://u@lax.spool.getknit.app/spool/v1") == "wss://u@public-1.spool.getknit.app/spool/v1")
        #expect(SpoolURL.canonical(SpoolURL.house) == SpoolURL.house)
    }

    @Test func onlyTheExactFormerHostIsRenamedNeverTheLabUnderIt() {
        for url in [
            "wss://lab.lax.spool.getknit.app/spool/v1",
            "wss://stun.lab.lax.spool.getknit.app/x",
            "wss://lax.spool.getknit.app.evil/spool/v1",
            "wss://relay.example.org/lax.spool.getknit.app",
            "wss://[::1]:9470/spool/v1",
        ] {
            #expect(SpoolURL.canonical(url) == url)
        }
    }

    /// A combining mark after a separator leaves the separator whole: the text is read as bytes, as Kotlin reads chars.
    @Test func aCombiningMarkNeverHidesASeparator() {
        #expect(SpoolURL.redact("wss://relay.example.org/spool/v1?\u{301}k=secret") == "wss://relay.example.org/spool/v1")
        #expect(SpoolURL.host("wss://relay.example.org/\u{301}spool/v1") == "relay.example.org")
    }

    @Test func theHostRowAndTheRedactionDoNotCareAboutCase() {
        #expect(SpoolURL.host("WSS://relay.example.org/spool/v1?k=secret-token") == "relay.example.org")
        #expect(SpoolURL.redact("WSS://relay.example.org/spool/v1?k=secret-token") == "WSS://relay.example.org/spool/v1")
        #expect(SpoolURL.host("wss://relay.example.org:9470?k=secret-token") == "relay.example.org:9470")
    }

    @Test func aRowNeverRendersEmpty() {
        #expect(SpoolURL.host("relay.example.org?k=secret-token") == "relay.example.org")
        #expect(SpoolURL.host("wss:///spool/v1") == "wss:///spool/v1")
        #expect(SpoolURL.host("ws") == "ws")
    }

    /// A plain URL's shown host is its dialled host (P1's security review): printable ASCII, no user info, no backslash.
    @Test func aPlainURLShowsTheHostItDials() {
        for plain in [SpoolURL.house, "wss://relay.example.org:9470/spool/v1?k=a@b", "ws://10.0.0.5/spool/v1#x@y"] {
            #expect(SpoolURL.isPlain(plain), "\(plain)")
        }
        for spoof in [
            "wss://relay.example@other.example/spool/v1",
            "wss://relay.example\\@other.example/spool/v1",
            "wss://other.example\\relay.example/spool/v1",
            "wss://relay.example.org /spool/v1",
            "wss://\u{202E}gro.elpmaxe/spool/v1",
            "wss://r\u{0435}lay.example/spool/v1",
            "wss://relay.example.org/spool/v1\u{7F}",
        ] {
            #expect(!SpoolURL.isPlain(spoof), "\(spoof)")
        }
    }
}
