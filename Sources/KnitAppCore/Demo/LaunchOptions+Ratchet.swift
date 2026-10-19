extension LaunchOptions {
    /// What `-ratchet` chooses for the ratchet's switch, a debug build's way off the ratchet and back for a device trial
    /// (ADR 2026-10.5sk9): `-ratchet off` or `-ratchet on`. The app keeps the choice and hands it back to every launch
    /// after it that names none, so a launch iOS makes by itself (after an install, at the first unlock after a reboot)
    /// keeps the switch where the trial put it; its start would otherwise republish the profile with the prekey the trial
    /// took away. With no choice made or kept, the switch is on. A release build reads no argument and keeps nothing (ADR
    /// 2026-10.8cy5), so its switch is always on.
    public enum Choice: Sendable, Equatable {
        /// The switch on.
        case on
        /// The switch off.
        case off

        /// The word that names it, as `-ratchet` takes it and the app keeps it.
        public var word: String {
            self == .on ? "on" : "off"
        }

        /// The choice `word` names: `on` or `off`, and nothing else.
        public init?(word: String) {
            switch word {
            case "on":
                self = .on
            case "off":
                self = .off
            default:
                return nil
            }
        }

        /// The choice the word after `flag` in `arguments` names, or `nil` for none: no `flag`, nothing after it, or a word
        /// other than `on` and `off`, which leaves a kept choice as it was.
        init?(after flag: String, in arguments: [String]) {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                return nil
            }
            self.init(word: arguments[index + 1])
        }
    }
}
