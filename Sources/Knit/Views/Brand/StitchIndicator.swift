#if os(iOS)
    import SwiftUI

    /// Knit's "something is on its way": three knit stitches, the "V" a stitch makes on the needle, with a highlight that
    /// sweeps across and lifts each one as it passes, like a needle laying a row (`KnitStitchIndicator.kt` in knit-next,
    /// ADR 2026-10.5waw). It stands where a spinner would. Decorative: the words beside it say what is under way. With
    /// Reduce Motion on it holds still, the middle stitch lit. It grows with the text size.
    internal struct StitchIndicator: View {
        /// How many stitches (`STITCHES`).
        private static let stitches = 3
        /// One sweep, in seconds (`SWEEP_MS`).
        private static let sweep = 1.2
        /// The stitches' worth of sweep past the last one, every stitch dim, before it starts again (`PAUSE`).
        private static let pause = 0.5
        /// An unlit stitch's opacity (`DIM_ALPHA`).
        private static let dim = 0.35
        /// Where the sweep rests with Reduce Motion on: on the middle stitch.
        private static let still = 1.5
        /// The canvas, as Android sizes it in dp.
        private static let width: CGFloat = 34
        private static let height: CGFloat = 14
        /// A stitch's half width, as a fraction of its slot.
        private static let halfWidth: CGFloat = 0.35
        /// A stitch's half height, and how far the sweep lifts it.
        private static let halfHeight: CGFloat = 4
        private static let lift: CGFloat = 2
        /// The stroke.
        private static let lineWidth: CGFloat = 2.5
        /// Half of anything.
        private static let half: CGFloat = 0.5

        /// The stitches' color: the tint, unless the caller picks another.
        var color = Palette.accent
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

        var body: some View {
            TimelineView(.animation(paused: reduceMotion)) { context in
                Canvas { canvas, size in
                    draw(in: &canvas, size: size, phase: reduceMotion ? Self.still : Self.phase(at: context.date))
                }
            }
            .frame(width: Self.width * scale, height: Self.height * scale)
            .accessibilityHidden(true)
        }

        /// Where the sweep is at `date`: from 0 to the last stitch's far edge and through the pause.
        private static func phase(at date: Date) -> Double {
            let span = Double(stitches) + pause
            return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: sweep) / sweep * span
        }

        private func draw(in canvas: inout GraphicsContext, size: CGSize, phase: Double) {
            let slot = size.width / CGFloat(Self.stitches)
            let stroke = StrokeStyle(lineWidth: Self.lineWidth * scale, lineCap: .round, lineJoin: .round)
            for index in 0..<Self.stitches {
                // Brightest as the sweep crosses the stitch's middle, fading with distance.
                let lit = min(max(1 - abs(phase - (Double(index) + Self.half)), 0), 1)
                let rise = -Self.lift * scale * lit
                let center = CGPoint(x: slot * (CGFloat(index) + Self.half), y: size.height * Self.half + rise)
                var stitch = Path()
                stitch.move(to: CGPoint(x: center.x - slot * Self.halfWidth, y: center.y - Self.halfHeight * scale))
                stitch.addLine(to: CGPoint(x: center.x, y: center.y + Self.halfHeight * scale))
                stitch.addLine(to: CGPoint(x: center.x + slot * Self.halfWidth, y: center.y - Self.halfHeight * scale))
                canvas.stroke(stitch, with: .color(color.opacity(Self.dim + (1 - Self.dim) * lit)), style: stroke)
            }
        }
    }
#endif
