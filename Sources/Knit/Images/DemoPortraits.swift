#if os(iOS)
    import CoreGraphics
    import Foundation
    import KnitAppCore

    /// The demo's profile photos, painted rather than shipped: a sky, a few shapes, and a JPEG of them, encoded as a
    /// profile photo is. Coordinates are fractions of the picture, from its bottom left corner.
    internal enum DemoPortraits {
        /// The picture `-demoPhoto` hands the cropper: wider than tall, so it has somewhere to pan.
        private static let pick = (width: 1600, height: 1200)
        /// Each channel's depth.
        private static let bitsPerComponent = 8

        /// `portrait` as a profile photo.
        static func profilePhoto(_ portrait: DemoPortrait) -> [UInt8]? {
            jpeg(portrait, width: ProfilePhoto.side, height: ProfilePhoto.side)
        }

        /// The picture Choose photo picks under `-demoPhoto`.
        static func pickedPhoto() -> Data? {
            jpeg(.summit, width: pick.width, height: pick.height).map { Data($0) }
        }

        private static func jpeg(_ portrait: DemoPortrait, width: Int, height: Int) -> [UInt8]? {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
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
            Canvas(context: context, space: space, width: CGFloat(width), height: CGFloat(height)).paint(Scene.of(portrait))
            return context.makeImage().flatMap { DeviceImageCodec.jpeg($0, quality: ProfilePhoto.quality) }
        }
    }

    /// One picture: a sky from its top color to its horizon's, then discs and shapes laid over it in order. Each is
    /// written out as text, a color in hex and then points as `x,y`, which keeps a picture's numbers in one line each:
    /// a sky is two colors, a disc a color, its center and its radius, and a shape a color and its corners.
    private struct Scene {
        let sky: String
        var discs: [String] = []
        let shapes: [String]

        static func of(_ portrait: DemoPortrait) -> Self {
            switch portrait {
            case .summit:
                summit
            case .sunset:
                sunset
            case .forest:
                forest
            case .lake:
                lake
            case .campfire:
                campfire
            }
        }

        private static let summit = Self(
            sky: "4A90D9 CDE6F7",
            discs: ["FFF4C2 0.78,0.8 0.08"],
            shapes: [
                "8FA9C7 0,0.35 0.2,0.55 0.35,0.45 0.55,0.7 0.75,0.5 1,0.6 1,0 0,0",
                "5D6F8C 0,0.2 0.3,0.45 0.5,0.78 0.7,0.42 1,0.25 1,0 0,0",
                "F7FAFC 0.42,0.66 0.5,0.78 0.58,0.66 0.54,0.69 0.5,0.64 0.46,0.69",
                "3A4A5F 0,0 0,0.18 0.4,0.12 1,0.2 1,0",
            ]
        )

        private static let sunset = Self(
            sky: "6B4C9A FFC27A",
            discs: ["FFE9A8 0.5,0.36 0.15"],
            shapes: [
                "8E4A6B 0,0.3 0.25,0.42 0.5,0.32 0.75,0.45 1,0.35 1,0 0,0",
                "4B2A4A 0,0.15 0.35,0.25 0.7,0.12 1,0.2 1,0 0,0",
            ]
        )

        private static let forest = Self(
            sky: "8CC9B4 EAF6EF",
            discs: ["FFFDF2 0.24,0.8 0.07"],
            shapes: [
                "5E8F6E 0,0.32 0.1,0.66 0.2,0.32",
                "5E8F6E 0.2,0.32 0.3,0.7 0.4,0.32",
                "5E8F6E 0.4,0.32 0.5,0.64 0.6,0.32",
                "5E8F6E 0.6,0.32 0.7,0.72 0.8,0.32",
                "5E8F6E 0.8,0.32 0.9,0.66 1,0.32",
                "2F5D43 0,0.08 0.17,0.56 0.34,0.08",
                "2F5D43 0.33,0.08 0.5,0.6 0.67,0.08",
                "2F5D43 0.66,0.08 0.83,0.54 1,0.08",
                "23432F 0,0 0,0.1 1,0.1 1,0",
            ]
        )

        private static let lake = Self(
            sky: "6FB1E0 DDF0FA",
            shapes: [
                "7C93A8 0,0.45 0.3,0.68 0.55,0.5 0.8,0.72 1,0.55 1,0.4 0,0.4",
                "4D7FA3 0,0 0,0.4 1,0.4 1,0",
                "9CC3DD 0.15,0.3 0.45,0.3 0.45,0.32 0.15,0.32",
                "9CC3DD 0.55,0.18 0.9,0.18 0.9,0.2 0.55,0.2",
            ]
        )

        private static let campfire = Self(
            sky: "0F1630 2C3566",
            discs: [
                "F4F1DE 0.8,0.82 0.06",
                "FFFFFF 0.12,0.9 0.008",
                "FFFFFF 0.3,0.78 0.008",
                "FFFFFF 0.46,0.92 0.008",
                "FFFFFF 0.62,0.7 0.008",
                "FFFFFF 0.2,0.62 0.008",
                "FFFFFF 0.9,0.6 0.008",
            ],
            shapes: [
                "1D1D24 0,0 0,0.25 1,0.22 1,0",
                "6B4226 0.3,0.16 0.7,0.26 0.72,0.22 0.32,0.12",
                "6B4226 0.3,0.26 0.7,0.16 0.68,0.12 0.28,0.22",
                "F28C28 0.34,0.24 0.42,0.42 0.5,0.58 0.58,0.42 0.66,0.24",
                "FFD166 0.42,0.24 0.47,0.36 0.5,0.44 0.53,0.36 0.58,0.24",
            ]
        )
    }

    /// A context and the size it paints, which reads a ``Scene``'s text as it paints it.
    private struct Canvas {
        private static let hex = 16
        private static let channelMax: CGFloat = 255
        private static let byte = 0xFF
        private static let redShift = 16
        private static let greenShift = 8

        let context: CGContext
        let space: CGColorSpace
        let width: CGFloat
        let height: CGFloat

        func paint(_ scene: Scene) {
            let sky = scene.sky.split(separator: " ").compactMap(color)
            if let gradient = CGGradient(colorsSpace: space, colors: sky as CFArray, locations: nil) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])
            }
            for disc in scene.discs {
                let parts = disc.split(separator: " ")
                guard let fill = parts.first.flatMap(color), let center = parts.dropFirst().first.flatMap(point),
                    let radius = parts.last.flatMap({ Double($0) })
                else {
                    continue
                }
                let side = CGFloat(radius) * min(width, height)
                context.setFillColor(fill)
                context.fillEllipse(in: CGRect(origin: center, size: .zero).insetBy(dx: -side, dy: -side))
            }
            for shape in scene.shapes {
                let parts = shape.split(separator: " ")
                guard let fill = parts.first.flatMap(color) else {
                    continue
                }
                context.setFillColor(fill)
                context.addLines(between: parts.dropFirst().compactMap(point))
                context.closePath()
                context.fillPath()
            }
        }

        /// `x,y` as fractions of the picture, in its pixels.
        private func point(_ text: Substring) -> CGPoint? {
            let parts = text.split(separator: ",").compactMap { Double($0) }
            guard let across = parts.first, let up = parts.last, parts.count > 1 else {
                return nil
            }
            return CGPoint(x: CGFloat(across) * width, y: CGFloat(up) * height)
        }

        /// `RRGGBB` as a color.
        private func color(_ text: Substring) -> CGColor? {
            Int(text, radix: Self.hex).map { hex in
                let channel = { (shift: Int) in CGFloat((hex >> shift) & Self.byte) / Self.channelMax }
                return CGColor(srgbRed: channel(Self.redShift), green: channel(Self.greenShift), blue: channel(0), alpha: 1)
            }
        }
    }
#endif
