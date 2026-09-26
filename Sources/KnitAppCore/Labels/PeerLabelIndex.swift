import Foundation
import KnitCrypto
import KnitWire

/// The name to show for a person and, when another identity this device knows renders to the same name, the
/// discriminator that tells them apart (`PeerLabel` in knit-next's `PeerLabels.kt`, ADR 058 there).
public struct PeerLabel: Sendable, Equatable {
    /// The person's node id.
    public let nodeId: String
    /// ``Alias/displayName(stored:nodeId:)``'s answer: the stored name, or the alias when it is blank.
    public let name: String
    /// What the person would quote to be told apart: their alias, grown by as many tokens as the index needed.
    public let alias: String
    /// The part of the alias shown after the name, or `nil` when the name alone is unique.
    public let discriminator: String?

    /// The rendered label, `name` or `name (discriminator)`. Deliberately not localized: every surface, on both
    /// platforms, renders a label the same way.
    public var text: String {
        Self.text(name, discriminator)
    }

    static func text(_ name: String, _ discriminator: String?) -> String {
        discriminator.map { "\(name) (\($0))" } ?? name
    }
}

/// Collision-aware labels over every identity this device knows (`PeerLabels` and `PeerLabelIndex`).
///
/// A name is free text and nothing makes it unique, so a peer shows under its name alone in the common case and as
/// `name (discriminator)` when another known identity shares its ``NameKey``. The discriminator is a prefix of the
/// peer's alias phrase, which every device derives the same way, and it grows a token each round the rendered texts
/// still coincide: a name chosen to read like someone's label, or an alias ground to match one. Distinct ids have
/// distinct digests, so every label in an index is distinct. This makes a collision evident; it does not stop
/// impersonation, which is what the safety number is for.
public struct PeerLabelIndex: Sendable {
    private let storedNames: [String: String]
    private let idsByKey: [String: Set<String>]
    private let idsByText: [String: Set<String>]
    private let consumed: [String: Int]
    private let phrases: [String: [String]]

    /// An index over nothing, which discriminates nothing.
    public static let empty = Self(storedNames: [:], idsByKey: [:], idsByText: [:], consumed: [:], phrases: [:])

    private init(
        storedNames: [String: String],
        idsByKey: [String: Set<String>],
        idsByText: [String: Set<String>],
        consumed: [String: Int],
        phrases: [String: [String]]
    ) {
        self.storedNames = storedNames
        self.idsByKey = idsByKey
        self.idsByText = idsByText
        self.consumed = consumed
        self.phrases = phrases
    }

    /// The index over `peers`, each a node id and its stored, possibly blank, name, and `me`, keyed by node id: a
    /// peer row for our own id and `me` are one identity. Every member sharing a ``NameKey`` takes one token, then
    /// every member still sharing a rendered text takes one more, until all texts differ.
    public init(peers: [(nodeId: String, name: String)], me: (nodeId: String, name: String)? = nil) {
        var stored: [String: String] = [:]
        var order: [String] = []
        for (nodeId, name) in peers + (me.map { [$0] } ?? []) where stored.updateValue(name, forKey: nodeId) == nil {
            order.append(nodeId)
        }
        var words: [String: [String]] = [:]
        var names: [String: String] = [:]
        var keyGroups: [String: Set<String>] = [:]
        for nodeId in order {
            words[nodeId] = Alias.tokens(for: nodeId)
            let name = Alias.displayName(stored: stored[nodeId], nodeId: nodeId)
            names[nodeId] = name
            keyGroups[NameKey.of(name), default: []].insert(nodeId)
        }
        var spent: [String: Int] = [:]
        for group in keyGroups.values where group.count > 1 {
            for nodeId in group {
                spent[nodeId] = Self.tokensInName(stored[nodeId]) + 1
            }
        }
        let render = { (nodeId: String, tokens: Int) in
            PeerLabel.text(names[nodeId] ?? nodeId, Self.discriminator(words[nodeId] ?? [], stored[nodeId], tokens))
        }
        var texts: [String: String] = [:]
        for nodeId in order {
            texts[nodeId] = render(nodeId, spent[nodeId] ?? Self.tokensInName(stored[nodeId]))
        }
        Self.growUntilDistinct(&texts, &spent, stored, render)
        var textGroups: [String: Set<String>] = [:]
        for (nodeId, text) in texts {
            textGroups[text, default: []].insert(nodeId)
        }
        self.init(storedNames: stored, idsByKey: keyGroups, idsByText: textGroups, consumed: spent, phrases: words)
    }

