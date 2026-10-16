import KnitAppCore
import Testing

/// `-ratchet on` and `-ratchet off`, a debug build's way onto the dark ratchet for a device trial (ADR 2026-10.5sk9, phase
/// P5b). The choice is kept for every launch after it that names none, so a launch iOS makes by itself, after an install
/// or a reboot, keeps the switch where the trial put it, and its start never republishes the profile without the prekey.
/// The app reads and keeps it only in a debug build: a release build hands `LaunchOptions` no arguments and no kept
/// choice (ADR 2026-10.8cy5), so it never turns the switch on before the flip.
@Suite struct LaunchRatchetTests {
    @Test func theArgumentDecidesAndIsTheChoiceToKeep() {
        for stored in [nil, .off, .on] as [LaunchOptions.Choice?] {
            let on = LaunchOptions(arguments: ["Knit", "-ratchet", "on"], storedRatchet: stored)
            let off = LaunchOptions(arguments: ["Knit", "-ratchet", "off"], storedRatchet: stored)
            #expect(on.ratchet && on.ratchetChoice == .on, "on, over \(String(describing: stored))")
            #expect(!off.ratchet && off.ratchetChoice == .off, "off, over \(String(describing: stored))")
        }
        #expect(!LaunchOptions(arguments: ["Knit", "-ratchet", "on"]).seedDemo, "the live mesh, not the demo")
    }

    @Test func aLaunchThatNamesNoChoiceTakesTheKeptOneAndKeepsNothing() {
        let kept = LaunchOptions(arguments: ["Knit"], storedRatchet: .on)
        #expect(kept.ratchet && kept.ratchetChoice == nil, "iOS's own launch keeps the switch on")
        let keptOff = LaunchOptions(arguments: ["Knit"], storedRatchet: .off)
        #expect(!keptOff.ratchet && keptOff.ratchetChoice == nil)
    }

    /// What the app keeps is the choice's own word, read back as the same choice.
    @Test func aChoiceIsKeptAsItsWord() {
        for choice in [LaunchOptions.Choice.on, .off] {
            #expect(LaunchOptions.Choice(word: choice.word) == choice)
        }
        #expect(LaunchOptions.Choice.on.word == "on" && LaunchOptions.Choice.off.word == "off")
        #expect(LaunchOptions.Choice(word: "yes") == nil && LaunchOptions.Choice(word: "") == nil)
    }

    @Test func withNeitherTheSwitchIsOff() {
        #expect(!LaunchOptions(arguments: ["Knit"]).ratchet)
        #expect(LaunchOptions(arguments: []) == LaunchOptions(arguments: [], storedRatchet: nil), "what a release build reads")
        #expect(!LaunchOptions(arguments: []).ratchet && LaunchOptions(arguments: []).ratchetChoice == nil)
    }

    /// `-ratchet` with no value, or with one other than `on` and `off`, chooses nothing: the kept choice stands, or off with
    /// none, and nothing is kept, so a slip never turns the switch off behind a trial's back, nor on.
    @Test(arguments: [["Knit", "-ratchet"], ["Knit", "-ratchet", "yes"], ["Knit", "-ratchet", "ON"], ["Knit", "-ratchet", "-seedDemo"]])
    func aMalformedValueChoosesNothing(arguments: [String]) {
        let none = LaunchOptions(arguments: arguments)
        #expect(!none.ratchet && none.ratchetChoice == nil)
        let kept = LaunchOptions(arguments: arguments, storedRatchet: .on)
        #expect(kept.ratchet && kept.ratchetChoice == nil)
        #expect(LaunchOptions(arguments: ["Knit", "-ratchet", "-seedDemo"]).seedDemo, "the next flag is read as itself")
    }
}
