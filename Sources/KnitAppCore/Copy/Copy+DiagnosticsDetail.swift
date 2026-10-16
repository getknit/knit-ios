import Foundation
public import KnitMesh

extension Copy {
    /// Diagnostics' drop counters, one per reason the engine drops a frame locally (``DropReason``).
    public enum Drops {
        /// The counter's label for one reason.
        public static func reason(_ reason: DropReason) -> String {
            switch reason {
            case .noSenderKey:
                NSLocalizedString("diagnostics.drop.no-key", bundle: .main, value: "Dropped: no sender key", comment: "A drop counter")
            case .keyMismatch:
                NSLocalizedString(
                    "diagnostics.drop.key-mismatch",
                    bundle: .main,
                    value: "Dropped: key mismatch",
                    comment: "A drop counter"
                )
            case .badSignature:
                NSLocalizedString(
                    "diagnostics.drop.bad-signature",
                    bundle: .main,
                    value: "Dropped: bad signature",
                    comment: "A drop counter"
                )
            case .unsigned:
                NSLocalizedString("diagnostics.drop.unsigned", bundle: .main, value: "Dropped: unsigned", comment: "A drop counter")
            case .undecodable:
                NSLocalizedString("diagnostics.drop.undecodable", bundle: .main, value: "Dropped: undecodable", comment: "A drop counter")
            case .cannotOpen:
                NSLocalizedString(
                    "diagnostics.drop.cannot-open",
                    bundle: .main,
                    value: "Dropped: couldn't open",
                    comment: "A drop counter"
                )
            case .cleartextDirect:
                NSLocalizedString(
                    "diagnostics.drop.cleartext",
                    bundle: .main,
                    value: "Dropped: unencrypted DM",
                    comment: "A drop counter"
                )
            case .pinChangeRefused:
                NSLocalizedString(
                    "diagnostics.drop.pin-change",
                    bundle: .main,
                    value: "Dropped: key change refused",
                    comment: "A drop counter"
                )
            case .cleartextGroup, .rosterRefused, .blocked, .reactionRefused:
                laterReason(reason)
            case .ratchetNoSession, .ratchetEpochGone, .ratchetDuplicate, .ratchetBadHeader, .ratchetAeadFail, .storeRefused:
                ratchetReason(reason)
            case .groupRatchetNoKey, .groupRatchetDuplicate, .groupRatchetBadHeader, .groupRatchetAeadFail:
                groupRatchetReason(reason)
            }
        }

        /// The labels for the drops the forward-secrecy ratchet brought (ADR 2026-10.5sk9).
        private static func ratchetReason(_ reason: DropReason) -> String {
            switch reason {
            case .ratchetNoSession:
                NSLocalizedString(
                    "diagnostics.drop.ratchet-no-session",
                    bundle: .main,
                    value: "Dropped: no session with sender",
                    comment: "A drop counter: a forward-secret DM from someone this phone holds no encryption session with"
                )
            case .ratchetEpochGone:
                NSLocalizedString(
                    "diagnostics.drop.ratchet-epoch-gone",
                    bundle: .main,
                    value: "Dropped: key no longer kept",
                    comment: "A drop counter: a forward-secret DM that needs a key this phone has already deleted, or never had"
                )
            case .ratchetDuplicate:
                NSLocalizedString(
                    "diagnostics.drop.ratchet-duplicate",
                    bundle: .main,
                    value: "Dropped: duplicate",
                    comment: "A drop counter: another copy of a forward-secret DM this phone already opened"
                )
            case .ratchetBadHeader:
                NSLocalizedString(
                    "diagnostics.drop.ratchet-bad-header",
                    bundle: .main,
                    value: "Dropped: bad session header",
                    comment: "A drop counter: a forward-secret DM whose encryption header is malformed"
                )
            case .ratchetAeadFail:
                NSLocalizedString(
                    "diagnostics.drop.ratchet-aead-fail",
                    bundle: .main,
                    value: "Dropped: sessions out of step",
                    comment: "A drop counter: a forward-secret DM that failed to decrypt because the two phones' sessions disagree"
                )
            default:
                NSLocalizedString(
                    "diagnostics.drop.store-refused",
                    bundle: .main,
                    value: "Dropped: couldn't be saved",
                    comment: "A drop counter: a message the phone's storage failed to save; it is opened again from the phone's own copy"
                )
            }
        }