    /// The label for `nodeId`, under the name the index holds for it. A node id outside the index, a sender whose
    /// profile has not pinned, grows as far as it must to read apart from every member, and never changes one.
    public func label(for nodeId: String) -> PeerLabel {
        label(for: nodeId, storedName: storedNames[nodeId])
    }

    /// The label for `nodeId` under `storedName`, which may differ from the name the index holds for it.
    public func label(for nodeId: String, storedName: String?) -> PeerLabel {
        let name = Alias.displayName(stored: storedName, nodeId: nodeId)
        let words = phrases[nodeId] ?? Alias.tokens(for: nodeId)
        let held = storedNames[nodeId] == storedName ? consumed[nodeId] : nil
        let spent = held ?? resolve(nodeId, name, words, storedName)
        return PeerLabel(
            nodeId: nodeId,
            name: name,
            alias: words.prefix(max(spent, 1)).joined(separator: " "),
            discriminator: Self.discriminator(words, storedName, spent)
        )
    }

    /// The tokens an id needs against the index: one when a member shares its name's key, then one more while a
    /// member's text still matches.
    private func resolve(_ nodeId: String, _ name: String, _ words: [String], _ storedName: String?) -> Int {
        var spent = Self.tokensInName(storedName)
        if !idsByKey[NameKey.of(name), default: []].subtracting([nodeId]).isEmpty {
            spent += 1
        }
        while spent < Alias.maxTokens, collides(nodeId, PeerLabel.text(name, Self.discriminator(words, storedName, spent))) {
            spent += 1
        }
        return spent
    }

    private func collides(_ nodeId: String, _ text: String) -> Bool {
        !idsByText[text, default: []].subtracting([nodeId]).isEmpty
    }

    /// Each round, every id whose text another shares takes one more token, bounded by the digest's ten.
    private static func growUntilDistinct(
        _ texts: inout [String: String],
        _ consumed: inout [String: Int],
        _ stored: [String: String],
        _ render: (String, Int) -> String
    ) {
        for _ in 0..<Alias.maxTokens {
            let colliding = Dictionary(grouping: texts.keys) { texts[$0] ?? "" }.values.filter { $0.count > 1 }.flatMap(\.self)
            guard !colliding.isEmpty else {
                return
            }
            var grew = false
            for nodeId in colliding {
                let spent = consumed[nodeId] ?? tokensInName(stored[nodeId])
                if spent < Alias.maxTokens {
                    consumed[nodeId] = spent + 1
                    texts[nodeId] = render(nodeId, spent + 1)
                    grew = true
                }
            }
            // Nothing left to grow: two ids share every token, which only a SHA-256 collision could do.
            guard grew else {
                return
            }
        }
    }

    /// The tokens a rendered name already spends: one when it is the alias, a blank profile's name.
    private static func tokensInName(_ storedName: String?) -> Int {
        guard let storedName, !TextLimits.isBlank(storedName) else {
            return 1
        }
        return 0
    }

    /// The tokens after those the name spends, up to `spent`, or `nil` when there are none.
    private static func discriminator(_ words: [String], _ storedName: String?, _ spent: Int) -> String? {
        let from = tokensInName(storedName)
        guard spent > from else {
            return nil
        }
        return words[from..<min(spent, words.count)].joined(separator: " ")
    }
}

/// The collision key of a display name (`NameKey` in `PeerLabels.kt`): NFKC-normalized, Unicode format characters
/// removed (zero-width joiners and spaces, bidi overrides), lower-cased, whitespace runs collapsed and trimmed, so
/// "Alice", "alice", "Ａlice" and "Al\u{200B}ice" are one name. Confusables are deliberately not folded: a Cyrillic
/// "а" stays apart from a Latin "a", a recorded limit.
public enum NameKey {
    /// The key of `name`.
    public static func of(_ name: String) -> String {
        let folded = name.precomposedStringWithCompatibilityMapping.unicodeScalars.filter { $0.properties.generalCategory != .format }
        return TextLimits.normalizeSingleLine(String(String.UnicodeScalarView(folded)).lowercased())
    }
}
