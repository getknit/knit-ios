/// What a card's picture becomes before it is sent (`PreviewImage.kt` in knit-next, ADR 2026-11.hcvg): upright, at most
/// ``side`` pixels on its long side, and a JPEG at ``quality``, or a lossy WebP when it has transparency, which a JPEG
/// would fill in black. Past ``LinkPreviewBlob/imageMaxBytes`` it is made again smaller and rougher, then given up on: a
/// card without a picture is still a card.
public enum CardPicture {
    /// The long side's most, in pixels (`MAX_DIM`).
    public static let side = 512
    /// The long side's most on the second try (`RETRY_DIM`).
    public static let retrySide = 384
    /// Under this on either side the picture is a favicon or a tracking pixel, and the card goes without (`MIN_DIM`).
    public static let minSide = 64
    /// The JPEG and WebP quality, on libjpeg's and libwebp's scale (`QUALITY`, 80).
    public static let quality = 0.8
    /// The quality of the second try (`RETRY_QUALITY`, 70).
    public static let retryQuality = 0.7
    /// ImageIO's JPEG quality whose tables read as libjpeg's ``quality``: ImageIO's scale is its own, as
    /// ``ChatPhoto/imageIOQuality`` says (measured on macOS 27, 2026-11-10; `ImageIOTests` pins it on the Mac).
    public static let imageIOQuality = 0.51
    /// ImageIO's JPEG quality whose tables read as libjpeg's ``retryQuality``.
    public static let retryImageIOQuality = 0.43
}
