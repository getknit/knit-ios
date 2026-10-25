#if os(iOS)
    import SwiftUI

    /// How far a photo streaming in has got: a thin ring that fills clockwise from twelve o'clock over a faint track, as
    /// the App Store and Messages draw a download (`ArrivalIndicator` in knit-next, ADR 2026-10.y9qh). It eases to each
    /// sample and then holds still, so a stalled stream lets the screen settle: nothing here animates without end
    /// (knit-next #72). With Reduce Motion on it steps. It is decorative: the caption under it says how much is in.
    internal struct ArrivalRing: View {
        /// The share in, from 0 to 1.
        let fraction: Double

        /// The ring's side and stroke at the default text size (Android's 24 dp ring, a touch larger for a 160-point box).
        private static let side: CGFloat = 28
        private static let lineWidth: CGFloat = 2.5
        /// The track's opacity under the ring (`TRACK_ALPHA`).
        private static let track = 0.3
        /// How long the ring takes to reach a new sample, in seconds: under the 500 ms between samples, so it is still
        /// before the next.
        private static let ease = 0.4
        /// A quarter turn back, so the ring starts at twelve o'clock.
        private static let quarterTurnBack = -90.0
        private static let start = Angle.degrees(quarterTurnBack)

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

        var body: some View {
            ZStack {
                Circle()
                    .stroke(Palette.accent.opacity(Self.track), lineWidth: Self.lineWidth * scale)
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: Self.lineWidth * scale, lineCap: .round))
                    .rotationEffect(Self.start)
            }
            .frame(width: Self.side * scale, height: Self.side * scale)
            .animation(reduceMotion ? nil : .easeOut(duration: Self.ease), value: fraction)
            .accessibilityHidden(true)
        }
    }
#endif
