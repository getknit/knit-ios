#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// About: the version, the licence notice, the source, what encryption covers, and what ships inside.
    internal struct AboutView: View {
        let about: AboutInfo

        var body: some View {
            Form {
                Section {
                    Text(about.versionLine)
                        .accessibilityIdentifier(AccessibilityID.aboutVersion)
                    Text(Copy.About.license)
                        .accessibilityIdentifier(AccessibilityID.aboutLicense)
                    if let url = URL(string: AboutInfo.sourceURL) {
                        Link(Copy.About.source, destination: url)
                            .accessibilityIdentifier(AccessibilityID.aboutSource)
                    }
                }
                Section {
                    Text(Copy.About.security)
                }
                Section {
                    ForEach(ThirdPartyNotice.shipped + ThirdPartyNotice.bundled) { notice in
                        if let url = URL(string: notice.url) {
                            Link(destination: url) {
                                ValueRow(notice.name, value: notice.license)
                            }
                        }
                    }
                } header: {
                    SectionNote(Copy.About.notices)
                }
            }
            .navigationTitle(Copy.About.title)
            .accessibilityIdentifier(AccessibilityID.aboutScreen)
        }
    }
#endif
