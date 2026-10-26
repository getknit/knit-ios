/// The compact layout's shapes for what this build does not model, a short video (label 16) and a profile's supporter
/// badges (`ProfileV2`'s label 8): each is read as kotlinx's `compactCbor` reads it, only so that a plaintext Android's
/// decode refuses is refused here too, and dropped (knit-ios #14).
extension MessageContentV2 {
    /// `VideoV2`'s labels (`MessageContentV2.kt:223-235` at knit-next `e63f15f4`).
    enum VideoLabel: UInt64, CBORLabel {
        case durationMs = 1
        case width = 2
        case height = 3
        case poster = 4
    }

    /// `BadgeV2`'s labels (`MessageContentV2.kt:291-298` at knit-next `e63f15f4`).
    enum BadgeLabel: UInt64, CBORLabel {
        // swiftlint:disable:next identifier_name - the Kotlin property's name, which kotlinx also reads as this key
        case w = 1
        // swiftlint:disable:next identifier_name - the Kotlin property's name, which kotlinx also reads as this key
        case r = 2
    }

    /// A short video's duration, size and poster under label 16 (`VideoV2`, `MessageContentV2.kt:223-235` at knit-next
    /// `e63f15f4`), all four required. This build plays no video, so it only checks the shape.
    struct VideoV2: CBORShape {
        init(cbor: CBOR) throws(WireDecodingError) {
            let fields = try CBORLabeledFields<VideoLabel>(cbor, type: "VideoV2")
            _ = try fields.required(.durationMs, .int64)
            _ = try fields.required(.width, .int32)
            _ = try fields.required(.height, .int32)
            _ = try fields.required(.poster, .bytes)
        }
    }

    /// One supporter badge of a sealed profile, under `ProfileV2`'s label 8 (`BadgeV2`, `MessageContentV2.kt:291-298` at
    /// knit-next `e63f15f4`), both fields required. This build shows no badges, so it only checks the shape.
    struct BadgeV2: CBORShape {
        init(cbor: CBOR) throws(WireDecodingError) {
            let fields = try CBORLabeledFields<BadgeLabel>(cbor, type: "BadgeV2")
            _ = try fields.required(.w, .bytes)
            _ = try fields.required(.r, .bytes)
        }
    }
}
