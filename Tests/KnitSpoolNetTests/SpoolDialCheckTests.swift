import Foundation
import KnitWire
import Testing

@testable import KnitSpoolNet

/// The dial's address check (ADR 2026-11.adrq, P5): the whole factory again, one parse of the host, and the URL Foundation
/// builds printing as the accepted text. It runs on every platform, since Foundation's `URLComponents` is the same parser.
@Suite struct SpoolDialCheckTests {
    private func accepted(_ text: String, cleartext: Bool = true) throws -> AcceptedSpoolURL {
        try #require(AcceptedSpoolURL(text, allowCleartext: cleartext), "\(text) is accepted")
    }

    @Test func anAcceptedAddressDialsAsItsOwnText() throws {
        for text in [
            "wss://relay.example.org:8443/spool/v1?k=secret", "wss://public-1.spool.getknit.app/spool/v1", "ws://127.0.0.1:9470/spool/v1",
            "ws://[::1]:9470/spool/v1", "ws://localhost/spool/v1", "wss://relay.example.org./spool/v1", "wss://relay.example.org?x=1",
        ] {
            let url = try accepted(text)
            let target = try #require(SpoolDialCheck.target(for: url, cleartext: true), "\(text) dials")
            #expect(target.absoluteString == text)
        }
    }

    /// The whole factory again with the build's flag: an address only a cleartext build takes is refused by one that is not.
    @Test func cleartextDialsOnlyWhereTheBuildDialsIt() throws {
        let url = try accepted("ws://127.0.0.1:9470/spool/v1")
        #expect(SpoolDialCheck.target(for: url, cleartext: false) == nil)
        #expect(SpoolDialCheck.target(for: try accepted("wss://relay.example.org/spool/v1"), cleartext: false) != nil)
    }

    /// Texts the factory takes whose host or port another reading of the same bytes sees differently, or which Foundation
    /// would print otherwise: each is refused at the dial.
    @Test func aHostOrPortThatReadsTwoWaysIsRefused() throws {
        for text in [
            "wss://relay.example.org:0443/spool/v1", "wss://relay.example.org:/spool/v1", "wss://relay.example.org:99999/spool/v1",
            "wss://relay.example.org:0/spool/v1", "wss://:443/spool/v1", "wss:///spool/v1", "wss://relay.example.org:1:2/spool/v1",
            "wss://[::1]x/spool/v1", "wss://relay.example.org/a|b", "wss://relay.example.org/spool/v1?x={y}",
        ] {
            let url = try accepted(text, cleartext: false)
            #expect(SpoolDialCheck.target(for: url, cleartext: true) == nil, "\(text) refused")
        }
    }

    /// Hosts built from the pieces a parser could read two ways: percent-encoded, trailing-dot, double-port and bracketed. No
    /// address with a `%` in its authority gets past the factory, and every one the check dials has the host and port
    /// ``SpoolURL/host(_:)`` reads, byte for byte.
    @Test func everyDialledHostIsTheHostSpoolURLReads() {
        let hosts = [
            "relay.example.org", "relay.example.org.", "RELAY.example.org", "127.0.0.1", "127.0.0.1.", "[::1]", "[fe80::1]", "[v1.x]",
            "[::1]x", "[::1%25en0]", "rel%61y.example.org", "%72elay", "relay%2eexample.org", "relay.example.org%", "a_b", "0x7f.1",
            "", "[", "]", "[]",
        ]
        let ports = ["", ":", ":0", ":443", ":0443", ":65535", ":65536", ":+1", ":-1", ":1:2", ":%34%34", ":44%33", "::"]
        var dialled = 0
        for scheme in ["wss://", "ws://"] {
            for host in hosts {
                for port in ports {
                    let text = scheme + host + port + "/spool/v1"
                    for cleartext in [false, true] {
                        guard let url = AcceptedSpoolURL(text, allowCleartext: cleartext) else {
                            continue
                        }
                        #expect(!(host + port).contains("%"), "\(text) has a % in its authority and was accepted")
                        guard let target = SpoolDialCheck.target(for: url, cleartext: cleartext) else {
                            continue
                        }
                        dialled += 1
                        let parsed = URLComponents(string: target.absoluteString)
                        let read = (parsed?.percentEncodedHost ?? "") + (parsed?.port.map { ":\($0)" } ?? "")
                        #expect(read == SpoolURL.host(url.socketURLText), "\(text) reads one host")
                        #expect(read == host + port, "\(text) dials the host it was given")
                        #expect(target.absoluteString == url.socketURLText)
                    }
                }
            }
        }
        #expect(dialled > 0, "some addresses dial")
    }

    /// The same, over random authorities drawn from the characters an authority may hold, from a fixed seed.
    @Test func randomAuthoritiesDialOnlyAsTheyRead() {
        let alphabet = Array("ab1.:[]%25e-_~!$&'()*+,;=")
        var generator = SplitMix(seed: 0x5EED)
        for _ in 0..<4000 {
            let length = Int(generator.next() % 12)
            let authority = String((0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
            for text in ["wss://\(authority)/spool/v1", "ws://\(authority)/spool/v1"] {
                guard let url = AcceptedSpoolURL(text, allowCleartext: true) else {
                    continue
                }
                #expect(!authority.contains("%"), "\(text) accepted with a % in its authority")
                guard let target = SpoolDialCheck.target(for: url, cleartext: true) else {
                    continue
                }
                let parsed = URLComponents(string: target.absoluteString)
                let read = (parsed?.percentEncodedHost ?? "") + (parsed?.port.map { ":\($0)" } ?? "")
                #expect(read == authority && read == SpoolURL.host(text), "\(text) dials \(read)")
            }
        }
    }
}

/// SplitMix64, so the random authorities are the same on every run.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
