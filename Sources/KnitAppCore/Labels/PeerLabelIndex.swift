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
///
/// A stranger not heard from in a week gives way (knit-next ADR 2026-10.k8ge, ``LabelFade``): the contact it collided
/// with reads plain again, and the stranger keeps a label no one else wears.
///
/// Someone else's name is indexed as its ``NamePresenter`` draws it, so a name the content filter hides is blank here
/// and takes the alias path an invisible name takes, and two hidden names still read apart (knit-next ADR
/// 2026-11.y4pc). Our own name is never presented.
public struct PeerLabelIndex: Sendable {
    private let storedNames: [String: String]
    private let idsByKey: [String: Set<String>]
    private let idsByText: [String: Set<String>]
    private let consumed: [String: Int]
    private let phrases: [String: [String]]
    private let presenter: NamePresenter
    private let selfId: String?

    /// An index over nothing, which discriminates nothing.
    public static let empty = Self(
        storedNames: [:], idsByKey: [:], idsByText: [:], consumed: [:], phrases: [:], presenter: .asStored, selfId: nil)

    private init(
        storedNames: [String: String],
        idsByKey: [String: Set<String>],
        idsByText: [String: Set<String>],
        consumed: [String: Int],
        phrases: [String: [String]],
        presenter: NamePresenter,
        selfId: String?
    ) {
        self.storedNames = storedNames
        self.idsByKey = idsByKey
        self.idsByText = idsByText
        self.consumed = consumed
        self.phrases = phrases
        self.presenter = presenter
        self.selfId = selfId
    }

    /// The index over `peers`, each a node id and its stored, possibly blank, name drawn as `presenter` draws it, and
    /// `me`, keyed by node id: a peer row for our own id and `me` are one identity, under our name as it is. Every
    /// member sharing a ``NameKey`` takes one token, then every member still sharing a rendered text takes one more,
    /// until all texts differ.
    ///
    /// The members in `stale` give way (`PeerLabels.index`'s `stale`, knit-next ADR 2026-10.k8ge): strangers not heard
    /// from in a week (``LabelFade``). The rest, the live members, `me` always among them, are labelled as if the stale
    /// ones were not there, so a contact whose only namesake went quiet reads plain again. A stale member still reads
    /// apart from everyone: it starts at the tokens it would hold against every member, never fewer, so a look-alike that
    /// ground a contact's alias and then went quiet cannot settle on the label the contact wore while both were live, and
    /// it grows past every text that still matches, the live texts held fixed. Empty, or naming no member, it changes
    /// nothing.
    public init(
        peers: [(nodeId: String, name: String)], me: (nodeId: String, name: String)? = nil, presenter: NamePresenter = .asStored,
        stale: Set<String> = []
    ) {
        var stored: [String: String] = [:]
        var order: [String] = []
        let shown = peers.map { (nodeId: $0.nodeId, name: presenter($0.name)) }
        for (nodeId, name) in shown + (me.map { [$0] } ?? []) where stored.updateValue(name, forKey: nodeId) == nil {
            order.append(nodeId)
        }
        var words: [String: [String]] = [:]
        var names: [String: String] = [:]
        var keys: [String: String] = [:]
        var keyGroups: [String: Set<String>] = [:]
        for nodeId in order {
            words[nodeId] = Alias.tokens(for: nodeId)
            let name = Alias.displayName(stored: stored[nodeId], nodeId: nodeId)
            names[nodeId] = name
            let key = NameKey.of(name)
            keys[nodeId] = key
            keyGroups[key, default: []].insert(nodeId)
        }
        let universe = Universe(stored: stored, names: names, keys: keys, words: words)
        let full = universe.consumed(among: order)
        let yielding = Set(order.filter { stale.contains($0) && $0 != me?.nodeId })
        let spent = yielding.isEmpty ? full : universe.yielding(full, stale: yielding, order: order)
        var textGroups: [String: Set<String>] = [:]
        for nodeId in order {
            textGroups[universe.text(nodeId, spent[nodeId] ?? 0), default: []].insert(nodeId)
        }
        self.init(
            storedNames: stored,
            idsByKey: keyGroups,
            idsByText: textGroups,
            consumed: spent,
            phrases: words,
            presenter: presenter,
            selfId: me?.nodeId
        )
    }

