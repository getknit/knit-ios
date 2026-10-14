public import KnitWire

/// A person a message mentions (`Mention` in knit-next's `Wire.kt:441-447`, kept in `MessageEntity.mentions`): their node
/// id, and the text that follows the "@" in the body, which is the sender's label for them, "Name" or "Name (alias
/// words)" when two people share a name (knit-next ADR 058). A thread shows that text as the sender wrote it.
///
/// There are no offsets: a receiver finds a mention by its ``token`` in the body, and only the node id decides whether a
/// message mentions us.
public struct MessageMention: Sendable, Equatable {
    /// The mentioned person's node id, kept unparsed, which compares by its bytes (ADR 2026-09.jc2x).
    public var nodeId: String
    /// The text after the "@", as the sender wrote it.
    public var name: String

    /// A mention.
    public init(nodeId: String, name: String) {
        self.nodeId = nodeId
        self.name = name
    }

    /// The text a body carries for this mention: "@" and the name.
    public var token: String {
        "@" + name
    }
}

extension MessageMention {
    /// The mentions in `mentions` whose ``token`` `body` holds, each pair of node id and name once and none with an empty
    /// name, in their order; or none at all for a list no composer could have written.
    ///
    /// Android's composer keeps a pick while the text holds its token (`text.contains("@${it.name}")`,
    /// `ChatScreen.kt:530` at the pin), so every list its users send passes this whole, a stale pick among them: one whose
    /// chip went but whose token lives on inside a longer name, "@Ann" inside "@Annabel". A sender drops what fails it, and
    /// a receiver keeps no more. Tokens match by UTF-16 code units, as Kotlin's `contains` does.
    ///
    /// A frame can list thousands of long names, so each token is looked up in an index of the body's substrings, in
    /// time that grows with the token alone. The tokens found are bounded by the body: each chip the composer inserts sits
    /// in a place of its own, and a stale pick hides inside another name, so the distinct tokens of a list someone picked
    /// come to less than twice the body's units, short of one name hiding several stale picks at once. A list past that
    /// keeps none, whatever its order, which bounds what a row holds and what a thread's highlight searches (ADR
    /// 2026-10.nbhj). Android keeps any list, so a crafted mention without its
    /// token, or in such a list, alerts there and not here.
    public static func carried(_ mentions: [MessageMention], in body: String) -> [MessageMention] {
        let text = Array(body.utf16)
        let index = SubstringIndex(text)
        var found: [[UInt16]: Bool] = [:]
        var seen = Set<[ExactKey]>()
        let kept = mentions.filter { mention in
            guard !mention.name.isEmpty, seen.insert([ExactKey(mention.nodeId), ExactKey(mention.name)]).inserted else {
                return false
            }
            let token = Array(mention.token.utf16)
            if let known = found[token] {
                return known
            }
            let occurs = index.contains(token)
            found[token] = occurs
            return occurs
        }
        let foundUnits = found.reduce(0) { units, entry in entry.value ? units + entry.key.count : units }
        return foundUnits <= foundPerBodyUnit * text.count ? kept : []
    }

    /// How many units of distinct tokens found a list may hold for each unit of its body: a chip's own, and as many again
    /// for stale picks hiding inside other names.
    private static let foundPerBodyUnit = 2
}

/// Every substring of one text, as a suffix automaton: built in time that grows with the text, it answers whether a needle
/// occurs in time that grows with the needle alone, by UTF-16 code units, as Kotlin's `contains` compares them.
internal struct SubstringIndex {
    /// Each state's moves, its suffix link, and the longest substring it stands for.
    private var moves: [[UInt16: Int]] = [[:]]
    private var links: [Int] = [-1]
    private var lengths: [Int] = [0]

    /// The index of `text`.
    init(_ text: [UInt16]) {
        var last = 0
        for unit in text {
            let current = moves.count
            moves.append([:])
            links.append(0)
            lengths.append(lengths[last] + 1)
            var state = last
            while state >= 0, moves[state][unit] == nil {
                moves[state][unit] = current
                state = links[state]
            }
            if state >= 0, let target = moves[state][unit] {
                if lengths[state] + 1 == lengths[target] {
                    links[current] = target
                } else {
                    let clone = moves.count
                    moves.append(moves[target])
                    links.append(links[target])
                    lengths.append(lengths[state] + 1)
                    while state >= 0, moves[state][unit] == target {
                        moves[state][unit] = clone
                        state = links[state]
                    }
                    links[target] = clone
                    links[current] = clone
                }
            }
            last = current
        }
    }

    /// Whether `needle` occurs in the text; an empty one always does.
    func contains(_ needle: [UInt16]) -> Bool {
        var state = 0
        for unit in needle {
            guard let next = moves[state][unit] else {
                return false
            }
            state = next
        }
        return true
    }
}

extension [MessageMention] {
    /// Whether one of these mentions `node`, by its node id alone (`List<Mention>.mention`, `Wire.kt:447`): the name
    /// is the sender's to write, and a node id compares by its bytes (ADR 2026-09.jc2x).
    public func mentions(_ node: NodeId) -> Bool {
        let key = ExactKey(node.string)
        return contains { ExactKey($0.nodeId) == key }
    }
}
