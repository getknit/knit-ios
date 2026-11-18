import Testing

@testable import KnitWire

/// The one address a relay's socket is opened to (ADR 2026-11.adrq, P4b1): what the factory takes and refuses, and that it
/// prints its host alone.
@Suite struct AcceptedSpoolURLTests {
    @Test func aPlainSecureAddressIsTakenInItsStoredForm() throws {
        let url = try #require(AcceptedSpoolURL("WSS://relay.example.org:8443/spool/v1?k=secret", allowCleartext: false))
        #expect(url.socketURLText == "wss://relay.example.org:8443/spool/v1?k=secret")
        #expect(url == AcceptedSpoolURL("wss://relay.example.org:8443/spool/v1?k=secret", allowCleartext: false))
        let house = try #require(AcceptedSpoolURL("wss://lax.spool.getknit.app/spool/v1", allowCleartext: false))
        #expect(house.socketURLText == SpoolURL.house, "a renamed house relay folds on the way in")
    }

    @Test func userInfoABackslashNonASCIIAFragmentAndLengthAreRefused() {
        let refused = [
            "wss://user@relay.example.org/spool/v1",
            "wss://user:pass@relay.example.org/spool/v1",
            "wss://relay.example.org\\@evil.example/spool/v1",
            "wss://relay.exämple.org/spool/v1",
            "wss://relay.example.org/spool/v1 ",
            "wss://relay.example.org/spool/v1#k=x",
            "wss://relay.example.org/" + String(repeating: "a", count: AcceptedSpoolURL.maxBytes),
            "https://relay.example.org/spool/v1",
            "relay.example.org/spool/v1",
            "",
        ]
        for raw in refused {
            #expect(AcceptedSpoolURL(raw, allowCleartext: true) == nil, "\(raw.count) bytes refused")
        }
        let longest = "wss://r/" + String(repeating: "a", count: AcceptedSpoolURL.maxBytes - 8)
        #expect(AcceptedSpoolURL(longest, allowCleartext: false) != nil, "exactly the limit is taken")
    }

    /// A host is read once: an authority holding a `%` is refused in either scheme, since a parser that decodes it would
    /// dial another host than the one printed. A `%` after the authority is the path's or the query's.
    @Test func aPercentInTheAuthorityIsRefusedAndOneAfterItIsNot() {
        let refused = [
            "wss://relay%2Eexample.org/spool/v1", "wss://relay.example.org%3A443/spool/v1", "wss://relay.example.org:%34%34%33/spool/v1",
            "wss://%72elay.example.org/spool/v1", "wss://[::1%25en0]/spool/v1", "wss://relay.example.org%/spool/v1",
            "ws://127.0.0.1%2E/spool/v1", "ws://[fe80::1%25en0]:9470/spool/v1", "ws://127.0.0.1:94%370/spool/v1",
        ]
        for raw in refused {
            #expect(AcceptedSpoolURL(raw, allowCleartext: true) == nil, "\(raw) refused")
        }
        #expect(AcceptedSpoolURL("wss://relay.example.org/spool%2Fv1?x=%41", allowCleartext: false) != nil, "a path's and a value's")
        #expect(AcceptedSpoolURL("ws://127.0.0.1:9470/spool/v1?x=%41", allowCleartext: true) != nil, "a cleartext value's")
        #expect(AcceptedSpoolURL("wss://relay.example.org?%6B=1", allowCleartext: false) != nil, "a query right after the host")
    }

    @Test func cleartextIsRefusedWhenNotAllowed() {
        #expect(AcceptedSpoolURL("ws://127.0.0.1:9470/spool/v1", allowCleartext: false) == nil)
        #expect(AcceptedSpoolURL("WS://10.0.0.5/spool/v1", allowCleartext: false) == nil)
    }