    /// Whether `other` holds the same names, byte for byte, under the same ids, with every member spending the same
    /// tokens, so it gives every id the label and the mention texts this index gives: both are made from the names and
    /// those counts. The counts differ only where a stale member gave way in one index and not the other (ADR
    /// 2026-11.58yk), which moves labels with no name changing.
    func holdsTheNames(of other: Self) -> Bool {
        selfId.map(ExactKey.init) == other.selfId.map(ExactKey.init) && storedNames.count == other.storedNames.count
            && consumed == other.consumed
            && storedNames.allSatisfy { nodeId, name in other.storedNames[nodeId].map { ExactKey($0) == ExactKey(name) } ?? false }
    }

    /// The label for `nodeId`, under the name the index holds for it. A node id outside the index, a sender whose
    /// profile has not pinned, grows as far as it must to read apart from every member, and never changes one.
    public func label(for nodeId: String) -> PeerLabel {
        label(for: nodeId, shown: storedNames[nodeId])
    }

    /// The label for `nodeId` under `storedName`, which may differ from the name the index holds for it: drawn as the
    /// index draws every name but ours, so a raw name a caller holds reads as the index's own would.
    public func label(for nodeId: String, storedName: String?) -> PeerLabel {
        label(for: nodeId, shown: nodeId == selfId ? storedName : storedName.map { presenter($0) })
    }

    /// The texts a received mention of `nodeId` may carry and still be drawn as one (`mentionTexts` in knit-next's
    /// `PeerLabels.kt`): the label ``label(for:)`` gives them, then that label grown by each further token of their own
    /// alias phrase, up to ``Alias/maxTokens``. A sender whose directory saw a clash this one does not writes one of the
    /// longer texts; a name this index does not hold for them, or another id's tokens, is none of them.
    public func mentionTexts(for nodeId: String) -> [String] {
        let shown = storedNames[nodeId]
        let parts = measure(nodeId, shown: shown)
        return (parts.spent...max(parts.spent, Alias.maxTokens)).map { tokens in
            PeerLabel.text(parts.name, Self.discriminator(parts.words, shown, tokens))
        }
    }

    /// The label for `nodeId` under `storedName` as it is drawn.
    private func label(for nodeId: String, shown storedName: String?) -> PeerLabel {
        let parts = measure(nodeId, shown: storedName)
        return PeerLabel(
            nodeId: nodeId,
            name: parts.name,
            alias: parts.words.prefix(max(parts.spent, 1)).joined(separator: " "),
            discriminator: Self.discriminator(parts.words, storedName, parts.spent)
        )
    }

    /// What a label is made of: the name `nodeId` shows under `storedName` as it is drawn, its alias phrase, and the
    /// tokens its label spends.
    private func measure(_ nodeId: String, shown storedName: String?) -> LabelParts {
        let name = Alias.displayName(stored: storedName, nodeId: nodeId)
        let words = phrases[nodeId] ?? Alias.tokens(for: nodeId)
        let held = storedNames[nodeId] == storedName ? consumed[nodeId] : nil
        return LabelParts(name: name, words: words, spent: held ?? resolve(nodeId, name, words, storedName))
    }

