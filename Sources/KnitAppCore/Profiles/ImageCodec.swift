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
/// side, and a JPEG at ``quality``, or a PNG when it has transparency, which JPEG lacks and ImageIO writes no WebP to
/// keep. A GIF goes as it is, so it keeps its frames, and nothing past ``OutgoingPhoto/maxBytes`` goes at all.
public enum ChatPhoto {
    /// The long side's most, in pixels (`MAX_DIMENSION`).
    public static let side = 1280
    /// The JPEG quality (`JPEG_QUALITY`, 85).
    public static let quality = 0.85
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
    /// `data` made ready to send in a chat, as ``ChatPhoto`` says. A still photo leaves with none of its metadata, so
    /// neither where nor when it was taken leaves the phone; a GIF goes as it is. `nil` when it is no image this phone
    /// reads, or would weigh more than ``OutgoingPhoto/maxBytes``.
    func chatPhoto(from data: Data) async -> OutgoingPhoto?
}
