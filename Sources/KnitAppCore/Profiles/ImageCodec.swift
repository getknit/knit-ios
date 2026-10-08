public import Foundation
public import KnitMesh

/// What a profile photo is (`AvatarStore.kt` in knit-next): a square JPEG of ``side`` pixels at ``quality``, cropped
/// from a source decoded upright with its long side at most ``sourceSide``.
public enum ProfilePhoto {
    /// The photo's side, in pixels (`AVATAR_SIZE`).
    public static let side = 256
    /// Its JPEG quality (`JPEG_QUALITY`, 90).
    public static let quality = 0.9
    /// The cropper's source is decoded no larger than this on its long side (`MAX_CROP_DIMENSION`): ample for 256
    /// pixels, and bounded, so a large photo cannot exhaust memory.
    public static let sourceSide = 1280
}

/// What a photo sent in a chat is (`AttachmentStore.kt` in knit-next): upright, at most ``side`` pixels on its long
/// side, and a JPEG at ``quality``, or a lossy WebP at the same quality when it has transparency, which JPEG lacks. A
/// clean picture goes as its own bytes, stripped (``StrippedPicture/isClean``), and a moving one as ``ChatAnimation``
/// says. Nothing past ``OutgoingPhoto/maxBytes`` goes at all.
public enum ChatPhoto {
    /// The long side's most, in pixels (`MAX_DIMENSION`).
    public static let side = 1280
    /// The JPEG and WebP quality, on libjpeg's and libwebp's scale (`JPEG_QUALITY` and `WEBP_QUALITY`, 85).
    public static let quality = 0.85
    /// ImageIO's JPEG quality whose tables read as libjpeg's ``quality``, which the app writes a JPEG at. ImageIO's scale
    /// is its own: its 0.85 reads as libjpeg's 95, about twice the bytes of Android's photo (measured on macOS 27,
    /// 2026-10-08; `ImageIOTests` pins it on the Mac).
    public static let imageIOQuality = 0.575
    /// The sharpest JPEG that goes as its own bytes, as its tables read (``JPEGStrip``): ``quality`` and
    /// `QUALITY_SLACK`, 2, since a table read back from rounded entries can land a point either side.
    public static let sharpestPassThrough = 87
    /// The heaviest still WebP that goes as its own bytes, per pixel (`WEBP_MAX_BYTES_PER_PIXEL`): half a byte sits well
    /// above what ``quality`` comes to with an alpha plane, so the app's own output qualifies.
    public static let heaviestWebP = 0.5
}

/// What a moving picture sent in a chat becomes (`AttachmentStore.kt` and `WebpTranscode.kt` in knit-next, ADR
/// 2026-10.8hmx): an animated lossy WebP at most ``side`` pixels on its long side, sampled at ``framesPerSecond`` and
/// written at ``quality``, looping forever. A GIF always takes this door, unless the WebP would be no smaller; an animated
/// WebP takes it past ``Sticker``'s bounds, and an APNG always, since Android plays none.
public enum ChatAnimation {
    /// The long side's most, in pixels (`GIF_MAX_DIMENSION`).
    public static let side = 480
    /// How often a frame is sampled (`GIF_MAX_FPS`).
    public static let framesPerSecond = 15
    /// The WebP quality, on libwebp's scale (`GIF_WEBP_QUALITY`, 70).
    public static let quality = 0.7
    /// The most frames that go out (`MAX_FRAMES`): a longer clip is sampled more sparsely, so it keeps its length.
    public static let maxFrames = 200
    /// The most frames a source may have and still be read (`MAX_SOURCE_FRAMES`).
    public static let maxSourceFrames = 1000
    /// The largest source canvas read, on its long side (`MAX_CANVAS`).
    public static let maxSourceSide = 4096
}

/// The bounds within which an animated WebP goes as its own bytes, stripped (`ANIMATED_PASS_MAX_*`): the sticker's
/// 512-pixel canvas, which the 480 of ``ChatAnimation`` would resample for 32 pixels, and the Bluetooth cost of a MiB.
public enum Sticker {
    /// The canvas's long side's most, in pixels.
    public static let side = 512
    /// The most frames.
    public static let maxFrames = 200
    /// The most bytes, 1 MiB.
    public static let maxBytes = 1_048_576
}

/// Why a picked picture cannot be sent.
public enum PhotoFailure: Error, Equatable {
    /// It is no picture this phone reads.
    case unreadable
    /// It is past the most pixels the app decodes, or nothing it can make of it fits ``OutgoingPhoto/maxBytes``.
    case tooLarge
}

/// A picked image the app's codec decoded for the cropper: upright and bounded, and opaque here, where only its size
/// matters.
public protocol PreparedImage: Sendable {
    /// Its width, in pixels.
    var pixelWidth: Int { get }
    /// Its height, in pixels.
    var pixelHeight: Int { get }
}

/// Where a profile photo is decoded and encoded: ImageIO in the app, a stand-in in tests, the same arrangement as
/// ``CameraAccess``.
public protocol ImageCodec: Sendable {
    /// `data` decoded for the cropper: turned upright by its orientation tag, with its long side at most
    /// ``ProfilePhoto/sourceSide``, or `nil` when it is no image this phone reads.
    func prepare(_ data: Data) async -> (any PreparedImage)?
    /// `crop` of `image`, scaled to ``ProfilePhoto/side`` pixels square and encoded as a JPEG at ``ProfilePhoto/quality``
    /// with none of the picked photo's metadata, so neither where nor when it was taken leaves the phone; or `nil` when
    /// it fails.
    func profilePhoto(from image: any PreparedImage, crop: CropRect) async -> [UInt8]?
    /// `data` made ready to send in a chat, as ``ChatPhoto`` and ``ChatAnimation`` say. Whatever goes leaves with none of
    /// the picked picture's metadata, so neither where nor when it was taken leaves the phone.
    func chatPhoto(from data: Data) async -> Result<OutgoingPhoto, PhotoFailure>
}