    /// The tokens an id needs against the index: one when a member shares its name's key, then one more while a
    /// member's text still matches.
    private func resolve(_ nodeId: String, _ name: String, _ words: [String], _ storedName: String?) -> Int {
        var spent = Self.tokensInName(storedName)
        if !idsByKey[NameKey.quick(name), default: []].subtracting([nodeId]).isEmpty {
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

    /// The tokens a rendered name already spends: one when it is the alias, a blank profile's name. Blank is
    /// ``NameKey/isBlankName(_:)``, as in ``Alias/displayName(stored:nodeId:)``: if the two disagreed, a name of U+3164
    /// alone would render as `Alias (Alias)`.
    internal static func tokensInName(_ storedName: String?) -> Int {
        NameKey.isBlankName(storedName) ? 1 : 0
    }

    /// The tokens after those the name spends, up to `spent`, or `nil` when there are none.
    internal static func discriminator(_ words: [String], _ storedName: String?, _ spent: Int) -> String? {
        let from = tokensInName(storedName)
        guard spent > from else {
            return nil
        }
        return words[from..<min(spent, words.count)].joined(separator: " ")
    }
}

/// A label's parts before it is rendered.
private struct LabelParts {
    /// ``Alias/displayName(stored:nodeId:)``'s answer.
    var name: String
    /// The id's whole alias phrase.
    var words: [String]
    /// The tokens the label spends, those its name spends included.
    var spent: Int
}

/// One index's members, what each renders as, and the passes that count their tokens (`Universe` in knit-next's
/// `PeerLabels.kt`). Every member's count is recorded, live and stale alike: a member that fell through to
/// ``PeerLabelIndex``'s `resolve` would be judged against the stale members its live labels leave out.
private struct Universe {
    /// Each member's stored name, as it is drawn.
    let stored: [String: String]
    /// ``Alias/displayName(stored:nodeId:)``'s answer for each member.
    let names: [String: String]
    /// Each member's name's ``NameKey``.
    let keys: [String: String]
    /// Each member's whole alias phrase.
    let words: [String: [String]]

    /// `nodeId`'s rendered label when it spends `tokens`.
    func text(_ nodeId: String, _ tokens: Int) -> String {
        PeerLabel.text(
            names[nodeId] ?? nodeId, PeerLabelIndex.discriminator(words[nodeId] ?? [], stored[nodeId], tokens))
    }

    /// The rule over `ids` alone (`consumedAmong`): a token for each member of a name another of `ids` shares, then
    /// rounds until no text repeats.
    func consumed(among ids: [String]) -> [String: Int] {
        var shared: [String: Int] = [:]
        for nodeId in ids {
            shared[keys[nodeId] ?? "", default: 0] += 1
        }
        var consumed: [String: Int] = [:]
        for nodeId in ids {
            let namesake = shared[keys[nodeId] ?? "", default: 0] > 1
            consumed[nodeId] = PeerLabelIndex.tokensInName(stored[nodeId]) + (namesake ? 1 : 0)
        }
        growUntilDistinct(&consumed, frozen: [])
        return consumed
    }

    /// The live members, every one in `order` outside `stale`, labelled among themselves; each of `stale` from where
    /// `full` put it, grown past every text, the live ones held fixed (`yielding`).
    func yielding(_ full: [String: Int], stale: Set<String>, order: [String]) -> [String: Int] {
        let live = order.filter { !stale.contains($0) }
        var consumed = consumed(among: live)
        for nodeId in stale {
            consumed[nodeId] = full[nodeId]
        }
        growUntilDistinct(&consumed, frozen: Set(live))
        return consumed
    }

    /// Each round, every id whose text another shares takes one more token, except a `frozen` one, whose text the round
    /// reads but never moves. Bounded by the digest's ten.
    private func growUntilDistinct(_ consumed: inout [String: Int], frozen: Set<String>) {
        var texts: [String: String] = [:]
        for (nodeId, tokens) in consumed {
            texts[nodeId] = text(nodeId, tokens)
        }
        for _ in 0..<Alias.maxTokens {
            let colliding = Dictionary(grouping: texts.keys) { texts[$0] ?? "" }.values.filter { $0.count > 1 }.flatMap(\.self)
                .filter { !frozen.contains($0) }
            guard !colliding.isEmpty else {
                return
            }
            var grew = false
            for nodeId in colliding {
                let spent = consumed[nodeId] ?? 0
                if spent < Alias.maxTokens {
                    consumed[nodeId] = spent + 1
                    texts[nodeId] = text(nodeId, spent + 1)
                    grew = true
                }
            }
            // Nothing left to grow: two ids share every token, which only a SHA-256 collision could do.
            guard grew else {
                return
            }
        }
    }
}
