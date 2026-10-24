import Foundation
import KnitTestSupport
import KnitWire
import Testing

/// The id shapes the router admits (knit-next ADR 2026-10.9qr4, #178), row by row from `FrameIdTest.kt` at knit-next
/// `a81f2050`: what every build mints, a profile's `profile-<sender>-<stamp>`, and Android's walkie chunk's short prefix.
/// Android's database drops a leading U+FEFF from every id it binds and byte-swaps the rest after a leading U+FFFE, so an
/// id the gate lets through must be one no table can confuse with another; the Kelvin and combining-acute rows are this
/// port's own, the shapes Swift's `==` and `count` are fooled by (ADR 2026-09.jc2x).
@Suite struct FrameIdAdmitsTests {
    private let alice = fixtureNodeId(1).string
    private let bob = fixtureNodeId(2).string

    private func envelope(_ id: String, type: FrameType = .chat, sender: String? = nil, sentAt: Int64 = 1_700_000_000) -> RelayEnvelope {
        RelayEnvelope(type: type, id: id, senderId: sender ?? alice, sentAt: sentAt, payload: [])
    }

    private func minted(_ seed: UInt64 = 1) -> String {
        var generator = SplitMix(state: seed)
        return FrameId.generate(using: &generator)
    }

    @Test func everyIdTheAppMintsIsAdmitted() {
        #expect(FrameId.admits(envelope(minted())))
        #expect(FrameId.admits(envelope(minted(2), type: .receipt)))
        #expect(FrameId.admits(envelope(String(minted(3).prefix(FrameId.talkLength)), type: .talk)))
        let stamp: Int64 = 1_700_000_000_123
        #expect(FrameId.admits(envelope(FrameId.profileId(sender: alice, publishedAt: stamp), type: .profile, sentAt: stamp)))
    }

    @Test func aProfileIdIsItsSenderAndStampSpelledOutSoAStampOfZeroOrBelowIsAdmittedToo() {
        #expect(FrameId.profileId(sender: alice, publishedAt: 42) == "profile-\(alice)-42")
        #expect(FrameId.admits(envelope("profile-\(alice)-0", type: .profile, sentAt: 0)))
        #expect(FrameId.admits(envelope("profile-\(alice)--5", type: .profile, sentAt: -5)))
        #expect(FrameId.admits(envelope("profile-\(alice)-\(Int64.max)", type: .profile, sentAt: .max)))
    }

    @Test func anUnknownTypeIsHeldToTheMintedShape() {
        let future = FrameType(rawValue: "future")
        #expect(FrameId.admits(envelope(minted(), type: future)))
        #expect(!FrameId.admits(envelope("m1", type: future)))
    }

    @Test func aLeadingByteOrderMarkOrItsSwappedTwinIsRefusedOnEveryType() {
        let id = minted()
        // Each UTF-16 unit of the id byte-swapped, as SQLite reads the rest of a string after a leading U+FFFE.
        let swapped = String(
            String.UnicodeScalarView(id.unicodeScalars.compactMap { Unicode.Scalar(($0.value & 0xFF) << 8 | $0.value >> 8) }))
        for crafted in ["\u{FEFF}" + id, "\u{FFFE}" + swapped, "\u{FEFF}" + id.dropFirst()] {
            #expect(!FrameId.admits(envelope(crafted)), "\(Array(crafted.utf8))")
        }
        let talk = String(id.prefix(FrameId.talkLength))
        #expect(!FrameId.admits(envelope("\u{FEFF}" + talk.dropFirst(), type: .talk)))
        let profile = "\u{FEFF}" + FrameId.profileId(sender: alice, publishedAt: 7)
        #expect(!FrameId.admits(envelope(profile, type: .profile, sentAt: 7)))
    }

    @Test func aFrameIdMustRoundTripNotMerelyLookLikeOne() {
        let id = minted()
        #expect(!FrameId.admits(envelope(String(id.dropLast()))))
        #expect(!FrameId.admits(envelope(id + "A")))
        #expect(!FrameId.admits(envelope(id + "==")))
        #expect(!FrameId.admits(envelope("+" + id.dropFirst())))
        #expect(!FrameId.admits(envelope("/" + id.dropFirst())))
        // The last character of a 16-byte id carries two padding bits, which must be zero: only A, Q, g and w round-trip.
        #expect(!FrameId.admits(envelope(String(id.dropLast()) + "B")))
        #expect(!FrameId.admits(envelope("")))
    }

    @Test func aProfileIdIsBoundToItsSenderAndStamp() {
        let stamp: Int64 = 1_700_000_000_123
        #expect(!FrameId.admits(envelope(FrameId.profileId(sender: bob, publishedAt: stamp), type: .profile, sentAt: stamp)))
        #expect(!FrameId.admits(envelope(FrameId.profileId(sender: alice, publishedAt: stamp + 1), type: .profile, sentAt: stamp)))
        #expect(!FrameId.admits(envelope("profile-\(alice)-007", type: .profile, sentAt: 7)))
        #expect(!FrameId.admits(envelope("profile-\(alice)", type: .profile, sentAt: 0)))
        #expect(!FrameId.admits(envelope(minted(), type: .profile)))
        // A sender that is not a node id cannot have a profile id, whatever the id spells.
        #expect(!FrameId.admits(envelope("profile-alice-7", type: .profile, sender: "alice", sentAt: 7)))
        let upper = alice.uppercased()
        #expect(!FrameId.admits(envelope("profile-\(upper)-7", type: .profile, sender: upper, sentAt: 7)))
    }

