import Foundation

extension KnitMarkPath {
    /// An arc's sweep: the longer way round or the shorter, and clockwise (on a y-down screen) or not.
    struct ArcFlags {
        let large: Bool
        let sweep: Bool
    }

    /// The degrees in half a turn.
    private static let degreesPerHalfTurn = 180.0
    /// The widest one cubic curve draws of an arc: a quarter turn.
    private static let quarterTurn = Double.pi * half
    /// A whole turn, 2π.
    private static let fullTurn = Double.pi / half
    /// A quarter, which takes a curve's span to the angle its handle length is figured from.
    private static let quarter = 0.25
    /// Three quarters: a circle's handle is tan(θ/4) / (3/4) of its radius.
    private static let threeQuarters = 0.75

    /// An elliptical arc as cubic curves of a quarter turn or less (the SVG spec's appendix on arcs, F.6.5 and F.6.6).
    static func arc(from start: Point, to end: Point, radii: (Double, Double), rotation: Double, flags: ArcFlags) -> [Step] {
        guard start != end else {
            return []
        }
        guard abs(radii.0) > 0, abs(radii.1) > 0 else {
            return [.line(end)]
        }
        let phi = rotation * .pi / degreesPerHalfTurn
        let ellipse = Ellipse(start: start, end: end, radii: radii, phi: phi, flags: flags)
        var delta = ellipse.angle(from: ellipse.startVector, to: ellipse.endVector)
        if !flags.sweep, delta > 0 {
            delta -= fullTurn
        } else if flags.sweep, delta < 0 {
            delta += fullTurn
        }
        let theta = ellipse.angle(from: (1, 0), to: ellipse.startVector)
        let count = max(1, Int((abs(delta) / quarterTurn).rounded(.up)))
        let span = delta / Double(count)
        let handle = tan(span * quarter) / threeQuarters
        return (0..<count).map { index in
            let (from, to) = (theta + span * Double(index), theta + span * Double(index + 1))
            let (cos1, sin1, cos2, sin2) = (cos(from), sin(from), cos(to), sin(to))
            return .curve(
                index == count - 1 ? end : ellipse.place(cos2, sin2),
                control1: ellipse.place(cos1 - handle * sin1, sin1 + handle * cos1),
                control2: ellipse.place(cos2 + handle * sin2, sin2 - handle * cos2)
            )
        }
    }

    /// The ellipse an arc runs along, found from its endpoints (F.6.5), its radii grown if they cannot span them (F.6.6).
    private struct Ellipse {
        let center: Point
        let radii: (Double, Double)
        let cosPhi: Double
        let sinPhi: Double
        /// The start, from the center, in the ellipse's own frame and radii.
        let startVector: (Double, Double)
        /// The end, likewise.
        let endVector: (Double, Double)

        init(start: Point, end: Point, radii: (Double, Double), phi: Double, flags: ArcFlags) {
            var (rx, ry) = (abs(radii.0), abs(radii.1))
            (cosPhi, sinPhi) = (cos(phi), sin(phi))
            let (halfX, halfY) = ((start.x - end.x) * half, (start.y - end.y) * half)
            let x1 = cosPhi * halfX + sinPhi * halfY
            let y1 = -sinPhi * halfX + cosPhi * halfY
            let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
            if lambda > 1 {
                rx *= lambda.squareRoot()
                ry *= lambda.squareRoot()
            }
            let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
            let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
            let coefficient = (flags.large == flags.sweep ? -1 : 1) * max(0, numerator / denominator).squareRoot()
            let (centerX1, centerY1) = (coefficient * rx * y1 / ry, -coefficient * ry * x1 / rx)
            center = Point(
                x: cosPhi * centerX1 - sinPhi * centerY1 + (start.x + end.x) * half,
                y: sinPhi * centerX1 + cosPhi * centerY1 + (start.y + end.y) * half
            )
            self.radii = (rx, ry)
            startVector = ((x1 - centerX1) / rx, (y1 - centerY1) / ry)
            endVector = ((-x1 - centerX1) / rx, (-y1 - centerY1) / ry)
        }

        /// The signed angle from `first` to `second`.
        func angle(from first: (Double, Double), to second: (Double, Double)) -> Double {
            atan2(first.0 * second.1 - first.1 * second.0, first.0 * second.0 + first.1 * second.1)
        }

        /// A point on the unit circle, `along` and `across`, carried onto the ellipse.
        func place(_ along: Double, _ across: Double) -> Point {
            Point(
                x: center.x + radii.0 * along * cosPhi - radii.1 * across * sinPhi,
                y: center.y + radii.0 * along * sinPhi + radii.1 * across * cosPhi
            )
        }
    }
}
