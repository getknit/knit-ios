#if os(iOS)
    import CoreGraphics
    import Foundation
    import ImageIO
    import KnitAppCore
    import UniformTypeIdentifiers

    /// The demo's faces and photos, read from `DemoMedia` in the app's bundle, which only a debug build carries (ADR
    /// 2026-10.2acj), and encoded as a profile photo or a chat's photo is. Each is cropped to fill the size it is
    /// wanted at, about its middle. Without the folder, as in a release build, there is no picture to give.
    internal enum DemoPictures {
        /// The folder in the app's bundle, as `App/project.yml` names it.
        private static let folder = "DemoMedia"
        /// The picture `-demoPhoto` hands the cropper and the composer: taller than wide, as a phone held upright takes it.
        /// The cropper has somewhere to pan, and a photo sent from the composer stands as tall as its bubble lets it, the
        /// most a photo grows once it decodes.
        private static let pick = (width: 1200, height: 1600)
        private static let picked = DemoSnapshot.summit
        /// A photo a message in the demo carries, at the shape a phone's camera takes.
        private static let snapshot = (width: 960, height: 720)
        /// Each channel's depth.
        private static let bitsPerComponent = 8
        /// Half the room a picture overflows by goes past each edge, so it is cropped about its middle.
        private static let middle: CGFloat = 0.5
        /// The GIF `-demoPhoto gif` picks: four scenes in turn, each for 0.3 seconds, for good. A cycle of a whole number
        /// of seconds would show a UI test that looks once a second the same frame each time. It is twice the size a
        /// moving photo goes at, so the one a UI test watches play is the animated WebP the GIF was shrunk into.
        private static let reel: [DemoSnapshot] = [.sunset, .lake, .forest, .campfire]
        private static let reelFrame = (width: 960, height: 720)
        private static let reelDelay = 0.3

        /// `portrait` as a profile photo.
        static func profilePhoto(_ portrait: DemoPortrait) -> [UInt8]? {
            jpeg(of: portrait.rawValue, width: ProfilePhoto.side, height: ProfilePhoto.side, quality: ProfilePhoto.quality)
        }

        /// `picture` as a photo a message carries.
        static func chatPhoto(_ picture: DemoSnapshot) -> [UInt8]? {
            jpeg(of: picture.rawValue, width: snapshot.width, height: snapshot.height, quality: ChatPhoto.imageIOQuality)
        }

        /// The picture Choose photo and Add photo pick under `-demoPhoto`, or the GIF they pick under `-demoPhoto gif`.
        static func picked(moving: Bool) -> Data? {
            moving ? pickedGIF() : pickedPhoto()
        }

        private static func pickedPhoto() -> Data? {
            jpeg(of: picked.rawValue, width: pick.width, height: pick.height, quality: ProfilePhoto.quality).map { Data($0) }
        }

        /// The picture Add photo picks under `-demoPhoto gif`: a GIF that moves, written by ImageIO, so a UI test can watch
        /// one play in a thread (ADR 2026-10.ytvx).
        private static func pickedGIF() -> Data? {
            let frames = reel.compactMap { filled($0.rawValue, width: reelFrame.width, height: reelFrame.height) }
            let output = NSMutableData()
            guard frames.count == reel.count,
                let destination = CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, frames.count, nil)
            else {
                return nil
            }
            let forever = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
            CGImageDestinationSetProperties(destination, forever as CFDictionary)
            let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: reelDelay]]
            for frame in frames {
                CGImageDestinationAddImage(destination, frame, delay as CFDictionary)
            }
            return CGImageDestinationFinalize(destination) ? output as Data : nil
        }

        private static func jpeg(of name: String, width: Int, height: Int, quality: Double) -> [UInt8]? {
            filled(name, width: width, height: height).flatMap { DeviceImageCodec.jpeg($0, quality: quality) }
        }

        /// The bundled picture `name`, scaled to cover `width` by `height` and cropped about its middle to fit.
        private static func filled(_ name: String, width: Int, height: Int) -> CGImage? {
            guard let url = Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: folder),
                let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: bitsPerComponent,
                    bytesPerRow: 0,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )
            else {
                return nil
            }
            let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
            let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.interpolationQuality = .high
            context.draw(
                image,
                in: CGRect(
                    origin: CGPoint(x: (CGFloat(width) - drawn.width) * middle, y: (CGFloat(height) - drawn.height) * middle),
                    size: drawn
                )
            )
            return context.makeImage()
        }
    }
#endif
