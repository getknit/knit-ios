#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// Knit's mark, laid a stitch at a time as it appears, once, in the order a needle would lay them (ADR 2026-10.5waw).
    /// With Reduce Motion on it is there whole from the start. Decorative.
    internal struct LayingMark: View {
        /// The time between one stitch and the next, in milliseconds.
        private static let pace = 90
        /// How long a stitch takes to fade in, in seconds.
        private static let fade = 0.25

        @State private var laid = 0
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            ZStack {
                ForEach(KnitMarkPath.stitches.indices, id: \.self) { index in
                    KnitMark(stitch: index)
                        .fill(.tint)
                        .opacity(index < laid || reduceMotion ? 1 : 0)
                }
            }
            .accessibilityHidden(true)
            .task {
                guard !reduceMotion else {
                    return
                }
                for index in KnitMarkPath.stitches.indices {
                    guard (try? await Task.sleep(for: .milliseconds(Self.pace))) != nil else {
                        return
                    }
                    withAnimation(.easeOut(duration: Self.fade)) {
                        laid = index + 1
                    }
                }
            }
        }
    }
#endif
