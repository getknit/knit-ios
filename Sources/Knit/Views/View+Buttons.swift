#if os(iOS)
    import SwiftUI

    extension View {
        /// A filled, prominent button in the tint, its label in ``Palette/onAccent`` so it stays legible on the accent in
        /// dark mode. From iOS 26 it is Liquid Glass tinted coral, as the system draws its own prominent buttons; before
        /// that, the bordered fill (ADR 2026-10.5waw).
        @ViewBuilder
        func prominentButton() -> some View {
            if #available(iOS 26, *) {
                buttonStyle(.glassProminent).foregroundStyle(Palette.onAccent)
            } else {
                buttonStyle(.borderedProminent).foregroundStyle(Palette.onAccent)
            }
        }

        /// A quieter button: the label color on a gray wash, as Signal draws its secondary actions. The system's bordered
        /// style sets coral words on a wash of the same coral, which reads about 4.3:1 in light, under WCAG AA. It stays the
        /// system's style so a list row still takes taps apart from it.
        func secondaryButton() -> some View {
            buttonStyle(.bordered).buttonBorderShape(.capsule).tint(Palette.secondaryText).foregroundStyle(Color.primary)
        }
    }
#endif
