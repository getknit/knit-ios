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
