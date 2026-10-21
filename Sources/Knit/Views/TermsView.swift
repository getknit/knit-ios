#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// The terms (ADR 2026-10.cgm3): who may use Knit (ADR 2026-10.tydq), what the terms are for, each rule, and what a
    /// report does. Onboarding's terms page heads them with its own heading; About's page has its title instead.
    internal struct TermsSections: View {
        /// Whether the section opens with the terms' heading.
        let heading: Bool

        var body: some View {
            Section {
                Text(Copy.Terms.age)
                Text(Copy.Terms.intro)
                ForEach(Terms.rules, id: \.self) { rule in
                    Label(rule, systemImage: "nosign")
                }
            } header: {
                if heading {
                    PageHeading(text: Copy.Terms.title)
                }
            } footer: {
                SectionNote(Copy.Terms.enforcement)
            }
        }
    }

    /// The terms, read from About.
    internal struct TermsView: View {
        var body: some View {
            Form {
                TermsSections(heading: false)
            }
            .navigationTitle(Copy.Terms.title)
            .accessibilityIdentifier(AccessibilityID.termsScreen)
        }
    }
#endif
