import Foundation
import Testing

@testable import KnitAppCore

/// The terms of use (ADR 2026-10.cgm3): onboarding asks for them before the name, an install that onboarded before
/// them is asked before the app opens, and an agreement lasts until the terms change.
@MainActor
@Suite struct TermsTests {
    private func onboarding(_ preferences: MemoryPreferences) -> OnboardingModel {
        OnboardingModel(session: AppRig().session, preferences: preferences, permission: nil)
    }

    @Test func onboardingAsksForTheTermsBeforeTheName() async {
        let preferences = MemoryPreferences()
        let model = onboarding(preferences)
        #expect(!model.acceptedTerms)
        model.next()
        #expect(model.step == .terms)
        #expect(model.progress == Copy.Onboarding.step(1, of: 3))
        model.acceptTerms()
        #expect(model.step == .name, "agreeing goes on")
        #expect(model.acceptedTerms && preferences.acceptedTerms == Terms.version)
        model.back()
        #expect(model.step == .terms, "the terms stay a page back")
        await model.finish()
        #expect(onboarding(preferences).acceptedTerms, "remembered")
    }

    @Test func anInstallThatOnboardedBeforeTheTermsIsAskedAndStaysPut() {
        let preferences = MemoryPreferences(hasOnboarded: true)
        let model = onboarding(preferences)
        #expect(model.isFinished && !model.acceptedTerms)
        model.acceptTerms()
        #expect(model.acceptedTerms)
        #expect(model.step == .welcome, "no onboarding page moves after it")
    }

    @Test func newerTermsAskAgain() {
        #expect(!onboarding(MemoryPreferences(hasOnboarded: true, acceptedTerms: Terms.version - 1)).acceptedTerms)
        #expect(onboarding(MemoryPreferences(hasOnboarded: true, acceptedTerms: Terms.version)).acceptedTerms)
    }

    @Test func theRulesAreFourAndDistinct() {
        #expect(Terms.rules.count == 4)
        #expect(Set(Terms.rules).count == Terms.rules.count)
    }

    @Test func theLabIPhonesLaunchAgreesToTheseTerms() throws {
        // The device tests launch with `-acceptedTerms` so the iPhone opens on the app; a raised version needs it raised.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let live = try String(contentsOf: root.appending(path: "Tests/KnitDeviceTests/LiveKnit.swift"), encoding: .utf8)
        #expect(live.contains("static let acceptedTerms = \"\(Terms.version)\""))
    }
}

extension CopyCatalogTests {
    /// The terms' strings (ADR 2026-10.cgm3), apart so the suite stays under the lint's length.
    static var termsStrings: [String] {
        [Copy.Terms.title, Copy.Terms.intro, Copy.Terms.enforcement, Copy.Terms.agree] + Terms.rules
    }
}
