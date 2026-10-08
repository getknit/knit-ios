import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

@testable import KnitAppCore

/// Onboarding (MVP item 1) and Settings' Stop and Start (MVP item 10).
@MainActor
@Suite struct OnboardingAndSettingsTests {
    private func onboarding(_ rig: AppRig, preferences: MemoryPreferences = MemoryPreferences()) -> OnboardingModel {
        OnboardingModel(session: rig.session, preferences: preferences, permission: FakePermission())
    }

    private func onboarding(_ rig: AppRig, permission: FakePermission?) -> OnboardingModel {
        OnboardingModel(session: rig.session, preferences: MemoryPreferences(), permission: permission)
    }

    @Test func theStepsGoWelcomeTermsNameThenPermissions() {
        let model = onboarding(AppRig())
        #expect(model.step == .welcome)
        #expect(model.progress == nil)
        model.next()
        #expect(model.step == .terms)
        model.next()
        #expect(model.step == .name)
        #expect(model.progress == Copy.Onboarding.step(2, of: 3))
        model.next()
        model.next()
        #expect(model.step == .permissions, "the last page is the last")
        model.back()
        model.back()
        model.back()
        model.back()
        #expect(model.step == .welcome)
    }

    @Test func theNamePageSkipsWhileBlankAndCutsAtTheLimit() {
        let model = onboarding(AppRig())
        #expect(model.skipsName)
        model.name = " \t"
        #expect(model.skipsName)
        model.name = String(repeating: "N", count: 50)
        #expect(!model.skipsName)
        #expect(model.name.utf16.count == TextLimits.displayName)
        #expect(model.alias == Alias.alias(for: AppRig.me.nodeId.string))
    }

    @Test func bluetoothIsAskedByStartingTheRadio() async {
        let rig = AppRig()
        let model = onboarding(rig)
        #expect(model.bluetooth == .notAsked)
        await model.allowBluetooth()
        #expect(model.bluetooth == .asking)
        await rig.session.handle(.radioChanged(.off))
        #expect(model.bluetooth == .allowed, "allowed, if switched off")
        await rig.session.handle(.radioChanged(.unauthorized))
        #expect(model.bluetooth == .denied)
        await rig.session.handle(.radioChanged(.unsupported))
        #expect(model.bluetooth == .unsupported)
    }

    @Test func notificationsAreAskedOnce() async {
        let model = onboarding(AppRig(), permission: FakePermission(onRequest: .denied))
        await model.refresh()
        #expect(model.notifications == .notDetermined)
        await model.allowNotifications()
        #expect(model.notifications == .denied)
        let without = onboarding(AppRig(), permission: nil)
        await without.allowNotifications()
        #expect(without.notifications == .denied, "no way to ask is a no")
        await without.refresh()
        #expect(without.notifications == .denied)
    }

    @Test func finishingPublishesTheProfileEvenBlankStartsTheMeshAndIsRemembered() async {
        let rig = AppRig()
        let preferences = MemoryPreferences()
        let model = onboarding(rig, preferences: preferences)
        #expect(!model.isFinished)
        await model.finish()
        #expect(rig.mesh.calls.profiles == ["||false"], "published, so the profile's version moves to now")
        #expect(rig.session.isRunning)
        #expect(model.isFinished)
        #expect(preferences.hasOnboarded)
        #expect(onboarding(rig, preferences: preferences).isFinished)
    }

    @Test func finishingKeepsWhatElseTheProfileSaysAndStartsOnce() async {
        let rig = AppRig()
        rig.stores.ownProfile.save(OwnProfile(name: "", status: "Here", openToChat: true))
        let model = onboarding(rig)
        await model.allowBluetooth()
        model.name = "  Zoë  "
        await model.finish()
        #expect(rig.mesh.calls.profiles == ["Zoë|Here|true"])
        #expect(rig.mesh.calls.starts == 1)
    }

    // MARK: Settings

    @Test func stopAndStartToggleTheMesh() async {
        let rig = AppRig()
        let settings = SettingsModel(session: rig.session, permission: nil, about: AboutInfo(version: "0.1.0", build: "1"))
        #expect(!settings.isRunning)
        await settings.toggleMesh()
        #expect(settings.isRunning)
        await settings.toggleMesh()
        #expect(!settings.isRunning)
        #expect(rig.mesh.calls.starts == 1 && rig.mesh.calls.stops == 1)
    }

    @Test func settingsReadAndAskForNotifications() async {
        let rig = AppRig()
        let settings = SettingsModel(session: rig.session, permission: FakePermission(), about: AboutInfo(version: "1", build: "2"))
        await settings.refresh()
        #expect(settings.notifications == .notDetermined)
        await settings.requestNotifications()
        #expect(settings.notifications == .allowed)
        let without = SettingsModel(session: rig.session, permission: nil, about: settings.about)
        await without.requestNotifications()
        #expect(without.notifications == .denied)
        await without.refresh()
        #expect(without.notifications == .denied)
    }

    @Test func settingsNameUsAndSayWhichBuildThisIs() async {
        let rig = AppRig()
        let settings = SettingsModel(session: rig.session, permission: nil, about: AboutInfo(version: "0.1.0", build: "7"))
        #expect(settings.profileTitle == rig.session.identity.alias)
        await rig.session.updateProfile(name: "Zoë", status: "", openToChat: false)
        #expect(settings.profileTitle == "Zoë")
        #expect(settings.about.versionLine == "Version 0.1.0 (7)")
        #expect(AboutInfo.sourceURL.hasPrefix("https://"))
    }
}
