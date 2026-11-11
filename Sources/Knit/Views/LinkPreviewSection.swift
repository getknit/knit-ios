#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// Settings' link previews switch, in a build that sends cards (ADR 2026-11.hcvg): off until it is turned on, and its
    /// footer says what turning it on costs, the site seeing this phone's address (`settings_link_previews_title`).
    internal struct LinkPreviewSection: View {
        @Bindable var session: AppSession

        var body: some View {
            Section {
                Toggle(isOn: $session.sendsLinkPreviews) {
                    RowLabel(Copy.LinkPreviews.settingTitle, symbol: "link")
                }
                .accessibilityIdentifier(AccessibilityID.settingsLinkPreviews)
            } footer: {
                SectionNote(Copy.LinkPreviews.settingFooter)
            }
        }
    }
#endif