        /// The labels for the drops the group form of the forward-secrecy ratchet brought (ADR 2026-10.5sk9, phase P6a2).
        private static func groupRatchetReason(_ reason: DropReason) -> String {
            switch reason {
            case .groupRatchetNoKey:
                NSLocalizedString(
                    "diagnostics.drop.group-ratchet-no-key",
                    bundle: .main,
                    value: "Dropped: missing group key",
                    comment: "A drop counter: a forward-secret group message whose key this phone hasn't received or no longer keeps"
                )
            case .groupRatchetDuplicate:
                NSLocalizedString(
                    "diagnostics.drop.group-ratchet-duplicate",
                    bundle: .main,
                    value: "Dropped: duplicate group message",
                    comment: "A drop counter: another copy of a forward-secret group message this phone already opened"
                )
            case .groupRatchetBadHeader:
                NSLocalizedString(
                    "diagnostics.drop.group-ratchet-bad-header",
                    bundle: .main,
                    value: "Dropped: bad group header",
                    comment: "A drop counter: a forward-secret group message whose encryption header is malformed"
                )
            default:
                NSLocalizedString(
                    "diagnostics.drop.group-ratchet-aead-fail",
                    bundle: .main,
                    value: "Dropped: group keys out of step",
                    comment: "A drop counter: a forward-secret group message that failed to decrypt because the sender's keys disagree"
                )
            }
        }

        /// The labels for the drops groups, blocking and reactions brought.
        private static func laterReason(_ reason: DropReason) -> String {
            switch reason {
            case .cleartextGroup:
                NSLocalizedString(
                    "diagnostics.drop.cleartext-group",
                    bundle: .main,
                    value: "Dropped: unencrypted group message",
                    comment: "A drop counter"
                )
            case .blocked:
                NSLocalizedString(
                    "diagnostics.drop.blocked",
                    bundle: .main,
                    value: "Dropped: blocked sender",
                    comment: "A drop counter: frames from someone the user blocked, still passed on for others but not shown"
                )
            case .reactionRefused:
                NSLocalizedString(
                    "diagnostics.drop.reaction-refused",
                    bundle: .main,
                    value: "Dropped: reaction that isn't an emoji",
                    comment: "A drop counter: a reaction whose text is not a single emoji, still passed on for others but not shown"
                )
            default:
                NSLocalizedString(
                    "diagnostics.drop.roster-refused",
                    bundle: .main,
                    value: "Dropped: group member list refused",
                    comment: "A drop counter: a group message whose member list fails the checks"
                )
            }
        }
    }

    /// The debug build's test identities in Diagnostics, for checking both dial orders (MVP item 2).
    public enum TestIdentity {
        /// The debug build's identity section, for checking both dial orders (MVP item 2).
        public static var title: String {
            NSLocalizedString(
                "diagnostics.test-identity",
                bundle: .main,
                value: "Test identity",
                comment: "Diagnostics (debug): the section"
            )
        }

        /// What minting does.
        public static var footer: String {
            NSLocalizedString(
                "diagnostics.test-identity.footer",
                bundle: .main,
                value: """
                    Makes a new identity whose node ID sorts between the bounds you enter, and uses it from the next launch. The chats \
                    stay, and belong to the old identity.
                    """,
                comment: "Diagnostics (debug): what minting an identity does"
            )
        }

        /// The lower bound's field.
        public static var above: String {
            NSLocalizedString("diagnostics.above", bundle: .main, value: "Above node ID", comment: "Diagnostics (debug): the lower bound")
        }

        /// The upper bound's field.
        public static var below: String {
            NSLocalizedString("diagnostics.below", bundle: .main, value: "Below node ID", comment: "Diagnostics (debug): the upper bound")
        }

        /// The button that mints.
        public static var mint: String {
            NSLocalizedString(
                "diagnostics.mint",
                bundle: .main,
                value: "Make identity",
                comment: "Diagnostics (debug): mints an identity"
            )
        }

        /// A bound that is not a node id.
        public static var invalidNodeId: String {
            NSLocalizedString(
                "diagnostics.invalid",
                bundle: .main,
                value: "That isn't a node ID.",
                comment: "Diagnostics (debug): bad input"
            )
        }

        /// Nothing sorted inside the bounds.
        public static var noRoom: String {
            NSLocalizedString(
                "diagnostics.no-room",
                bundle: .main,
                value: "No node ID fits between those. Widen the bounds and try again.",
                comment: "Diagnostics (debug): the window is empty"
            )
        }

        /// A new identity was stored.
        public static func minted(_ nodeId: String) -> String {
            format(
                NSLocalizedString(
                    "diagnostics.minted",
                    bundle: .main,
                    value: "Made %@. Quit and reopen Knit to use it.",
                    comment: "Diagnostics (debug): %@ is the new node id"
                ),
                nodeId
            )
        }
    }
}
