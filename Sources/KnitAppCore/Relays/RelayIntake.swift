public import KnitWire

/// How a relay invite comes in (ADR 2026-11.adrq, P6): an opened link, which must start with an invite's prefix, or pasted
/// text, searched anywhere, each read by ``RelayInvite/parse(_:allowCleartext:)`` and then the dialler's own factory,
/// ``AcceptedSpoolURL``. Neither takes cleartext, in any build: `ws://` is a test socket's alone. The commons and Knit
/// Anywhere fields are ignored, and what is shown, kept and dialled is the one ``AcceptedSpoolURL`` this answers.
public enum RelayIntake {
    /// Why an invite was not taken, in words that name no part of the link.
    public enum Refusal: Sendable, Equatable {
        /// Not an invite this build reads.
        case notAnInvite
        /// An invite, for a relay this build will not dial.
        case unusableRelay
    }

    /// What an invite came to.
    public enum Outcome: Sendable, Equatable {
        case accepted(AcceptedSpoolURL)
        case refused(Refusal)
    }

    /// Whether `text`, an opened URL's absolute string, is a relay invite at all: it starts with one of the two prefixes,
    /// compared byte for byte. Anything else is some other link's business.
    public static func isInviteLink(_ text: String) -> Bool {
        [RelayInvite.urlPrefix, RelayInvite.schemePrefix].contains { text.utf8.starts(with: $0.utf8) }
    }

    /// The opened link `text`, or `nil` when it is not a relay invite (``isInviteLink(_:)``).
    public static func opened(_ text: String) -> Outcome? {
        isInviteLink(text) ? read(text) : nil
    }

    /// Pasted `text`, with an invite anywhere in it.
    public static func pasted(_ text: String) -> Outcome {
        read(text)
    }

    private static func read(_ text: String) -> Outcome {
        switch RelayInvite.parse(text, allowCleartext: false) {
        case .invalid(.badURL):
            return .refused(.unusableRelay)
        case .invalid:
            return .refused(.notAnInvite)
        case .invite(let invite):
            // The dialler's own factory, so the host the sheet names is the host the socket dials.
            guard let url = AcceptedSpoolURL(invite.url, allowCleartext: false) else {
                return .refused(.unusableRelay)
            }
            return .accepted(url)
        }
    }
}
