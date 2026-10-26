import KnitTestSupport
import KnitWire
import Testing

/// Every key Android types and this build does not model is checked as kotlinx types it (knit-ios #14): Android's honest
/// bytes still decode, and the same bytes with one value of the wrong type fail, in both the named and the compact
/// layout, as Android's `canCarry` and its open refuse them (`Wire.kt`, `MessageContent.kt` and `MessageContentV2.kt` at
/// knit-next `e63f15f4`).
@Suite struct TypedKeysTests {
    private func vector(_ name: String) throws -> CBOR { try CBOR.decode(GoldenVectors.bytes(name)) }

    /// A value of every kind but `kind`'s, none of them `null` or `A0`, which a nullable key reads as absent.
    private func wrongKinds(besides kind: String) -> [CBOR] {
        let all: [String: CBOR] = [
            "text": .text("x"), "bytes": .bytes([1]), "int": .unsigned(1), "bool": .bool(true),
            "map": .map([CBOR.Entry(key: .text("q"), value: .unsigned(1))]),
            "array": .array([]), "float": .float(1),
        ]
        return all.filter { $0.key != kind }.map(\.value)
    }

    // MARK: Honest bytes

    @Test func androidsHonestBytesStillDecode() throws {
        for name in ["chatContentVideo", "chatContentStyles"] {
            _ = try ChatContent(decoding: GoldenVectors.bytes(name))
        }
        let named =
            ["messageContentVideo", "messageContentStyles", "messageContentTransferOffer"]
            + GoldenVectors.names.filter { $0.hasPrefix("messageContentCall") || $0.hasPrefix("messageContentScopeConfig") }
        #expect(named.count == 11)
        for name in named {
            _ = try MessageContent(decoding: GoldenVectors.bytes(name))
        }
        #expect(
            try MessageContent(decoding: GoldenVectors.bytes("messageContentTransferOffer")).xf
                == vector("messageContentTransferOffer")[.key("xf")])
        #expect(try BlobRequestContent(decoding: GoldenVectors.bytes("blobReqContentFastOnly")) == BlobRequestContent(hash: "h1"))
        #expect(try ProfilePayload(decoding: GoldenVectors.bytes("profilePayloadBadges")).name == "Ann")
        for name in ["messageContentV2Video", "messageContentV2Styles", "messageContentV2ProfileBadges"] {
            #expect(MessageContentV2.decode(GoldenVectors.bytes(name)) != nil, "\(name)")
        }
        // A commons post's attachment name and key, which only a commons post sets, read in its chat.
        let chat = try #require(try vector("commonsPostAttachment")[.key("chat")])
        #expect(chat[.key("attachmentName")] != nil && chat[.key("attachmentKey")] != nil)
        #expect(try ChatContent(cbor: chat).body == "menu")
    }

    // MARK: A room post

    @Test func aRoomPostsUnmodelledKeysAreTyped() throws {
        let video = try vector("chatContentVideo")
        let checks: [(String, String)] = [("video", "map"), ("attachmentName", "text"), ("attachmentKey", "text"), ("s", "bytes")]
        for (key, kind) in checks {
            for wrong in wrongKinds(besides: kind) {
                #expect(throws: WireDecodingError.self, "\(key): \(wrong)") { try ChatContent(cbor: video.setting(.key(key), wrong)) }
            }
        }
        #expect(try ChatContent(cbor: video.setting(.key("attachmentName"), .text("clip.mp4"))).body == "look")
        #expect(try ChatContent(cbor: video.setting(.key("attachmentKey"), .null)).body == "look")
        try expectVideoShape(in: video, key: .key("video"), labels: ["durationMs", "width", "height", "poster"].map(CBOR.key)) { item in
            try ChatContent(cbor: item)
        }
    }

    /// Each of a video's four fields is required and not nullable, and each is typed.
    private func expectVideoShape<Decoded>(
        in item: CBOR, key: CBOR, labels: [CBOR], sourceLocation: SourceLocation = #_sourceLocation, decode: (CBOR) throws -> Decoded
    ) throws {
        let kinds = ["int", "int", "int", "bytes"]
        for (label, kind) in zip(labels, kinds) {
            let missing = item.editing(key) { video in video.removing(label) }
            let broken =
                [missing]
                + ([.null, .map([])] + wrongKinds(besides: kind)).map { value in item.editing(key) { video in video.setting(label, value) }
                }
            for candidate in broken {
                #expect(throws: (any Error).self, "\(label)", sourceLocation: sourceLocation) { try decode(candidate) }
            }
        }
        _ = try decode(item.editing(key) { $0.adding(.key("future"), .text("skipped")) })
    }

    // MARK: A sealed message, named

    @Test func aSealedMessagesUnmodelledKeysAreTyped() throws {
        let plain = try vector("messageContentStyles")
        for (key, kind) in [("video", "map"), ("cl", "map"), ("sc", "map"), ("xf", "map"), ("s", "bytes")] {
            for wrong in wrongKinds(besides: kind) {
                #expect(throws: WireDecodingError.self, "\(key): \(wrong)") { try MessageContent(cbor: plain.setting(.key(key), wrong)) }
            }
        }
        try expectVideoShape(
            in: try vector("messageContentVideo"), key: .key("video"), labels: ["durationMs", "width", "height", "poster"].map(CBOR.key)
        ) { item in
            try MessageContent(cbor: item)
        }
    }

    /// A call's `id` and `ph` are required, `gen`, `m`, `ct` and `hr` defaulted, so `null` fails them, and the rest
    /// nullable but typed, down to the direct invite's fields.
    @Test func aCallIsTypedFieldByField() throws {
        let offer = try vector("messageContentCallOffer")
        let fields: [CallField] = [
            CallField("id", "text"), CallField("ph", "int"), CallField("gen", "int"), CallField("sdp", "text", nullable: true),
            CallField("cand", "array", nullable: true), CallField("rsn", "int", nullable: true), CallField("m", "int"),
            CallField("dw", "map", nullable: true), CallField("dx", "int", nullable: true), CallField("ct", "bool"),
            CallField("hr", "bool"),
        ]
        for call in fields {
            let (field, kind, nullable) = (call.name, call.kind, call.nullable)
            for wrong in wrongKinds(besides: kind) {
                #expect(throws: WireDecodingError.self, "cl.\(field): \(wrong)") {
                    try MessageContent(cbor: offer.editing(.key("cl")) { $0.setting(.key(field), wrong) })
                }
            }
            let nulled = offer.editing(.key("cl")) { $0.setting(.key(field), .null) }
            if nullable {
                #expect(try MessageContent(cbor: nulled).ctl == 10, "cl.\(field) null")
            } else {
                #expect(throws: WireDecodingError.self, "cl.\(field) null") { try MessageContent(cbor: nulled) }
            }
        }
        for field in ["id", "ph"] {
            #expect(throws: WireDecodingError.missingField(type: "CallPayload", field: field)) {
                try MessageContent(cbor: offer.editing(.key("cl")) { $0.removing(.key(field)) })
            }
        }
        #expect(throws: WireDecodingError.self) {
            try MessageContent(cbor: offer.editing(.key("cl")) { $0.setting(.key("cand"), .array([.unsigned(1)])) })
        }
        for (field, kind) in [("s", "text"), ("p", "text"), ("o", "int"), ("k", "text")] {
            for wrong in wrongKinds(besides: kind) {
                #expect(throws: WireDecodingError.self, "dw.\(field): \(wrong)") {
                    try MessageContent(cbor: offer.editing(.key("cl")) { $0.editing(.key("dw")) { $0.setting(.key(field), wrong) } })
                }
            }
        }
        #expect(
            try MessageContent(
                cbor: offer.editing(.key("cl")) { $0.setting(.key("dw"), .map([CBOR.Entry(key: .text("o"), value: .null)])) }
            ).ctl == 10)
    }

    @Test func aScopeConfigNeedsEveryFieldButItsGroup() throws {
        let config = try vector("messageContentScopeConfigGroup")
        let required: [(String, String)] = [
            ("spools", "array"), ("maxFrames", "int"), ("ttlMs", "int"), ("maxBlob", "int"), ("version", "int"),
        ]
        for (field, kind) in required {
            for broken in [CBOR.null, .map([])] + wrongKinds(besides: kind) {
                #expect(throws: WireDecodingError.self, "sc.\(field): \(broken)") {
                    try MessageContent(cbor: config.editing(.key("sc")) { $0.setting(.key(field), broken) })
                }
            }
            #expect(throws: WireDecodingError.missingField(type: "ScopeConfigPayload", field: field)) {
                try MessageContent(cbor: config.editing(.key("sc")) { $0.removing(.key(field)) })
            }
        }
        #expect(try MessageContent(cbor: config.editing(.key("sc")) { $0.removing(.key("groupId")) }).ctl == 7)
        #expect(throws: WireDecodingError.self) {
            try MessageContent(cbor: config.editing(.key("sc")) { $0.setting(.key("groupId"), .unsigned(1)) })
        }
    }

    @Test func aTransferNeedsItsIdAndPhaseAndTypesTheRest() throws {
        let offer = try vector("messageContentTransferOffer")
        for field in ["id", "phase"] {
            for broken in [{ (xf: CBOR) in xf.removing(.key(field)) }, { $0.setting(.key(field), .null) }] {
                #expect(throws: WireDecodingError.self, "xf.\(field)") { try MessageContent(cbor: offer.editing(.key("xf"), broken)) }
            }
        }
        let fields: [(String, String)] = [
            ("name", "text"), ("size", "int"), ("mime", "text"), ("ssid", "text"), ("passphrase", "text"), ("port", "int"), ("key", "text"),
            ("reason", "int"),
        ]
        for (field, kind) in fields {
            for wrong in wrongKinds(besides: kind) {
                #expect(throws: WireDecodingError.self, "xf.\(field): \(wrong)") {
                    try MessageContent(cbor: offer.editing(.key("xf")) { $0.setting(.key(field), wrong) })
                }
            }
            #expect(try MessageContent(cbor: offer.editing(.key("xf")) { $0.setting(.key(field), .null) }).ctl == 9)
        }
    }

    @Test func aProfilesBadgesAreTyped() throws {
        let profile = try vector("profilePayloadBadges")
        for wrong in wrongKinds(besides: "array") {
            #expect(throws: WireDecodingError.self, "\(wrong)") { try ProfilePayload(cbor: profile.setting(.key("badges"), wrong)) }
        }
        #expect(try ProfilePayload(cbor: profile.setting(.key("badges"), .null)).name == "Ann")
        let badge = try #require(
            profile[.key("badges")].flatMap { item -> CBOR? in
                guard case .array(let badges) = item else { return nil }
                return badges.first
            })
        for field in ["w", "r"] {
            for broken in [badge.removing(.key(field)), badge.setting(.key(field), .null), badge.setting(.key(field), .text("x"))] {
                #expect(throws: WireDecodingError.self, "badge.\(field)") {
                    try ProfilePayload(cbor: profile.setting(.key("badges"), .array([broken])))
                }
            }
        }
        #expect(throws: WireDecodingError.self) { try ProfilePayload(cbor: profile.setting(.key("badges"), .array([.text("x")]))) }
    }

    @Test func aBlobRequestsFastOnlyIsANullableBool() throws {
        let request = try vector("blobReqContentFastOnly")
        for wrong in wrongKinds(besides: "bool") {
            #expect(throws: WireDecodingError.self, "\(wrong)") { try BlobRequestContent(cbor: request.setting(.key("fastOnly"), wrong)) }
        }
        #expect(try BlobRequestContent(cbor: request.setting(.key("fastOnly"), .null)) == BlobRequestContent(hash: "h1"))
        #expect(try BlobRequestContent(cbor: request.setting(.key("fastOnly"), .bool(false))) == BlobRequestContent(hash: "h1"))
    }

    // MARK: A sealed message, compact

    /// Each of `keys` in `fixture` refuses a value of any kind but `kind`, and reads `null` as absent.
    private func expectCompactKeysTyped(_ fixture: CBOR, keys: [CBOR], kind: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for key in keys {
            for wrong in wrongKinds(besides: kind) {
                #expect(
                    MessageContentV2.decode(fixture.setting(key, wrong).encoded) == nil, "\(key): \(wrong)", sourceLocation: sourceLocation)
            }
            #expect(
                MessageContentV2.decode(fixture.setting(key, .null).encoded) != nil, "\(key): null is absent",
                sourceLocation: sourceLocation)
        }
    }

    /// Label 16, label 17 and `pr`'s label 8 are typed under their labels and under the property names kotlinx also
    /// reads as their keys.
    @Test func theCompactLayoutsNewLabelsAreTyped() throws {
        let video = try vector("messageContentV2Video")
        let styles = try vector("messageContentV2Styles")
        let badges = try vector("messageContentV2ProfileBadges")
        expectCompactKeysTyped(video, keys: [.unsigned(16), .key("video")], kind: "map")
        expectCompactKeysTyped(styles, keys: [.unsigned(17), .key("st")], kind: "bytes")
        for key in [CBOR.unsigned(8), .key("badges")] {
            for wrong in wrongKinds(besides: "array") {
                let broken = badges.editing(.unsigned(11)) { profile in profile.setting(key, wrong) }
                #expect(MessageContentV2.decode(broken.encoded) == nil, "pr.\(key): \(wrong)")
            }
            let missing = badges.editing(.unsigned(11)) { profile in
                profile.setting(key, .array([.map([CBOR.Entry(key: .unsigned(1), value: .bytes([1]))])]))
            }
            #expect(MessageContentV2.decode(missing.encoded) == nil, "pr.\(key): a badge with no r")
        }
        try expectVideoShape(in: video, key: .unsigned(16), labels: (1...4).map { CBOR.unsigned($0) }) { item in
            guard let content = MessageContentV2.decode(item.encoded) else {
                throw Refused()
            }
            return content
        }
        // A name key inside the video reads as its label too.
        let named = video.editing(.unsigned(16)) { $0.removing(.unsigned(2)).adding(.key("width"), .text("wide")) }
        #expect(MessageContentV2.decode(named.encoded) == nil)
    }
}

/// The compact decoder's refusal, as an error a check can expect.
private struct Refused: Error {}

/// One field of a call: its name, the CBOR kind kotlinx reads it as, and whether `null` is absent there.
private struct CallField {
    let name: String
    let kind: String
    let nullable: Bool

    init(_ name: String, _ kind: String, nullable: Bool = false) {
        self.name = name
        self.kind = kind
        self.nullable = nullable
    }
}