    @Test func cleartextGoesOnlyToThisPhoneOrItsNetworkAndNeverWithAToken() {
        let local = [
            "ws://127.0.0.1:9470/spool/v1", "ws://localhost:9470/spool/v1", "ws://10.1.2.3/spool/v1", "ws://172.16.0.1/spool/v1",
            "ws://172.31.255.255/spool/v1", "ws://192.168.1.20:80/spool/v1", "ws://169.254.3.4/spool/v1", "ws://[::1]:9470/spool/v1",
            "ws://[fd00::5]/spool/v1", "ws://[FE80::1]/spool/v1", "ws://[fc00:0:0:0:0:0:0:1]/spool/v1",
        ]
        for raw in local {
            #expect(AcceptedSpoolURL(raw, allowCleartext: true) != nil, "\(raw) taken in a debug build")
        }
        let refused = [
            "ws://8.8.8.8/spool/v1", "ws://172.32.0.1/spool/v1", "ws://192.169.0.1/spool/v1", "ws://relay.example.org/spool/v1",
            "ws://[2001:db8::1]/spool/v1", "ws://[::2]/spool/v1", "ws://127.0.0.1/spool/v1?k=secret", "ws://127.0.0.1/spool/v1?a=b&k=s",
            "ws://256.0.0.1/spool/v1", "ws://10.0.0/spool/v1", "ws://1234.0.0.1/spool/v1", "ws://[1::2::3]/spool/v1",
            "ws://[12345::1]/spool/v1", "ws://[::g]/spool/v1", "ws://[1:2:3:4:5:6:7:8:9]/spool/v1", "ws://[::1/spool/v1",
            "ws://[1:2:3:4:5:6:7::8]/spool/v1",
        ]
        for raw in refused {
            #expect(AcceptedSpoolURL(raw, allowCleartext: true) == nil, "\(raw) refused")
        }
        #expect(AcceptedSpoolURL("ws://127.0.0.1/spool/v1?kk=1", allowCleartext: true) != nil, "only a `k=` parameter is a token")
        for raw in ["ws://010.0.0.1/spool/v1", "ws://127.0.0.1/spool/v1?K=s", "ws://127.0.0.1/spool/v1?a=1&%6B=s"] {
            #expect(AcceptedSpoolURL(raw, allowCleartext: true) == nil, "\(raw) refused")
        }
        #expect(AcceptedSpoolURL("ws://10.0.0.1/spool/v1", allowCleartext: true) != nil, "a lone zero is a part")
    }

    @Test func aReleaseBuildRefusesCleartextWhateverTheCallerAsks() {
        #expect(AcceptedSpoolURL("ws://127.0.0.1:9470/spool/v1", allowCleartext: true, debugBuild: false) == nil)
        #expect(AcceptedSpoolURL("ws://127.0.0.1:9470/spool/v1", allowCleartext: true, debugBuild: true) != nil)
        #expect(AcceptedSpoolURL("wss://relay.example.org/spool/v1", allowCleartext: false, debugBuild: false) != nil)
    }

    @Test func itPrintsItsHostAndNothingElse() throws {
        let url = try #require(AcceptedSpoolURL("wss://relay.example.org:8443/spool/v1?k=secret", allowCleartext: false))
        var dumped = ""
        dump(url, to: &dumped)
        for shown in ["\(url)", String(reflecting: url), dumped] {
            #expect(!shown.contains("k=") && !shown.contains("@") && !shown.contains("/spool"), "only the host is shown")
        }
        #expect("\(url)" == "relay.example.org:8443")
        #expect(Mirror(reflecting: url).children.isEmpty)
    }

    /// What a relay list marks private: a `k` key in either case, or any key holding a `%`, the reading the cleartext rule
    /// refuses a token by; a key that only ends in `k`, a bare `k` with no value and a path alone are no token.
    @Test func aTokenIsAKeyKInEitherCaseOrAKeyHoldingAPercent() throws {
        let tokens = ["?k=secret", "?K=secret", "?a=1&k=2", "?%6b=secret", "?k="]
        for query in tokens {
            let url = try #require(AcceptedSpoolURL("wss://relay.example.org/spool/v1" + query, allowCleartext: false))
            #expect(url.carriesToken, "\(query) carries a token")
        }
        let plain = ["", "?token=secret", "?kk=1", "?k", "/private"]
        for rest in plain {
            let url = try #require(AcceptedSpoolURL("wss://relay.example.org/spool/v1" + rest, allowCleartext: false))
            #expect(!url.carriesToken, "\(rest) carries none")
        }
    }
}
