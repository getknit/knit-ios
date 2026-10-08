internal import libwebp

/// An animated lossy WebP written a frame at a time through libwebp's `WebPAnimEncoder`, as Android's
/// `AnimatedWebpMuxer` writes one: every frame lossy at one quality, looping forever (`LOOP_FOREVER`). It holds the
/// encoder's state and the frames encoded so far, never the source clip. Not `Sendable`: one task writes it.
public final class AnimatedWebPWriter {
    private let encoder: OpaquePointer
    private var config: WebPConfig
    private let width: Int
    private let height: Int
    /// When the next frame starts, in milliseconds from the first.
    private var elapsed = 0
    private var frames = 0

    /// A writer for frames `width` × `height` at `quality` (0 to 1), or `nil` when libwebp refuses them.
    public init?(width: Int, height: Int, quality: Double) {
        var options = WebPAnimEncoderOptions()
        guard width > 0, height > 0, WebPAnimEncoderOptionsInit(&options) != 0, let settings = WebPEncoder.config(quality: quality) else {
            return nil
        }
        options.anim_params.loop_count = 0
        options.allow_mixed = 0
        guard let made = WebPAnimEncoderNew(Int32(width), Int32(height), &options) else {
            return nil
        }
        encoder = made
        config = settings
        self.width = width
        self.height = height
    }

    deinit {
        WebPAnimEncoderDelete(encoder)
    }

    /// Adds `frame`, shown for `milliseconds`; `false` when it is another size than the writer's or libwebp fails.
    public func add(_ frame: RGBAImage, milliseconds: Int) -> Bool {
        guard frame.width == width, frame.height == height, milliseconds > 0, var picture = WebPEncoder.picture(frame) else {
            return false
        }
        defer { WebPPictureFree(&picture) }
        guard WebPAnimEncoderAdd(encoder, &picture, Int32(elapsed), &config) != 0 else {
            return false
        }
        elapsed += milliseconds
        frames += 1
        return true
    }

    /// The animation's bytes, or `nil` when it holds no frame or libwebp fails. Call it once.
    public func finish() -> [UInt8]? {
        guard frames > 0, WebPAnimEncoderAdd(encoder, nil, Int32(elapsed), nil) != 0 else {
            return nil
        }
        var data = WebPData()
        guard WebPAnimEncoderAssemble(encoder, &data) != 0, let bytes = data.bytes else {
            return nil
        }
        defer { WebPDataClear(&data) }
        return Array(UnsafeBufferPointer(start: bytes, count: data.size))
    }
}
