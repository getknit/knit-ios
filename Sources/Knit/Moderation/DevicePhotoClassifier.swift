#if os(iOS)
    import CoreGraphics
    import CoreML
    import Foundation
    import KnitAppCore
    import KnitMesh

    /// The content filter's classifier (ADR 2026-10.rpmq): GantMan's `nsfw_model`, the one Knit for Android ships as
    /// `nsfw.tflite`, converted to a float16 Core ML program by `tools/models/nsfw/` and bundled as `NSFW.mlmodelc`.
    ///
    /// A photo is read as Android reads it (`NsfwImageModerator.infer`): decoded with its long side at most 512 pixels,
    /// stretched to 224 by 224 with no crop, and handed over as RGB divided by 255. A GIF gives its first frame, and a
    /// transparent pixel reads as black. The model loads on the first photo, runs on the CPU and the Neural Engine
    /// (never the GPU, which iOS denies an app in the background), and lets go when Knit leaves the front or memory runs
    /// low. One that fails to load stays failed until Knit starts again, and every photo then goes through, as
    /// Android's does.
    internal actor DevicePhotoClassifier: PhotoClassifier {
        /// The model's input side, in pixels.
        private static let side = 224
        /// The long side a photo is decoded at before it is stretched (`ImageScreeningService.SCREEN_MAX_DIM`).
        private static let decodeSide = 512
        private static let channels = 3
        private static let bytesPerPixel = 4
        private static let bitsPerComponent = 8
        private static let maxChannel: Float = 255

        private enum State {
            case unloaded
            case loaded(MLModel)
            case failed
        }

        private var state = State.unloaded
        private let log: any KnitLog

        /// The bundled classifier, which reports what goes wrong to `log`.
        init(log: any KnitLog) {
            self.log = log
        }

        func scores(of bytes: [UInt8]) -> [Float]? {
            guard let model = model(), let input = Self.input(from: Data(bytes)) else {
                return nil
            }
            do {
                let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)])
                let output = try model.prediction(from: features)
                guard let scores = output.featureValue(for: "scores")?.multiArrayValue else {
                    log.log(.warning, "photo classifier: no scores in its output")
                    return nil
                }
                return (0..<scores.count).map { scores[$0].floatValue }
            } catch {
                log.log(.warning, "photo classifier: prediction failed: \(error)")
                return nil
            }
        }

        /// Lets the model go; the next photo loads it again.
        func release() {
            if case .loaded = state {
                state = .unloaded
            }
        }

        private func model() -> MLModel? {
            switch state {
            case .loaded(let model):
                return model
            case .failed:
                return nil
            case .unloaded:
                break
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            guard let url = Bundle.main.url(forResource: "NSFW", withExtension: "mlmodelc") else {
                log.log(.warning, "photo classifier: NSFW.mlmodelc is not in the app, so no photo is screened")
                state = .failed
                return nil
            }
            do {
                let model = try MLModel(contentsOf: url, configuration: configuration)
                state = .loaded(model)
                return model
            } catch {
                log.log(.warning, "photo classifier: the model did not load, so no photo is screened: \(error)")
                state = .failed
                return nil
            }
        }

        /// The model's input for the photo in `data`, or `nil` when it is no photo a thread may show.
        private static func input(from data: Data) -> MLMultiArray? {
            guard
                let image = PhotoDecoder.thumbnail(
                    data, side: decodeSide, types: PhotoDecoder.meshTypes, pixels: PhotoDecoder.meshPixels),
                let pixels = stretched(image),
                // swiftlint:disable:next legacy_objc_type - Core ML takes a shape as NSNumbers.
                let input = try? MLMultiArray(shape: [1, side, side, channels].map { NSNumber(value: $0) }, dataType: .float32)
            else {
                return nil
            }
            input.withUnsafeMutableBufferPointer(ofType: Float.self) { values, _ in
                for pixel in 0..<(side * side) {
                    for channel in 0..<channels {
                        values[pixel * channels + channel] = Float(pixels[pixel * bytesPerPixel + channel]) / maxChannel
                    }
                }
            }
            return input
        }

        /// `image` drawn into `side` by `side` sRGB pixels, stretched to fill them, four bytes a pixel from the top row
        /// down; transparency lands on black.
        private static func stretched(_ image: CGImage) -> [UInt8]? {
            var pixels = [UInt8](repeating: 0, count: side * side * bytesPerPixel)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                    let context = CGContext(
                        data: buffer.baseAddress,
                        width: side,
                        height: side,
                        bitsPerComponent: bitsPerComponent,
                        bytesPerRow: side * bytesPerPixel,
                        space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                    )
                else {
                    return false
                }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            return drawn ? pixels : nil
        }
    }
#endif