    @Test func aTalkIdIsExactlyTheShortPrefix() {
        let id = minted()
        #expect(!FrameId.admits(envelope(id, type: .talk)))
        #expect(!FrameId.admits(envelope(String(id.prefix(FrameId.talkLength + 1)), type: .talk)))
        #expect(!FrameId.admits(envelope(String(id.prefix(FrameId.talkLength - 1)), type: .talk)))
        #expect(!FrameId.admits(envelope("abc.efgh+jk", type: .talk)))
        // The short prefix is a talk id only: on any other type it is refused.
        #expect(!FrameId.admits(envelope(String(id.prefix(FrameId.talkLength)))))
    }

    /// This port's rows: Swift's `==` is canonical equivalence and `count` counts graphemes, so a check written with
    /// either would admit these. Each is measured and compared by its UTF-8 bytes instead.
    @Test func idsSwiftCallsEqualOrTheRightLengthAreRefused() {
        let canonical = String(repeating: "A", count: 20) + "KA"
        let kelvin = String(repeating: "A", count: 20) + "\u{212A}A"
        #expect(kelvin == canonical && kelvin.count == FrameId.length, "Swift's == and count are both fooled")
        #expect(FrameId.admits(envelope(canonical)))
        #expect(!FrameId.admits(envelope(kelvin)))
        // A combining acute folds onto the letter before it: one more scalar, the same 22 characters.
        let acute = String(repeating: "A", count: 21) + "e\u{301}"
        #expect(acute.count == FrameId.length)
        #expect(!FrameId.admits(envelope(acute)))
        let talk = String(repeating: "A", count: 10) + "\u{212A}"
        #expect(talk.count == FrameId.talkLength)
        #expect(!FrameId.admits(envelope(talk, type: .talk)))
        let profile = FrameId.profileId(sender: alice, publishedAt: 7)
        let decomposed = profile.replacingOccurrences(of: "7", with: "7\u{301}")
        #expect(!FrameId.admits(envelope(decomposed, type: .profile, sentAt: 7)))
    }

    @Test func frameIdOfGivesDistinctAdmittedIdsForDistinctLabels() {
        let labels = ["m1", "m2", "dm-1", "post-1", "gm-1", "x-frame", "", "\u{FEFF}m1", "caf\u{E9}", "cafe\u{301}"]
        let ids = labels.map(frameIdOf)
        #expect(Set(ids).count == labels.count)
        #expect(ids.allSatisfy { FrameId.admits(RelayEnvelope(type: .chat, id: $0, senderId: "s", payload: [])) })
        let again = ["m1", "m2", "dm-1"].map(frameIdOf)
        #expect(again == Array(ids.prefix(3)), "the same label is the same id")
    }

    /// Every envelope the vector files carry is one the gate admits, so a vector frame replayed through the router is
    /// never refused at the door; `wire-v1.json`'s `relayEnvelope` is the codec's decode-only fixture, whose id is `m1`.
    @Test(arguments: ["wire-v1.json", "keyed-v1.json", "ratchet-v1.json", "ios-emitted-v1.json"])
    func everyVectorEnvelopeIsAdmitted(file: String) throws {
        let data = try Data(contentsOf: VectorFile.directory.appendingPathComponent(file))
        var envelopes: [(String, RelayEnvelope)] = []
        Self.collect(try JSONSerialization.jsonObject(with: data), path: file, into: &envelopes)
        #expect(!envelopes.isEmpty, "\(file) carries envelopes")
        for (path, envelope) in envelopes where path != "wire-v1.json.vectors.relayEnvelope" {
            #expect(FrameId.admits(envelope), "\(path): \(envelope.type.rawValue) \(envelope.id)")
        }
    }

    /// Every hex string in a vector file that decodes as a wire envelope's signed bytes, or as a relay envelope itself.
    private static func collect(_ value: Any, path: String, into envelopes: inout [(String, RelayEnvelope)]) {
        switch value {
        case let object as [String: Any]:
            for (key, child) in object {
                collect(child, path: "\(path).\(key)", into: &envelopes)
            }
        case let array as [Any]:
            for (index, child) in array.enumerated() {
                collect(child, path: "\(path)[\(index)]", into: &envelopes)
            }
        case let text as String:
            guard let bytes = Hex.decode(text), !bytes.isEmpty else {
                return
            }
            if let wire = try? WireEnvelope(decoding: bytes), let envelope = try? RelayEnvelope(decoding: wire.signed) {
                envelopes.append((path, envelope))
            } else if let envelope = try? RelayEnvelope(decoding: bytes) {
                envelopes.append((path, envelope))
            }
        default:
            return
        }
    }
}

/// SplitMix64, so a minted id is reproducible.
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
