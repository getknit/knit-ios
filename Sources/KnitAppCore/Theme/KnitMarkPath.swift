import Foundation

/// Knit's mark, the stitched "K", as the steps of a path in a unit square (ADR 2026-10.5waw). The path data is knit-next's
/// `ic_launcher_monochrome.xml`, copied as it is: dashes for the upright and the arms, and a diamond node where they meet,
/// whose square hole is a subpath of its own wound the other way, so it cuts under the non-zero fill rule. It is parsed
/// here rather than drawn by hand so the mark stays Android's, and so the parse is tested on Linux.
public enum KnitMarkPath {
    /// A point in the mark's unit square, y down.
    public struct Point: Sendable, Equatable {
        // swiftlint:disable:next identifier_name - a coordinate's own name
        public let x: Double
        // swiftlint:disable:next identifier_name - a coordinate's own name
        public let y: Double

        /// The point (`x`, `y`).
        public init(x: Double, y: Double) { // swiftlint:disable:this identifier_name - a coordinate's own names
            self.x = x
            self.y = y
        }
    }

    /// One step of a path.
    public enum Step: Sendable, Equatable {
        case move(Point)
        case line(Point)
        case curve(Point, control1: Point, control2: Point)
        case close
    }

    /// The mark's stitches, each closed, in the order a needle lays them: the upright's top, the node where the arms meet,
    /// the upright's foot, then each arm outward. Fit to the unit square and centered across it.
    public static let stitches: [[Step]] = (try? parse(pathData)).map { fitted(laid($0)) } ?? []

    /// `ic_launcher_monochrome.xml`'s path data, on its 520-unit grid.
    static let pathData =
        "M356.88,97.49l18.5,-19.67a19.6,19.6 0,0 1,3.9 -3.19,19.86 19.86,0 0,1 3.49,-2 19.57,19.57 0,0 1,25.25 27,19.78 19.78,0 "
        + "0,1 -3.64,5.47l-18.49,19.67a19.91,19.91 0,0 1,-29 -27.28Z M273.68,186 L316.88,140a19.91,19.91 0,0 1,29 27.28l-43.2,"
        + "45.94a19.91,19.91 0,1 1,-29 -27.28Z M156.92,91a20.2,20.2 0,0 1,0.54 -4.57,19.56 19.56,0 0,1 38.74,0 19.91,19.91 0,0 "
        + "1,0.53 4.53v27a19.91,19.91 0,1 1,-39.81 0Z M197,428.66a19.83,19.83 0,0 1,-2.31 9.3,19.54 19.54,0 0,1 -35,0.38 19.82,"
        + "19.82 0,0 1,-2.52 -9.68v-27a19.91,19.91 0,1 1,39.81 0Z M262.37,266.25a19.91,19.91 0,1 1,-28.42 27.89L229.83,290 197,"
        + "322v16.12a19.91,19.91 0,1 1,-39.81 0v-15.4l-46.74,-46.51a19.85,19.85 0,0 1,-5.11 -8.73A19.57,19.57 0,0 1,108.74 249a"
        + "20.13,20.13 0,0 1,3.05 -3.91l45.13,-44.62L156.92,182.17a19.91,19.91 0,1 1,39.81 0L196.73,200.4l32.81,32.51 4.14,"
        + "-4.4a19.91,19.91 0,0 1,29 27.28l-5.19,5.51Z M345.15,379a19.9,19.9 0,0 1,-28.15 -0.27l-43.12,-43.94a19.91,19.91 0,0 1,"
        + "28.41 -27.89l43.13,43.95A19.9,19.9 0,0 1,345.15 379Z M400.27,445a19.56,19.56 0,0 1,-21.62 -3.93,20.09 20.09,0 0,1 "
        + "-2.81,-2.36l-18.91,-19.27a19.91,19.91 0,0 1,28.42 -27.89l18.91,19.27a20.77,20.77 0,0 1,2.28 2.81,19.85 19.85,0 0,1 "
        + "3.72,5.55A19.58,19.58 0,0 1,400.27 445Z M176.83,236.73l-24.87,24.59l24.84,24.73l25.09,-24.48l-25.06,-24.84z"

    /// Each of Android's subpaths, by its place in ``pathData``.
    private static let subpaths = (
        upperArmTip: 0, upperArm: 1, uprightTop: 2, uprightFoot: 3, node: 4, lowerArm: 5, lowerArmTip: 6, nodeHole: 7
    )

    /// Where relative and absolute numbers part: an absolute number is relative to this.
    static let zero = Point(x: 0, y: 0)
    /// Half of anything.
    static let half = 0.5
    /// Points a curve is sampled at to find its extent.
    private static let samples = 16
    /// The middle coefficients of a cubic's weights, which run 1, 3, 3, 1.
    private static let cubicWeight = 3.0

    /// Android's subpaths regrouped as stitches, in the order they are laid. The node's hole rides with the node.
    private static func laid(_ paths: [[Step]]) -> [[Step]] {
        let order = [
            [subpaths.uprightTop], [subpaths.node, subpaths.nodeHole], [subpaths.uprightFoot], [subpaths.upperArm],
            [subpaths.upperArmTip], [subpaths.lowerArm], [subpaths.lowerArmTip],
        ]
        return order.map { group in group.filter { paths.indices.contains($0) }.flatMap { paths[$0] } }
    }

    /// `stitches` scaled together into the unit square, the longer side filling it and the shorter centered.
    static func fitted(_ stitches: [[Step]]) -> [[Step]] {
        let points = stitches.flatMap(extent)
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
            let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX > minX || maxY > minY
        else {
            return stitches
        }
        let scale = 1 / max(maxX - minX, maxY - minY)
        let offset = Point(
            x: (1 - (maxX - minX) * scale) * half - minX * scale,
            y: (1 - (maxY - minY) * scale) * half - minY * scale
        )
        let fit = { (point: Point) in Point(x: point.x * scale + offset.x, y: point.y * scale + offset.y) }
        return stitches.map { steps in
            steps.map { step in
                switch step {
                case .move(let point):
                    .move(fit(point))
                case .line(let point):
                    .line(fit(point))
                case .curve(let point, let control1, let control2):
                    .curve(fit(point), control1: fit(control1), control2: fit(control2))
                case .close:
                    .close
                }
            }
        }
    }

    /// The points that bound `steps`: every endpoint, and points along each curve, whose handles lie outside it.
    private static func extent(_ steps: [Step]) -> [Point] {
        var points: [Point] = []
        var current = zero
        for step in steps {
            if case .curve(let end, let control1, let control2) = step {
                let start = current
                points += (1...samples).map { sample in
                    let at = Double(sample) / Double(samples)
                    let rest = 1 - at
                    let weights = (rest * rest * rest, cubicWeight * rest * rest * at, cubicWeight * rest * at * at, at * at * at)
                    return Point(
                        x: weights.0 * start.x + weights.1 * control1.x + weights.2 * control2.x + weights.3 * end.x,
                        y: weights.0 * start.y + weights.1 * control1.y + weights.2 * control2.y + weights.3 * end.y
                    )
                }
            }
            if let end = endpoint(step) {
                points.append(end)
                current = end
            }
        }
        return points
    }

    /// Where `step` leaves the pen, or `nil` for a close or no step.
    static func endpoint(_ step: Step?) -> Point? {
        switch step {
        case .move(let point), .line(let point), .curve(let point, _, _):
            point
        case .close, nil:
            nil
        }
    }
}
