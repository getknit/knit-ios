import Foundation
public import KnitMesh

extension Copy {
    /// Diagnostics: links, sightings, drops and clocks, for someone checking the mesh. Plain and technical on purpose.
    public enum Diagnostics {
        /// The screen's title.
        public static var title: String {
            NSLocalizedString("diagnostics.title", bundle: .main, value: "Diagnostics", comment: "Diagnostics: the screen's title")
        }

        /// This device's section.
        public static var thisDevice: String {
            NSLocalizedString(
                "diagnostics.this-device",
                bundle: .main,
                value: "This device",
                comment: "Diagnostics: this device's section"
            )
        }

        /// The radio row's label.
        public static var bluetooth: String {
            NSLocalizedString("diagnostics.bluetooth", bundle: .main, value: "Bluetooth", comment: "Diagnostics: the radio's row")
        }

        /// The radio's state in a word or two.
        public static func radio(_ state: RadioState?) -> String {
            switch state {
            case nil:
                NSLocalizedString(
                    "diagnostics.radio.starting",
                    bundle: .main,
                    value: "Starting",
                    comment: "Diagnostics: radio not reported yet"
                )
            case .on:
                NSLocalizedString("diagnostics.radio.on", bundle: .main, value: "On", comment: "Diagnostics: radio on")
            case .off:
                NSLocalizedString("diagnostics.radio.off", bundle: .main, value: "Off", comment: "Diagnostics: radio off")
            case .unauthorized:
                NSLocalizedString(
                    "diagnostics.radio.not-allowed",
                    bundle: .main,
                    value: "Not allowed",
                    comment: "Diagnostics: radio refused"
                )
            case .unsupported:
                NSLocalizedString(
                    "diagnostics.radio.unsupported",
                    bundle: .main,
                    value: "No Bluetooth LE",
                    comment: "Diagnostics: no radio"
                )
            }
        }

        /// The mesh row's label.
        public static var mesh: String {
            NSLocalizedString("diagnostics.mesh", bundle: .main, value: "Mesh", comment: "Diagnostics: the mesh's row")
        }

        /// The mesh is running.
        public static var running: String {
            NSLocalizedString("diagnostics.running", bundle: .main, value: "Running", comment: "Diagnostics: the mesh is running")
        }

        /// The mesh is stopped.
        public static var stopped: String {
            NSLocalizedString("diagnostics.stopped", bundle: .main, value: "Stopped", comment: "Diagnostics: the mesh is stopped")
        }

        /// The linked peers' section.
        public static func linked(_ count: Int) -> String {
            format(
                NSLocalizedString(
                    "diagnostics.linked",
                    bundle: .main,
                    value: "Linked (%lld)",
                    comment: "Diagnostics: linked peers; a count"
                ),
                count
            )
        }

        /// No links.
        public static var noneLinked: String {
            NSLocalizedString("diagnostics.linked.none", bundle: .main, value: "No links", comment: "Diagnostics: nothing linked")
        }

        /// The sighted peers' section.
        public static func sighted(_ count: Int) -> String {
            format(
                NSLocalizedString(
                    "diagnostics.sighted",
                    bundle: .main,
                    value: "Sighted (%lld)",
                    comment: "Diagnostics: sighted peers; a count"
                ),
                count
            )
        }

        /// No sightings.
        public static var noneSighted: String {
            NSLocalizedString(
                "diagnostics.sighted.none",
                bundle: .main,
                value: "Nothing sighted",
                comment: "Diagnostics: nothing sighted"
            )
        }

        /// Pinned peers neither linked nor sighted.
        public static func known(_ count: Int) -> String {
            format(
                NSLocalizedString(
                    "diagnostics.known",
                    bundle: .main,
                    value: "Known, out of range (%lld)",
                    comment: "Diagnostics: pinned peers; a count"
                ),
                count
            )
        }

        /// A sighting's signal and age: "-67 dBm, 3 s ago".
        public static func sighting(rssi: Int, secondsAgo: Int) -> String {
            format(
                NSLocalizedString(
                    "diagnostics.sighting",
                    bundle: .main,
                    value: "%1$lld dBm, %2$lld s ago",
                    comment: "Diagnostics: %1$lld is signal strength, %2$lld the seconds since it was heard"
                ),
                rssi,
                secondsAgo
            )
        }

        /// A link's protocol version and capability bits: "v3, caps 9".
        public static func link(version: Int, capabilities: String) -> String {
            format(
                NSLocalizedString(
                    "diagnostics.link",
                    bundle: .main,
                    value: "v%1$lld, caps %2$@",
                    comment: "Diagnostics: %1$lld is the peer's protocol version, %2$@ its capability bits in hex"
                ),
                version,
                capabilities
            )
        }

        /// A peer's clock agrees with ours, within a couple of seconds.
        public static var clockInStep: String {
            NSLocalizedString(
                "diagnostics.clock.in-step",
                bundle: .main,
                value: "Clock in step",
                comment: "Diagnostics: the peer's clock agrees"
            )
        }

        /// A peer's clock runs ahead of ours.
        public static func clockAhead(seconds: Int) -> String {
            format(
                NSLocalizedString(
                    "diagnostics.clock.ahead",
                    bundle: .main,
                    value: "Clock %lld s ahead",
                    comment: "Diagnostics: the peer's clock is ahead"
                ),
                seconds
            )
        }

        /// A peer's clock runs behind ours, by at least this much.
        public static func clockBehind(seconds: Int) -> String {
            format(
                NSLocalizedString(
                    "diagnostics.clock.behind",
                    bundle: .main,
                    value: "Clock up to %lld s behind",
                    comment: "Diagnostics: the peer's clock is behind, by at most this"
                ),
                seconds
            )
        }

        /// The counters' section.
        public static var counters: String {
            NSLocalizedString("diagnostics.counters", bundle: .main, value: "Counters", comment: "Diagnostics: the counters' section")
        }

        /// FILE records thrown away: avatars and attachments, which the MVP does not show.
        public static var discardedFiles: String {
            NSLocalizedString(
                "diagnostics.discarded-files",
                bundle: .main,
                value: "File records discarded",
                comment: "Diagnostics: a counter"
            )
        }
    }
}
