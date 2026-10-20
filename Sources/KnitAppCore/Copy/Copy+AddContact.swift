import Foundation

extension Copy {
    /// Add contact: our code and link, the scanner, and a link someone sent (ADR 2026-10.tpr5). Android's `add_contact_*`,
    /// `contact_link_*` and `verify_*` strings, adapted to an iPhone that reaches people over Bluetooth alone.
    public enum AddContact {
        /// The screen's title, and the button that opens it.
        public static var title: String {
            NSLocalizedString("add-contact.title", bundle: .main, value: "Add contact", comment: "Screen title and button: add a contact")
        }

        /// What the code and the scanner are for.
        public static var inPerson: String {
            NSLocalizedString(
                "add-contact.in-person",
                bundle: .main,
                value: "Show your code to someone nearby, or scan theirs, to add them as a verified contact, even if you've never chatted.",
                comment: "Add contact: what showing and scanning a code does"
            )
        }

        /// The caption under our own code.
        public static var codeCaption: String {
            NSLocalizedString(
                "add-contact.code.caption",
                bundle: .main,
                value: "Let them scan this code.",
                comment: "Add contact: under the user's own code"
            )
        }

        /// The button that shares our contact link.
        public static var shareLink: String {
            NSLocalizedString(
                "add-contact.share-link", bundle: .main, value: "Share link", comment: "Add contact: shares the user's contact link")
        }

        /// The button that copies our contact link.
        public static var copyLink: String {
            NSLocalizedString(
                "add-contact.copy-link", bundle: .main, value: "Copy link", comment: "Add contact: copies the user's contact link")
        }

        /// Said once our link is copied.
        public static var linkCopied: String {
            NSLocalizedString("add-contact.link-copied", bundle: .main, value: "Link copied", comment: "Add contact: the link was copied")
        }

        /// What our link is for.
        public static var linkCaption: String {
            NSLocalizedString(
                "add-contact.link.caption",
                bundle: .main,
                value: "If you're too far apart to scan, send your link instead. They add you from yours, and you add them from theirs.",
                comment: "Add contact: what sharing the user's link does"
            )
        }

        /// The text that goes with our link when it is shared; `url` is the link.
        public static func shareText(_ url: String) -> String {
            format(
                NSLocalizedString(
                    "add-contact.share-text",
                    bundle: .main,
                    value: "Add me on Knit: %@",
                    comment: "Add contact: the message the user's link is shared in; %@ is the link"
                ),
                url
            )
        }

        /// The section that takes a link someone sent.
        public static var byLink: String {
            NSLocalizedString(
                "add-contact.by-link", bundle: .main, value: "Add by link", comment: "Add contact: the section that takes a link")
        }

        /// How to add someone from their link.
        public static var byLinkCaption: String {
            NSLocalizedString(
                "add-contact.by-link.caption",
                bundle: .main,
                value: "Paste a contact link someone sent you. Send them yours too, so they can add you.",
                comment: "Add contact: how to add someone from a link"
            )
        }

        /// The link field's label.
        public static var inputLabel: String {
            NSLocalizedString(
                "add-contact.input.label", bundle: .main, value: "Contact link", comment: "Add contact: the link field's label")
        }

        /// The link field's placeholder, the shape of a link.
        public static var inputPrompt: String {
            NSLocalizedString(
                "add-contact.input.prompt",
                bundle: .main,
                value: "https://getknit.app/c#…",
                comment: "Add contact: the link field's placeholder, the shape of a contact link"
            )
        }

        /// The button that reads the link in the field.
        public static var lookup: String {
            NSLocalizedString("add-contact.lookup", bundle: .main, value: "Continue", comment: "Add contact: reads the link in the field")
        }

        /// The preview's title; `name` is the person's label.
        public static func previewTitle(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "add-contact.preview.title",
                    bundle: .main,
                    value: "Add %@?",
                    comment: "Add contact: the preview's title; %@ is the person's name"
                ),
                name
            )
        }

        /// Under the safety number in the preview; `name` is the person's label.
        public static func safetyCaption(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "add-contact.preview.safety",
                    bundle: .main,
                    value: """
                        Compare this number with %@ over a call to be sure the link really came from them. You can also do that \
                        later from their profile.
                        """,
                    comment: "Add contact: under the safety number in the preview; %@ is the person's name"
                ),
                name
            )
        }

        /// The preview's note for someone already a contact; `name` is their label.
        public static func already(_ name: String) -> String {
            format(
                NSLocalizedString(
                    "add-contact.preview.already",
                    bundle: .main,
                    value: "%@ is already in your contacts.",
                    comment: "Add contact: the person is already a contact; %@ is their name"
                ),
                name
            )
        }

        /// The preview's note for someone blocked.
        public static var blocked: String {
            NSLocalizedString(
                "add-contact.preview.blocked",
                bundle: .main,
                value: "You've blocked this person.",
                comment: "Add contact: the person in the preview is blocked"
            )
        }

        /// The preview's button that adds the person.
        public static var confirm: String {
            NSLocalizedString(
                "add-contact.confirm", bundle: .main, value: "Add contact", comment: "Add contact: adds the person in the preview")
        }

        /// The preview's button that unblocks the person and adds them.
        public static var confirmUnblocking: String {
            NSLocalizedString(
                "add-contact.confirm.unblock",
                bundle: .main,
                value: "Unblock and add",
                comment: "Add contact: unblocks the blocked person in the preview and adds them"
            )
        }

        /// What a scan here did, said once the scanner closes.
        public static func scanOutcome(_ outcome: AddContactScanOutcome) -> String {
            switch outcome {
            case .added:
                NSLocalizedString(
                    "add-contact.scan.added",
                    bundle: .main,
                    value: "Verified and added to your contacts.",
                    comment: "Add contact: a scanned code added the person as a verified contact"
                )
            case .mismatch:
                NSLocalizedString(
                    "add-contact.scan.mismatch",
                    bundle: .main,
                    value: "That code doesn't match the key Knit already has for this person. Make sure you're scanning the right phone.",
                    comment: "Add contact: a scanned code carries a different key than the one Knit holds for that person"
                )
            case .ownCode:
                Profile.scanOutcome(.ownCode, name: "")
            case .notACode:
                Profile.scanOutcome(.notACode, name: "")
            case .failed:
                failed
            }
        }

        /// Why a link added nobody.
        public static func problem(_ problem: AddContactProblem) -> String {
            switch problem {
            case .notALink:
                NSLocalizedString(
                    "add-contact.link.invalid",
                    bundle: .main,
                    value: "That isn't a Knit contact link.",
                    comment: "Add contact: the pasted or opened text is not a contact link"
                )
            case .ownLink:
                NSLocalizedString(
                    "add-contact.link.own",
                    bundle: .main,
                    value: "That's your own link. Send it to the other person, and add theirs.",
                    comment: "Add contact: the user opened or pasted their own link"
                )
            case .mismatch(let name):
                format(
                    NSLocalizedString(
                        "add-contact.link.mismatch",
                        bundle: .main,
                        value: """
                            This link's key doesn't match the one Knit already has for %@. Ask them to compare safety numbers \
                            with you.
                            """,
                        comment: "Add contact: a link carries a different key than the one Knit holds; %@ is the person's name"
                    ),
                    name
                )
            case .failed:
                failed
            }
        }

        /// A pin the store did not keep.
        private static var failed: String {
            NSLocalizedString(
                "add-contact.failed",
                bundle: .main,
                value: "Knit couldn't save this contact. Try again.",
                comment: "Add contact: the phone's storage refused the new contact"
            )
        }
    }
}
