#if os(iOS)
    import SwiftUI

    extension View {
        /// `bar` pinned under the view: from iOS 26 a bar whose scroll edge effect fades the content under it, as the
        /// system's own bars do; before that, an inset.
        @ViewBuilder
        func bottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
            let content = bar()
            if #available(iOS 26, *) {
                safeAreaBar(edge: .bottom) { content }
            } else {
                safeAreaInset(edge: .bottom) { content }
            }
        }

        /// The surface under a set of controls, such as the composer (ADR 2026-10.5waw): from iOS 26, a Liquid Glass panel
        /// clear of the screen's edges; before that, and with Reduce Transparency on, the opaque bar it always was. Words in
        /// the panel keep an opaque fill of their own, so their contrast never depends on what scrolls behind the glass.
        func glassPanel() -> some View {
            modifier(GlassPanel())
        }
    }

    private struct GlassPanel: ViewModifier {
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

        func body(content: Content) -> some View {
            if #available(iOS 26, *), !reduceTransparency {
                content
                    .glassEffect(.regular, in: .rect(cornerRadius: Layout.panelCorner, style: .continuous))
                    .padding(.horizontal, Layout.small)
                    .padding(.bottom, Layout.tight)
            } else {
                content
                    .background(.background.secondary)
            }
        }
    }
#endif
