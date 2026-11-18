import Foundation
import KnitAppCore
import Testing

extension CopyCatalogTests {
    /// Internet relays' strings (ADR 2026-11.adrq, P6), apart so the suite stays under the lint's length.
    static var relayStrings: [String] {
        [
            Copy.Relays.title,
            Copy.Relays.switchTitle,
            Copy.Relays.footer,
            Copy.Relays.knitsRelay,
            Copy.Relays.notKnits,
            Copy.Relays.privateMark,
            Copy.Relays.connected,
            Copy.Relays.connecting,
            Copy.Relays.waiting,
            Copy.Relays.paused,
            Copy.Relays.parked,
            Copy.Relays.off,
            Copy.Relays.unreadable,
            Copy.Relays.missing,
            Copy.Relays.unusable,
            Copy.Relays.park,
            Copy.Relays.unpark,
            Copy.Relays.remove,
            Copy.Relays.addHeader,
            Copy.Relays.pasteFooter,
            Copy.Relays.empty,
            Copy.RelayConsent.turnOnTitle,
            Copy.RelayConsent.turnOnHosts,
            Copy.RelayConsent.turnOnNone,
            Copy.RelayConsent.learns,
            Copy.RelayConsent.textOnly,
            Copy.RelayConsent.openOnly,
            Copy.RelayConsent.turnOn,
            Copy.RelayConsent.notNow,
            Copy.RelayConsent.addTitle,
            Copy.RelayConsent.privateNote,
            Copy.RelayConsent.offNote,
            Copy.RelayConsent.add,
            Copy.RelayConsent.inviteAlert,
            Copy.RelayConsent.notAnInvite,
            Copy.RelayConsent.unusableInvite,
            Copy.RelayConsent.duplicate,
            Copy.RelayConsent.listUnavailable,
            Copy.RelayConsent.notSaved,
            Copy.Relays.duplicateRow,
            Copy.Relays.listUnreadable,
            Copy.RelayConsent.joinsOnceRead,
            Copy.RelayConsent.consentNotSaved,
            Copy.Relays.numbered(3),
            Copy.Relays.full(8),
        ]
    }

    /// Every relay string is clean prose on one line, as the rest of the catalog is (`everyStringIsCleanProseOnOneLine`).
    @Test func everyRelayStringIsCleanProseOnOneLine() {
        #expect(Self.relayStrings.count > 40)
        for text in Self.relayStrings {
            #expect(!text.isEmpty)
            #expect(!text.contains("\n") && !text.contains("  ") && !text.contains(" .") && !text.contains(" ,"), "\(text)")
            #expect(text == text.trimmingCharacters(in: .whitespaces), "\(text)")
            #expect(!text.contains("%"), "a placeholder left unfilled: \(text)")
        }
    }

    /// The consent says what a relay learns, in the words the security review asked for.
    @Test func theConsentSaysWhatARelayLearns() {
        let learns = Copy.RelayConsent.learns
        for part in ["a code for each conversation", "your contacts", "when messages move", "when Knit is open", "IP address"] {
            #expect(learns.contains(part), "\(part)")
        }
        #expect(learns.contains("can't read your messages"))
    }

    /// The boundary is named plainly: text messages alone, and only while Knit is open.
    @Test func theRelaysNameWhatTheyCarryAndWhenTheyRun() {
        #expect(Copy.Relays.footer.contains("only while Knit is open"))
        #expect(Copy.RelayConsent.openOnly.contains("only while Knit is open"))
        #expect(Copy.RelayConsent.textOnly.contains("text messages"))
        for kind in ["Photos", "voice messages", "groups", "Nearby room"] {
            #expect(Copy.RelayConsent.textOnly.contains(kind))
        }
        #expect(Copy.Relays.numbered(3) == "Relay 3")
        // The access-key mark says what an address carries, and nothing of relays without it.
        #expect(Copy.Relays.privateMark == "Access key in link")
        #expect(Copy.Relays.full(8).contains("8 relays"))
    }
}
