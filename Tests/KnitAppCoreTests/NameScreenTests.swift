import Testing

@testable import KnitAppCore

/// The name screen's reading of a name (`NameScreenTest.kt`, knit-next ADR 2026-11.y4pc), over small lists so each rule
/// is seen alone, then the corners of Unicode the vectors leave out, each verdict the one knit-next's own compiled
/// `NameScreen` gave on 2026-11-14.
@Suite struct NameScreenTests {
    private let screen = NameScreen(
        slurs: ["pikey", "kike"],
        profanity: ["fuck", "dick", "pikey", "kike", "shit"],
        embeddable: ["fuck", "pikey"],
        exclusions: ["spikey"],
        allowedNames: ["dick", "pikey"]
    )

    private func everyone(_ name: String) -> NameScreen.Verdict {
        screen.check(name, audience: .everyone)
    }

    @Test func aPlainNameIsAllowed() {
        for name in ["Alice Smith", "", "   "] {
            #expect(!everyone(name).flagged, "\(name)")
        }
    }

    @Test func aTermAsAWholeWordIsFlagged() {
        for name in ["Mr Fuck", "fuck_lord", "Fuck69", "sh1t"] {
            #expect(everyone(name).flagged, "\(name)")
        }
    }

    @Test func camelCaseAndDigitRunsSplitAHandleIntoWords() {
        // "dick" is allowed as a real name, so "shit" carries the split cases.
        for name in ["BigShit", "xXShitXx", "Shit4Brains"] {
            #expect(everyone(name).flagged, "\(name)")
        }
        #expect(!WordFilter(words: ["shit"]).flags("BigShit"), "the message filter alone misses it")
    }

    @Test func anEmbeddableTermIsFoundInsideAWordAndANonEmbeddableOneIsNot() {
        #expect(everyone("bigfuckboy").flagged)
        #expect(everyone("pikeyboy").flagged)
        #expect(!everyone("bigshitboy").flagged, "shit is not embeddable (Akshit)")
    }

    @Test func anExclusionCutsTheWordBeforeTheInsideLookAndTheRestIsStillRead() {
        #expect(!everyone("spikeyboy").flagged)
        #expect(everyone("spikeyfuck").flagged)
    }

    @Test func aDigitIsALeetLetterInsideAWordOnlyBetweenLetters() {
        let shit = NameScreen(slurs: [], profanity: ["shit"], embeddable: ["shit"], exclusions: [], allowedNames: [])
        #expect(shit.check("ash1tlord", audience: .everyone).flagged, "1 between h and t is i: ashitlord")
        #expect(!shit.check("ash17tripathi", audience: .everyone).flagged, "next to another digit, 1 and 7 separate")
        #expect(everyone("p1keyboy").flagged)
        #expect(!everyone("pi9keyboy").flagged, "a digit with no letter it stands for separates, even between letters")
    }

    @Test func aRealNameOnTheAllowListPassesAsAWholeWordButNeverWhenItIsASlur() {
        for name in ["Dick Smith", "Dick", "JohnDick"] {
            #expect(!everyone(name).flagged, "\(name)")
        }
        // Only as written: a leet spelling is not a name, so it is read against the list as usual.
        #expect(everyone("BigD1ck69").flagged)
        #expect(everyone("D!ck").flagged)
        #expect(everyone("Pikey") == .slur, "on the allow-list and the slur list: the slur list wins")
    }

    @Test func aGroupNameTakesTheSlurListAlone() {
        #expect(!screen.check("Fuck Mondays", audience: .members).flagged)
        #expect(screen.check("Kike Club", audience: .members) == .slur)
        #expect(screen.check("pikeyboys", audience: .members) == .slur)
    }

    @Test func aHitReportsWhichListTrippedIt() {
        #expect(everyone("kike") == .slur)
        #expect(everyone("fuck") == .profanity)
        #expect(everyone("Alice") == .allowed)
    }

    // MARK: Unicode, over the shipped lists

    /// Each verdict here is what knit-next's compiled `NameScreen` answered over its shipped lists on the JDK. None
    /// turns on `\s`, where the JDK and ART differ.
    @Test(arguments: [
        ("Big\u{A0}Fuck", NameScreen.Verdict.profanity),
        ("\u{FF26}\u{FF35}\u{FF23}\u{FF2B}", .profanity),
        ("\u{1D42C}\u{1D421}1\u{1D42D}", .profanity),
        ("XMLFuckParser", .profanity),
        ("fuck\u{2019}s sake", .profanity),
        ("\u{661}fuck\u{662}", .profanity),
        ("pikey\u{338F}boy", .slur),
        ("bigfuck\u{338F}", .profanity),
        ("bigp1keyboy", .slur),
        ("a\u{661}pikey", .slur),
        ("sp1keyboy", .allowed),
    ])
    func theShippedScreenReadsUnicodeAsAndroidDoes(name: String, verdict: NameScreen.Verdict) {
        #expect(ShippedNameLists.screen.check(name, audience: .everyone) == verdict)
    }

    @Test func aDigitBesideALetterOutsideTheBMPSeparatesAsKotlinsCharReadsIt() {
        // 𝐩1𝐤𝐞𝐲: Kotlin sees surrogate halves beside the 1, never letters, so the 1 separates and no pikey is read.
        #expect(ShippedNameLists.screen.check("big\u{1D429}1\u{1D424}\u{1D41E}\u{1D432}boy", audience: .everyone) == .allowed)
    }

    @Test func anAllowedNameIsAWordInLettersSoADecomposedOneIsReadAgainstTheList() {
        // A combining accent is not a letter, so "Di\u{301}ck" is the runs "Di" and "ck", neither a name.
        #expect(ShippedNameLists.screen.check("D\u{ED}ck", audience: .everyone) == .allowed)
        #expect(ShippedNameLists.screen.check("Di\u{301}ck", audience: .everyone) == .profanity)
        #expect(ShippedNameLists.screen.check("Di\u{301}ck Smith", audience: .everyone) == .profanity)
    }

    @Test func aControlInsideASlurHidesItFromTheRawNameAndNotFromTheCleanedOne() {
        // Android screens a group's stored name, and cleans it only to draw it: the bidi control splits "pikey" for the
        // screen, then goes, so the slur draws. The iPhone screens what it draws (GroupNaming).
        let raw = "pi\u{202E}key club"
        #expect(ShippedNameLists.screen.check(raw, audience: .members) == .allowed)
        #expect(ShippedNameLists.screen.check("pikey club", audience: .members) == .slur)
        #expect(ShippedNameLists.screen.check("Fuck\u{A0}Mondays", audience: .members) == .allowed)
    }
}
