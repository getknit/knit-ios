import libwebp

/// What libwebp's own demuxer reads back from an encoded WebP: the canvas, the loop count, and each frame's pixels
/// (straight RGBA) and start time.
struct DecodedWebP {
    let width: Int
    let height: Int
    let loops: Int
    let frames: [(pixels: [UInt8], start: Int)]

    init?(_ bytes: [UInt8]) {
        var options = WebPAnimDecoderOptions()
        guard WebPAnimDecoderOptionsInit(&options) != 0 else {
            return nil
        }
        options.color_mode = MODE_RGBA
        var decoded: Self?
        bytes.withUnsafeBufferPointer { buffer in
            var data = WebPData(bytes: buffer.baseAddress, size: buffer.count)
            guard let decoder = WebPAnimDecoderNew(&data, &options) else {
                return
            }
            defer { WebPAnimDecoderDelete(decoder) }
            var info = WebPAnimInfo()
            guard WebPAnimDecoderGetInfo(decoder, &info) != 0 else {
                return
            }
            let size = Int(info.canvas_width * info.canvas_height) * 4
            var read: [(pixels: [UInt8], start: Int)] = []
            var start: Int32 = 0
            while WebPAnimDecoderHasMoreFrames(decoder) != 0 {
                var canvas: UnsafeMutablePointer<UInt8>?
                var end: Int32 = 0
                guard WebPAnimDecoderGetNext(decoder, &canvas, &end) != 0, let canvas else {
                    return
                }
                read.append((Array(UnsafeBufferPointer(start: canvas, count: size)), Int(start)))
                start = end
            }
            decoded = Self(
                width: Int(info.canvas_width), height: Int(info.canvas_height), loops: Int(info.loop_count), frames: read)
        }
        guard let decoded else {
            return nil
        }
        self = decoded
    }

    private init(width: Int, height: Int, loops: Int, frames: [(pixels: [UInt8], start: Int)]) {
        self.width = width
        self.height = height
        self.loops = loops
        self.frames = frames
    }
}
