#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// Knit's mark, the stitched "K" of knit-next's launcher icon (``KnitMarkPath``), in the largest square its frame holds,
    /// centered (ADR 2026-10.5waw). It fills by the non-zero rule, which cuts the node's hole. One stitch alone, when
    /// `stitch` names it, so the welcome page can lay them in turn.
    internal struct KnitMark: Shape {
        /// Half of anything.
        private static let half: CGFloat = 0.5

        /// The one stitch to draw, by its place in ``KnitMarkPath/stitches``, or `nil` for them all.
        var stitch: Int?

        func path(in rect: CGRect) -> Path {
            let side = min(rect.width, rect.height)
            let origin = CGPoint(x: rect.midX - side * Self.half, y: rect.midY - side * Self.half)
            let place = { (point: KnitMarkPath.Point) in CGPoint(x: origin.x + point.x * side, y: origin.y + point.y * side) }
            var path = Path()
            let stitches = KnitMarkPath.stitches
            let drawn = stitch.map { stitches.indices.contains($0) ? [stitches[$0]] : [] } ?? stitches
            for step in drawn.joined() {
                switch step {
                case .move(let point):
                    path.move(to: place(point))
                case .line(let point):
                    path.addLine(to: place(point))
                case .curve(let point, let control1, let control2):
                    path.addCurve(to: place(point), control1: place(control1), control2: place(control2))
                case .close:
                    path.closeSubpath()
                }
            }
            return path
        }
    }
#endif
