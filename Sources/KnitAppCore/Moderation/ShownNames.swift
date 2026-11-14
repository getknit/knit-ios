import KnitSync
import KnitWire

/// The name screen's verdicts, cached by text, and how someone else's name, status or group name is drawn while the
/// content filter is on (`ShownNames.kt`, knit-next ADR 2026-11.y4pc). A flagged one draws blank: a person shows their
/// alias, a group its members' title, and a status nothing. Nothing is stored, and the signed profile and group frames
/// are never touched. The same screen refuses our own name and status when they are set, whatever the toggle says.
///
/// A directory is rebuilt on every change and asks about every row, so the verdicts are kept, as many as Android keeps.
/// They are kept in two generations rather than one LRU list: a hit in the older generation moves to the newer, and the
/// older goes whole once the newer fills, which keeps what is read often and stays within the bound. A verdict never
/// changes for a text, so only the hit rate can differ from Android's. A text is keyed by its UTF-8 bytes, because
/// Swift's string equality makes a composed "Díck" and a decomposed one a single key, where the screen reads them apart.
public final class ShownNames: Sendable {
    /// How many verdicts are kept: room for every row of a full peer table twice over, with statuses and group names
    /// (`DEFAULT_CAPACITY`).
    public static let defaultCapacity = 8192

    private struct Key: Hashable {
        let audience: NameScreen.Audience
        let text: [UInt8]
    }

    /// A verdict as kept.
    private enum Kept {
        case flagged
        case clear
    }

    private struct Verdicts {
        var newer: [Key: Kept] = [:]
        var older: [Key: Kept] = [:]

        /// The verdict kept for `key`, moved to the newer generation if it was in the older one.
        mutating func verdict(for key: Key, generation: Int) -> Kept? {
            if let verdict = newer[key] {
                return verdict
            }
            guard let verdict = older.removeValue(forKey: key) else {
                return nil
            }
            keep(verdict, for: key, generation: generation)
            return verdict
        }

        /// Keeps `verdict` in the newer generation, which becomes the older one first when it is full: neither ever
        /// holds more than `generation`, a move from the older included, so a set read on every rebuild cannot grow it.
        mutating func keep(_ verdict: Kept, for key: Key, generation: Int) {
            if newer.count >= generation {
                older = newer
                newer = [:]
            }
            newer[key] = verdict
        }
    }

    /// The bound is split between the newer and the older generation.
    private static let generations = 2

    private let check: @Sendable (String, NameScreen.Audience) -> Bool
    private let generation: Int
    private let verdicts = Lock(Verdicts())

    /// The verdicts of `screen`, at most `capacity` of them kept.
    public convenience init(screen: NameScreen, capacity: Int = ShownNames.defaultCapacity) {
        self.init(capacity: capacity) { screen.check($0, audience: $1).flagged }
    }

    /// The verdicts `check` gives, whether a text is flagged for an audience, at most `capacity` of them kept.
    @preconcurrency
    public init(capacity: Int = ShownNames.defaultCapacity, check: @escaping @Sendable (String, NameScreen.Audience) -> Bool) {
        self.check = check
        generation = max(capacity / Self.generations, 1)
    }

    /// Whether `text` holds a term `audience` must not see. Blank text never does.
    public func flagged(_ text: String, audience: NameScreen.Audience) -> Bool {
        guard !TextLimits.isBlank(text) else {
            return false
        }
        let key = Key(audience: audience, text: Array(text.utf8))
        if let kept = verdicts.withLock({ $0.verdict(for: key, generation: generation) }) {
            return kept == .flagged
        }
        let flagged = check(text, audience)
        verdicts.withLock { $0.keep(flagged ? .flagged : .clear, for: key, generation: generation) }
        return flagged
    }

    /// A person's name or status, as strangers may see it: blank when it holds a slur or profanity.
    public var person: NamePresenter {
        NamePresenter { [self] in flagged($0, audience: .everyone) ? "" : $0 }
    }

    /// A group's name, as its members see it: blank when it holds a slur.
    public var group: NamePresenter {
        NamePresenter { [self] in flagged($0, audience: .members) ? "" : $0 }
    }
}
