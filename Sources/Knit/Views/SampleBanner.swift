#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// Whether the sample chats are open, and the way into them, for the screens that offer it (ADR 2026-11.pydf).
    internal struct SampleChats {
        /// Whether the screens on show are the sample's.
        let isOpen: Bool
        let open: @MainActor @Sendable () -> Void
    }

    extension EnvironmentValues {
        /// The sample chats; outside the launch's root, nothing opens.
        @Entry var sampleChats = SampleChats(isOpen: false) {
            // Outside the root, nothing opens.
        }
    }

    /// What the sample chats are, and the way out, above their navigation stack. It can't be dismissed: someone in a real
    /// outage must never take a sample for the real thing (ADR 2026-11.pydf). A sheet covers it while the sheet is up, as New
    /// message and the photo viewer do, and every message is written under it.
    internal struct SampleBanner: View {
        let leave: @MainActor () -> Void

        var body: some View {
            clearOfWindowControls(
                HStack(spacing: Layout.medium) {
                    Text(Copy.Sample.banner)
                        .font(.footnote)
                        // Whole, however it wraps: a sentence cut short here loses the words it exists to say.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityShowsLargeContentViewer { Text(Copy.Sample.banner) }
                        .accessibilityIdentifier(AccessibilityID.sampleBanner)
                    Button(Copy.Sample.leave, action: leave)
                        .prominentButton()
                        .controlSize(.small)
                        .accessibilityLabel(Copy.Sample.leaveLabel)
                        .accessibilityIdentifier(AccessibilityID.sampleLeave)
                }
            )
            .padding(.horizontal, Layout.large)
            .padding(.vertical, Layout.small)
            // A bar over every screen stops growing, as the system's own do, and the Large Content Viewer reads it larger: at
            // the largest size it took half the screen and left a thread no room.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            // Opaque, and under the status bar too: a thread scrolling behind it would fight its words.
            .background(Palette.incomingBubble.ignoresSafeArea(edges: .top))
            .accessibilityElement(children: .contain)
        }

        /// `content`, moved out from under the window controls iPadOS draws at a window's top left, where App Review's iPad shows
        /// them over an iPhone app (ADR 2026-11.pydf). A navigation bar steps aside by itself, and the banner sits above it.
        @ViewBuilder
        private func clearOfWindowControls(_ content: some View) -> some View {
            if #available(iOS 26, *) {
                content.containerCornerOffset(.leading, sizeToFit: true)
            } else {
                content
            }
        }
    }
#endif
