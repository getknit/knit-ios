import KnitAppCore
import Testing

/// `-blind on` and `-blind off`, a debug build's runtime switch for the blinded advert (ADR 2026-11.prsp, "Two gates"): kept
/// for every launch after it that names none, as `-ratchet` is, and on with neither since companion change A11. The
/// app reads and keeps it only in a debug build, whose factory always opens the gate; a release build hands `LaunchOptions`
/// no arguments and no kept choice, and its factory has no switch.
@Suite struct LaunchBlindTests {
    @Test func theArgumentDecidesAndIsTheChoiceToKeep() {
        for stored in [nil, .off, .on] as [LaunchOptions.Choice?] {
            let on = LaunchOptions(arguments: ["Knit", "-blind", "on"], storedBlind: stored)
            let off = LaunchOptions(arguments: ["Knit", "-blind", "off"], storedBlind: stored)
            #expect(on.blind && on.blindChoice == .on, "on, over \(String(describing: stored))")
            #expect(!off.blind && off.blindChoice == .off, "off, over \(String(describing: stored))")
        }
    }

    @Test func aLaunchThatNamesNoChoiceTakesTheKeptOne() {
        let kept = LaunchOptions(arguments: ["Knit"], storedBlind: .on)
        #expect(kept.blind && kept.blindChoice == nil)
        #expect(!LaunchOptions(arguments: ["Knit"], storedBlind: .off).blind)
    }

    @Test func withNeitherTheDebugDefaultStandsAndItIsOn() {
        #expect(LaunchOptions.blindDefault, "on since A11 merged and its trial passed")
        #expect(LaunchOptions(arguments: ["Knit"]).blind == LaunchOptions.blindDefault)
        // A release build hands no arguments and no kept choice, so it reads the default too, and its factory has no switch
        // to set: what keeps it clear is the gate (`AppEnvironment+BlindAdvert.swift`), not this value.
        #expect(LaunchOptions(arguments: []).blind && LaunchOptions(arguments: []).blindChoice == nil, "a release build")
    }

    /// The two switches are apart: one flag never sets the other.
    @Test func theRatchetAndTheAdvertAreApart() {
        let read = LaunchOptions(arguments: ["Knit", "-blind", "on", "-ratchet", "off"], storedRatchet: .on, storedBlind: .off)
        #expect(read.blind && !read.ratchet)
        #expect(read.blindChoice == .on && read.ratchetChoice == .off)
    }

    @Test(arguments: [["Knit", "-blind"], ["Knit", "-blind", "yes"], ["Knit", "-blind", "-seedDemo"]])
    func aMalformedValueChoosesNothing(arguments: [String]) {
        #expect(LaunchOptions(arguments: arguments).blind == LaunchOptions.blindDefault)
        #expect(!LaunchOptions(arguments: arguments, storedBlind: .off).blind)
        #expect(LaunchOptions(arguments: arguments, storedBlind: .on).blind)
        #expect(LaunchOptions(arguments: arguments).blindChoice == nil)
    }
}
