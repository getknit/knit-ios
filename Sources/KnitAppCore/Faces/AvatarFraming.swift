/// A square of a source image, in its pixels.
public struct CropRect: Sendable, Equatable {
    /// The left edge.
    public var left: Int
    /// The top edge.
    public var top: Int
    /// The width, which always equals ``height``.
    public var width: Int
    /// The height.
    public var height: Int

    /// The square at `left` and `top`, `width` by `height`.
    public init(left: Int, top: Int, width: Int, height: Int) {
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }
}

/// Where the user has placed a photo under the cropper's circle, and the square of it that the circle covers
/// (`AvatarCropDialog.kt` and `computeAvatarCrop` in knit-next). The image and the circle are both centered in the
/// cropper, the circle is ``circleFraction`` of the cropper's shorter side, and the image starts at the scale that
/// fills the circle with its shorter side. The user zooms from there up to ``maxScale``, and pans no further than
/// keeps the circle full.
public struct AvatarFraming: Sendable, Equatable {
    /// The circle's diameter as a fraction of the cropper's shorter side (`CIRCLE_FRACTION`).
    public static let circleFraction = 0.8
    /// The most the user can zoom past filling the circle (`MAX_SCALE`).
    public static let maxScale = 5.0
    /// How far one VoiceOver swipe zooms.
    public static let zoomStep = 1.25

    /// The source's width, in pixels.
    public let sourceWidth: Int
    /// The source's height, in pixels.
    public let sourceHeight: Int
    /// The circle's diameter, in points: zero until the cropper has been measured.
    public private(set) var diameter = 0.0
    /// The zoom, from 1 (the circle filled) to ``maxScale``.
    public private(set) var scale = 1.0
    /// How far the image's center sits from the cropper's, in points, unscaled.
    public private(set) var offsetX = 0.0
    /// How far the image's center sits from the cropper's, in points, unscaled.
    public private(set) var offsetY = 0.0

    /// A source of `sourceWidth` by `sourceHeight` pixels, centered and unzoomed.
    public init(sourceWidth: Int, sourceHeight: Int) {
        self.sourceWidth = max(sourceWidth, 1)
        self.sourceHeight = max(sourceHeight, 1)
    }

    /// Points per source pixel at the current zoom.
    public var pointsPerPixel: Double {
        diameter / Double(min(sourceWidth, sourceHeight)) * scale
    }

    /// The cropper measured `width` by `height` points: the circle follows, and the pan stays inside it.
    public mutating func fit(width: Double, height: Double) {
        diameter = max(min(width, height), 0) * Self.circleFraction
        clampOffset()
    }

    /// Zooms by `factor`, from 1 to ``maxScale``.
    public mutating func zoom(by factor: Double) {
        scale = min(max(scale * factor, 1), Self.maxScale)
        clampOffset()
    }

    /// Moves the image by `dx` and `dy` points, no further than keeps the circle full.
    public mutating func pan(dx: Double, dy: Double) {
        offsetX += dx
        offsetY += dy
        clampOffset()
    }

    /// The square of the source the circle covers.
    public var crop: CropRect {
        Self.crop(
            source: (sourceWidth, sourceHeight),
            diameter: Float(diameter),
            scale: Float(scale),
            offset: (Float(offsetX), Float(offsetY))
        )
    }

    /// Half of anything.
    private static let half = 0.5

    private mutating func clampOffset() {
        let side = pointsPerPixel
        let maxX = max(0, (side * Double(sourceWidth) - diameter) * Self.half)
        let maxY = max(0, (side * Double(sourceHeight) - diameter) * Self.half)
        offsetX = min(max(offsetX, -maxX), maxX)
        offsetY = min(max(offsetY, -maxY), maxY)
    }

    /// The square of a `source` of that many pixels across and down that a centered circle of `diameter` covers, with
    /// the image zoomed by `scale` and moved by `offset` (`computeAvatarCrop`). The diameter cancels out, since both
    /// are centered. At a scale of 1 with no offset this is a plain center crop, and since the scale is at least 1 the
    /// square always fits the source: it is only ever shifted back inside, never shrunk, so the scale to 256 pixels
    /// distorts nothing. In `Float`, as Kotlin computes it, with Java's rounding, half up.
    public static func crop(source: (width: Int, height: Int), diameter: Float, scale: Float, offset: (x: Float, y: Float)) -> CropRect {
        let halfway = Float(half)
        let minSide = max(min(source.width, source.height), 1)
        let screenPerSource = diameter / Float(minSide) * scale
        let side = min(max(javaRound(diameter / screenPerSource), 1), minSide)
        let centerX = Float(source.width) * halfway - offset.x / screenPerSource
        let centerY = Float(source.height) * halfway - offset.y / screenPerSource
        let left = min(max(javaRound(centerX - Float(side) * halfway), 0), max(source.width - side, 0))
        let top = min(max(javaRound(centerY - Float(side) * halfway), 0), max(source.height - side, 0))
        return CropRect(left: left, top: top, width: side, height: side)
    }

    /// Kotlin's `roundToInt`: the floor of the value plus a half, so ties go up, kept inside `Int32`. Kotlin throws on
    /// NaN, which a diameter of zero makes, and Android never crops before it has measured; here NaN is 0. The half is
    /// added in `Double`, where a `Float` plus a half is exact, as the mathematical floor Java computes.
    private static func javaRound(_ value: Float) -> Int {
        guard !value.isNaN else {
            return 0
        }
        let rounded = (Double(value) + half).rounded(.down)
        return Int(min(max(rounded, Double(Int32.min)), Double(Int32.max)))
    }
}
