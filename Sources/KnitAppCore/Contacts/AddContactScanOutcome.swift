/// What scanning a code in Add contact did (ADR 2026-10.tpr5): Android's `VerifyResult` on its Add contact screen
/// (`AddContactViewModel.onScanned`), plus a store that refused the pin.
public enum AddContactScanOutcome: Sendable, Equatable, CaseIterable {
    /// Their key pinned from the code, or matched the one pinned, and they are verified: a contact now.
    case added
    /// A valid code whose key is not the one pinned for its id. Nothing was written.
    case mismatch
    /// Our own code.
    case ownCode
    /// Not a Knit code, or one no key could have made.
    case notACode
    /// The pin did not land.
    case failed
}

/// Why a pasted or opened link added nobody (`AddContactEvent` in knit-next).
public enum AddContactProblem: Sendable, Equatable {
    /// Not a contact link, or one whose signature or id does not hold.
    case notALink
    /// Our own link.
    case ownLink
    /// A valid link whose key is not the one pinned for the person labelled `name`.
    case mismatch(name: String)
    /// The pin did not land.
    case failed
}
