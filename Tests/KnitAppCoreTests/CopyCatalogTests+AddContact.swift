import KnitAppCore
import Testing

extension CopyCatalogTests {
    /// Add contact's strings (ADR 2026-10.tpr5), apart so the suite stays under the lint's length.
    static var addContactStrings: [String] {
        [
            Copy.AddContact.title,
            Copy.AddContact.inPerson,
            Copy.AddContact.codeCaption,
            Copy.AddContact.shareLink,
            Copy.AddContact.copyLink,
            Copy.AddContact.linkCopied,
            Copy.AddContact.linkCaption,
            Copy.AddContact.shareText("https://getknit.app/c#abc"),
            Copy.AddContact.byLink,
            Copy.AddContact.byLinkCaption,
            Copy.AddContact.inputLabel,
            Copy.AddContact.inputPrompt,
            Copy.AddContact.lookup,
            Copy.AddContact.previewTitle("Sam"),
            Copy.AddContact.safetyCaption("Sam"),
            Copy.AddContact.already("Sam"),
            Copy.AddContact.blocked,
            Copy.AddContact.confirm,
            Copy.AddContact.confirmUnblocking,
        ] + AddContactScanOutcome.allCases.map(Copy.AddContact.scanOutcome)
            + [.notALink, .ownLink, .mismatch(name: "Sam"), .failed].map(Copy.AddContact.problem)
    }

    @Test func addContactsWordsNameThePersonAndCarryTheLink() {
        #expect(Copy.AddContact.previewTitle("Sam") == "Add Sam?")
        #expect(Copy.AddContact.already("Sam") == "Sam is already in your contacts.")
        #expect(Copy.AddContact.safetyCaption("Sam").hasPrefix("Compare this number with Sam "))
        #expect(Copy.AddContact.shareText("https://getknit.app/c#abc").hasSuffix("https://getknit.app/c#abc"))
    }
}
