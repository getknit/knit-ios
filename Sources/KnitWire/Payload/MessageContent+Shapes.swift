/// The shapes of the payloads a sealed message (``MessageContent``) and a sealed profile (``ProfilePayload``) may carry
/// and this build does not model: each is read as kotlinx reads it, only so that a plaintext Android's decode refuses
/// is refused here too, and dropped (knit-ios #14).
extension MessageContent {
    /// One supporter badge of a sealed profile (`BadgeEntry`, `Wire.kt:841-856` at knit-next `e63f15f4`): the issuer's
    /// wrapper and the holder's 16 random bytes, both required. This build shows no badges, so it only checks the shape.
    struct BadgeEntry: CBORShape {
        init(cbor: CBOR) throws(WireDecodingError) {
            let fields = try CBORFields(cbor, type: "BadgeEntry")
            _ = try fields.required("w", .bytes)
            _ = try fields.required("r", .bytes)
        }
    }

    /// The signaling of a direct Wi-Fi transfer (`TransferPayload`, `Wire.kt:868-880` at knit-next `e63f15f4`), the shape
    /// ``MessageContent/xf`` must have: an `id` and a `phase`, the rest nullable.
    struct TransferPayload: CBORShape {
        init(cbor: CBOR) throws(WireDecodingError) {
            let fields = try CBORFields(cbor, type: "TransferPayload")
            _ = try fields.required("id", .text)
            _ = try fields.required("phase", .int32)
            _ = try fields.nullable("name", .text)
            _ = try fields.nullable("size", .int64)
            _ = try fields.nullable("mime", .text)
            _ = try fields.nullable("ssid", .text)
            _ = try fields.nullable("passphrase", .text)
            _ = try fields.nullable("port", .int32)
            _ = try fields.nullable("key", .text)
            _ = try fields.nullable("reason", .int32)
        }
    }

    /// The signaling of one voice call (`CallPayload`, `Wire.kt:926-938` at knit-next `e63f15f4`), under ctl 10. This build
    /// takes no calls, so it only checks the shape: `id` and `ph` required, `gen`, `m`, `ct` and `hr` defaulted, so `null`
    /// fails them, and the rest nullable.
    struct CallPayload: CBORShape {
        init(cbor: CBOR) throws(WireDecodingError) {
            let fields = try CBORFields(cbor, type: "CallPayload")
            _ = try fields.required("id", .text)
            _ = try fields.required("ph", .int32)
            _ = try fields.optional("gen", .int32)
            _ = try fields.nullable("sdp", .text)
            _ = try fields.nullable("cand", .texts)
            _ = try fields.nullable("rsn", .int32)
            _ = try fields.optional("m", .int32)
            _ = try fields.nullable("dw", .checked(as: DirectInvite.self))
            _ = try fields.nullable("dx", .int32)
            _ = try fields.optional("ct", .bool)
            _ = try fields.optional("hr", .bool)
        }
    }

    /// The Wi-Fi Direct group a caller offers to host (`DirectInvite`, `Wire.kt:979-985` at knit-next `e63f15f4`): every
    /// field nullable, so even an empty map in a long form reads as one.
    struct DirectInvite: CBORShape {
        init(cbor: CBOR) throws(WireDecodingError) {
            let fields = try CBORFields(cbor, type: "DirectInvite")
            _ = try fields.nullable("s", .text)
            _ = try fields.nullable("p", .text)
            _ = try fields.nullable("o", .int32)
            _ = try fields.nullable("k", .text)
        }
    }

    /// A scope's relays and bounds (`ScopeConfigPayload`, `Wire.kt:777-785` at knit-next `e63f15f4`), under ctl 7. This
    /// port has no spool, so it only checks the shape: every field but `groupId` required.
    struct ScopeConfigPayload: CBORShape {
        init(cbor: CBOR) throws(WireDecodingError) {
            let fields = try CBORFields(cbor, type: "ScopeConfigPayload")
            _ = try fields.nullable("groupId", .text)
            _ = try fields.required("spools", .texts)
            _ = try fields.required("maxFrames", .int32)
            _ = try fields.required("ttlMs", .int64)
            _ = try fields.required("maxBlob", .int32)
            _ = try fields.required("version", .int32)
        }
    }
}
